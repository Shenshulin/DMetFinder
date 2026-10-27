# RtGeter_server.R
# ============================================================
# RtGeter —— 批量把「分钟区间」解析成「具体保留时间」
#
# 输入
#   1) 峰表：四列（峰 id / 样品名称 / MZ / RT_min），支持 xlsx·xls·csv·tsv·txt
#   2) 原始数据文件夹：里面是 .raw / .mzML / .mzXML
#
# 输出
#   峰表原有各列 + 追加一列 RT（共五列）
#
# RT_min 是分钟区间的**右端点**：
#   RT_min = 2  ->  (1, 2]
#   RT_min = 3  ->  (2, 3]
#   RT_min = 4  ->  (3, 4]
# 左开右闭，保证相邻分钟桶既不重叠也不留缝。
#
# 在区间内只扫 MS1 谱：每张谱里取 m/z 容差内的最强峰，
# 再在整段区间里取最强的那张谱，返回它的保留时间（平手取更早的扫描）。
#
# 性能要点：
#   1. 只读索引拿到全部扫描的保留时间，先在内存里筛出窗口内的 MS1 扫描，
#      再按扫描号读谱 —— 不把整个文件读进来（.raw 动辄数百 MB）。
#   2. 按 (样品, RT_min) 分组，同一组只读一次谱图，组内所有 m/z 复用。
#   3. 索引按 (路径, mtime) 缓存，重复运行不重复解析。
# ============================================================


# ------------------------------------------------------------
# 列出工作目录下可用的质谱文件
# 返回 data.frame(name, path, ext)；无文件时返回 0 行
# ------------------------------------------------------------
rtg_list_ms_files <- function(workdir) {
  empty <- data.frame(name = character(0), path = character(0),
                      ext = character(0), stringsAsFactors = FALSE)
  if (is.null(workdir) || !nzchar(workdir) || !dir.exists(workdir)) return(empty)

  files <- list.files(path = workdir,
                      pattern = "\\.(raw|mzml|mzxml)$",
                      full.names = TRUE, ignore.case = TRUE)
  if (length(files) == 0) return(empty)

  out <- data.frame(
    name = tools::file_path_sans_ext(basename(files)),
    path = files,
    ext  = tolower(tools::file_ext(files)),
    stringsAsFactors = FALSE
  )
  # 同一样本存在多种格式时保留第一个（与 Ms1Geter 的行为一致）
  out[!duplicated(out$name), , drop = FALSE]
}


# ------------------------------------------------------------
# 样品名归一化：小写 + 去掉扩展名/路径/空白与常见分隔符
# 让 "P173"、"p173 "、"P173.raw"、"G:/data/P173.mzML" 都能对上同一个文件
# ------------------------------------------------------------
rtg_norm_name <- function(x) {
  x <- as.character(x)
  x <- tolower(trimws(x))
  x <- basename(gsub("\\\\", "/", x))
  x <- sub("\\.(raw|mzml|mzxml)$", "", x)
  x <- gsub("[[:space:]_.-]+", "", x)
  x
}


# ------------------------------------------------------------
# 读取一个质谱文件的 MS1 扫描索引
#
# 返回 data.frame(scan, read_key, StartTime, scanType)：
#   scan     : 报告给用户的扫描号
#   read_key : 读谱时要用的键（.raw 用扫描号；mzML 用文件内行号）
#   StartTime: 保留时间，单位分钟
# ------------------------------------------------------------
rtg_ms1_index <- function(path) {

  ext <- tolower(tools::file_ext(path))

  if (identical(ext, "raw")) {

    idx <- rawrr::readIndex(path)

    # MSOrder 是最可靠的判据；老版本 rawrr 没有这一列时退回扫描类型字符串
    if ("MSOrder" %in% names(idx) && any(!is.na(idx$MSOrder))) {
      is_ms1 <- !is.na(idx$MSOrder) & idx$MSOrder == "Ms"
    } else {
      is_ms1 <- !is.na(idx$scanType) & idx$scanType == MS1_SCAN_TYPE
    }
    # 再兜一层：既没有 MSOrder、扫描类型也不是预期常量时，按 "Full ms" 判
    if (!any(is_ms1)) {
      is_ms1 <- !is.na(idx$scanType) &
        grepl("Full ms", idx$scanType, fixed = TRUE) &
        !grepl(" ms2 ", paste0(" ", idx$scanType), fixed = TRUE)
    }

    out <- data.frame(
      scan      = as.numeric(idx$scan),
      read_key  = as.numeric(idx$scan),
      StartTime = as.numeric(idx$StartTime),
      scanType  = as.character(idx$scanType),
      stringsAsFactors = FALSE
    )
    return(out[is_ms1 & !is.na(out$StartTime), , drop = FALSE])
  }

  if (ext %in% c("mzml", "mzxml")) {

    if (!requireNamespace("mzR", quietly = TRUE)) {
      stop("处理 .mzML/.mzXML 文件需要 mzR 包，请在 R 中运行: BiocManager::install(\"mzR\")")
    }

    ms <- mzR::openMSfile(path)
    on.exit(mzR::close(ms), add = TRUE)

    hdr <- mzR::header(ms)
    lv  <- as.integer(hdr$msLevel)

    keep <- !is.na(lv) & lv == 1L & !is.na(hdr$retentionTime)

    # 必须显式 return()：函数体最后的兜底是 stop()，
    # 若这里只是表达式的值，函数会继续往下走到 stop() 报"不支持的格式"。
    return(data.frame(
      scan      = as.numeric(hdr$seqNum)[keep],
      # mzR::peaks() 收的是文件内行号，不是 seqNum
      read_key  = which(keep),
      StartTime = as.numeric(hdr$retentionTime)[keep] / 60,
      scanType  = "ms1",
      stringsAsFactors = FALSE
    ))
  }

  stop("不支持的质谱文件格式: .", ext, "（支持 .raw / .mzML / .mzXML）")
}


# ------------------------------------------------------------
# 只读取指定扫描的谱图
# 返回 list，每个元素 list(mz, intensity)
# ------------------------------------------------------------
rtg_read_scans <- function(path, read_keys) {

  ext <- tolower(tools::file_ext(path))

  if (identical(ext, "raw")) {
    S <- rawrr::readSpectrum(rawfile = path, scan = read_keys, mode = "profile")
    return(lapply(S, function(x) {
      list(mz = as.numeric(x[["centroid.mZ"]]),
           intensity = as.numeric(x[["centroid.intensity"]]))
    }))
  }

  if (!requireNamespace("mzR", quietly = TRUE)) {
    stop("处理 .mzML/.mzXML 文件需要 mzR 包，请在 R 中运行: BiocManager::install(\"mzR\")")
  }

  ms <- mzR::openMSfile(path)
  on.exit(mzR::close(ms), add = TRUE)

  lapply(read_keys, function(k) {
    p <- mzR::peaks(ms, k)
    m <- as.numeric(p[, 1])
    v <- as.numeric(p[, 2])
    # profile 数据先质心化，否则同一离子的整段轮廓会被当成多个峰
    if (length(m) > 2 && looks_like_profile(m)) {
      cp <- centroid_profile_peaks(m, v)
      m  <- cp$mz
      v  <- cp$intensity
    }
    list(mz = m, intensity = v)
  })
}


# ------------------------------------------------------------
# 在一组已读出的谱里挑峰：区间内该 m/z 最强的那一张谱
#
# 参数：
#   spectra : rtg_read_scans() 的结果，顺序与 win 一一对应
#   win     : 窗口内的扫描索引（含 StartTime / scan）
#   mz / tol / unit : 目标质量与容差
#
# 返回 list(ok, status, rt, scan, mz_found, intensity, err_ppm, n_hit)
# ------------------------------------------------------------
rtg_pick_apex <- function(spectra, win, mz, tol, unit = "ppm") {

  best <- NULL
  n_hit <- 0L

  for (i in seq_along(spectra)) {

    sp <- spectra[[i]]
    if (is.null(sp) || length(sp$mz) == 0) next

    if (identical(unit, "Da")) {
      dist <- abs(sp$mz - mz)
    } else {
      dist <- abs(sp$mz - mz) / mz * 1e6
    }

    hit <- which(!is.na(dist) & dist <= tol)
    if (length(hit) == 0) next

    n_hit <- n_hit + 1L

    # 一张谱里可能有多于一个落在容差内的峰，取强度最高的那个
    j <- hit[which.max(sp$intensity[hit])]
    inten <- sp$intensity[j]

    # 严格大于才替换 -> 强度完全相同时保留更早的那张扫描
    if (is.null(best) || inten > best$intensity) {
      best <- list(
        rt        = win$StartTime[i],
        scan      = win$scan[i],
        mz_found  = sp$mz[j],
        intensity = inten
      )
    }
  }

  if (is.null(best)) {
    return(list(ok = FALSE, status = "no_peak", n_hit = 0L))
  }

  best$ok      <- TRUE
  best$status  <- "ok"
  best$err_ppm <- (best$mz_found - mz) / mz * 1e6
  best$n_hit   <- n_hit
  best
}


# ------------------------------------------------------------
# 单条查询（保留给脚本 / 单元测试用）
# ------------------------------------------------------------
rtg_query_apex <- function(path, index, mz, rt_min, tol, unit = "ppm") {

  lo <- rt_min - 1
  hi <- rt_min

  if (is.null(index) || nrow(index) == 0) {
    return(list(ok = FALSE, status = "no_index",
                message = "该文件里没有读到任何 MS1 扫描。"))
  }

  win <- index[index$StartTime > lo & index$StartTime <= hi, , drop = FALSE]

  if (nrow(win) == 0) {
    return(list(ok = FALSE, status = "empty_window",
                message = sprintf("区间 (%.3f, %.3f] 分钟内没有 MS1 扫描。", lo, hi),
                n_scan = 0))
  }

  win <- win[order(win$StartTime), , drop = FALSE]
  spectra <- rtg_read_scans(path, win$read_key)

  res <- rtg_pick_apex(spectra, win, mz, tol, unit)
  res$n_scan <- nrow(win)

  if (isTRUE(res$ok)) {
    res$message <- "ok"
  } else {
    res$message <- sprintf(
      "区间 (%.3f, %.3f] 内的 %d 张 MS1 谱中，没有落在 %.4f ± %s %s 范围内的峰。",
      lo, hi, nrow(win), mz,
      format(tol, trim = TRUE, scientific = FALSE), unit)
  }
  res
}


# ============================================================
# 表格读取与列识别
# ============================================================

# 判断一段文本是否是合法 UTF-8（用于区分 UTF-8 与 GB18030 的表格）
rtg_is_utf8 <- function(path, n_lines = 200L) {
  ln <- tryCatch(readLines(path, n = n_lines, warn = FALSE),
                 error = function(e) character(0))
  if (length(ln) == 0) return(TRUE)
  isTRUE(validUTF8(paste(ln, collapse = "\n")))
}

# 读取峰表 -> data.frame（全部按字符读进来，后续自己转数值，
# 以免峰 id 被 Excel 转成 1、1.0 这类不一致的表示）
rtg_read_table <- function(path) {

  ext <- tolower(tools::file_ext(path))

  if (ext %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop("读取 Excel 需要 readxl 包。")
    }
    df <- readxl::read_excel(path, sheet = 1, col_types = "text")
    df <- as.data.frame(df, stringsAsFactors = FALSE, check.names = FALSE)
    names(df) <- trimws(names(df))
    return(df)
  }

  if (!ext %in% c("csv", "tsv", "txt")) {
    stop("不支持的表格格式: .", ext,
         "（支持 .xlsx / .xls / .csv / .tsv / .txt）")
  }

  # 分隔符：扩展名优先；.txt 按首行里制表符与逗号的出现情况判断
  sep <- if (ext == "tsv") {
    "\t"
  } else if (ext == "csv") {
    ","
  } else {
    l1 <- tryCatch(readLines(path, n = 1L, warn = FALSE),
                   error = function(e) "")
    if (length(l1) && grepl("\t", l1[1], fixed = TRUE) &&
        !grepl(",", l1[1], fixed = TRUE)) "\t" else ","
  }

  enc <- if (rtg_is_utf8(path)) "UTF-8-BOM" else "GB18030"

  df <- suppressWarnings(tryCatch(
    utils::read.table(path, sep = sep, header = TRUE, quote = "\"",
                      comment.char = "", colClasses = "character",
                      check.names = FALSE, stringsAsFactors = FALSE,
                      fileEncoding = enc, na.strings = character(0)),
    error = function(e) NULL))

  if (is.null(df) || ncol(df) == 0) {
    stop("表格读取失败（分隔符或编码无法识别）：", basename(path))
  }

  names(df) <- trimws(names(df))
  df
}

# 列名归一化：小写 + 去掉空白与标点
# （"RT_min" -> "rtmin"、"峰 id" -> "峰id"、"m/z" -> "mz"）
rtg_norm_colname <- function(x) {
  x <- tolower(as.character(x))
  x <- gsub("[[:space:][:punct:]]", "", x)
  gsub("\uff1a", "", x, fixed = TRUE)   # 全角冒号不落在 [:punct:] 里
}

# 各字段的候选列名，**按优先级排列**（靠前的优先）
.rtg_col_alias <- list(
  id     = c("峰id", "峰编号", "峰序号", "峰号", "peakid", "featureid",
             "peakno", "id", "编号", "序号"),
  sample = c("样品名称", "样本名称", "样品名", "样本名", "samplename",
             "sampleid", "sample", "样品", "样本", "name", "filename", "文件名称"),
  mz     = c("mz", "mz值", "目标mz", "母离子mz", "母离子", "质荷比",
             "precursormz", "mass"),
  rt_min = c("rtmin", "rt分钟", "保留时间分钟", "rtmin值", "rtmin整数", "分钟")
)

# 按别名优先级找一列；返回列下标，找不到返回 NA
rtg_find_col <- function(nm_norm, aliases) {
  for (a in aliases) {
    h <- which(nm_norm == a)
    if (length(h)) return(h[1])
  }
  # 完全没命中时退一步做包含匹配（别名太短容易误伤，要求 >= 3 字符且唯一命中）
  for (a in aliases[nchar(aliases) >= 3]) {
    h <- which(grepl(a, nm_norm, fixed = TRUE))
    if (length(h) == 1L) return(h[1])
  }
  NA_integer_
}

# 自动识别四列；识别不全就按位置回退（前四列）
rtg_detect_cols <- function(df) {

  if (is.null(df) || ncol(df) < 4) return(NULL)

  nn <- rtg_norm_colname(names(df))
  idx <- c(id     = rtg_find_col(nn, .rtg_col_alias$id),
           sample = rtg_find_col(nn, .rtg_col_alias$sample),
           mz     = rtg_find_col(nn, .rtg_col_alias$mz),
           rt_min = rtg_find_col(nn, .rtg_col_alias$rt_min))

  auto <- !anyNA(idx) && !anyDuplicated(idx)
  if (!auto) idx <- c(id = 1L, sample = 2L, mz = 3L, rt_min = 4L)

  list(id = unname(idx[["id"]]), sample = unname(idx[["sample"]]),
       mz = unname(idx[["mz"]]), rt_min = unname(idx[["rt_min"]]),
       names = c(id = names(df)[idx[["id"]]],
                 sample = names(df)[idx[["sample"]]],
                 mz = names(df)[idx[["mz"]]],
                 rt_min = names(df)[idx[["rt_min"]]]),
       auto = auto)
}

# 字符 -> 数值（容忍前后空白与千分位逗号）
rtg_num <- function(x) {
  x <- gsub("[[:space:],]", "", as.character(x))
  suppressWarnings(as.numeric(x))
}


# ============================================================
# 批量主流程
#
# df    : 峰表（原始 data.frame）
# cols  : rtg_detect_cols() 的结果（或用户手动指定后的同构 list）
# files : rtg_list_ms_files() 的结果
#
# 返回 list(result = 输入 + RT 列, diag = 诊断表, log = 日志行)
# ============================================================
rtg_run_batch <- function(df, cols, files, tol, unit = "ppm", progress = NULL) {

  n <- nrow(df)
  logs <- character(0)
  say <- function(...) logs <<- c(logs, sprintf(...))

  diag <- data.frame(
    Peak_ID   = as.character(df[[cols$id]]),
    Sample    = as.character(df[[cols$sample]]),
    MZ        = rtg_num(df[[cols$mz]]),
    RT_min    = rtg_num(df[[cols$rt_min]]),
    Window    = NA_character_,
    Status    = NA_character_,
    RT        = NA_real_,
    Intensity = NA_real_,
    Scan      = NA_real_,
    MZ_found  = NA_real_,
    Error_ppm = NA_real_,
    MS1_scans = NA_integer_,
    Scans_hit = NA_integer_,
    File      = NA_character_,
    stringsAsFactors = FALSE
  )

  # ---- 前置校验：样品名、RT_min、MZ ----
  skey <- rtg_norm_name(diag$Sample)
  bad_sample <- is.na(skey) | !nzchar(skey)
  if (any(bad_sample)) {
    diag$Status[bad_sample] <- "bad_sample"
    say("⚠️ %d 行的样品名称为空，已跳过。", sum(bad_sample))
  }

  bad_rt <- !bad_sample & (is.na(diag$RT_min) | !is.finite(diag$RT_min) | diag$RT_min <= 0)
  if (any(bad_rt)) {
    diag$Status[bad_rt] <- "bad_rt_min"
    say("⚠️ %d 行的 RT_min 不是正数，已跳过。", sum(bad_rt))
  }

  bad_mz <- !bad_sample & !bad_rt & (is.na(diag$MZ) | !is.finite(diag$MZ) | diag$MZ <= 0)
  if (any(bad_mz)) {
    diag$Status[bad_mz] <- "bad_mz"
    say("⚠️ %d 行的 MZ 不是正数，已跳过。", sum(bad_mz))
  }

  todo <- !bad_sample & !bad_rt & !bad_mz

  # ---- 样品名 -> 文件路径 ----
  fkeys <- rtg_norm_name(files$name)
  fmap  <- stats::setNames(files$path, fkeys)

  resolve_file <- function(k) {
    if (is.na(k) || !nzchar(k)) return(NA_character_)
    if (k %in% fkeys) return(fmap[[k]])
    # 唯一前缀 / 后缀 / 包含匹配（"P173" 能对上 "P173_rep1"）
    h <- fkeys[startsWith(fkeys, k) | endsWith(fkeys, k) |
                 grepl(k, fkeys, fixed = TRUE)]
    if (length(h) == 1L) return(fmap[[h]])
    NA_character_
  }

  total_steps <- max(1L, sum(todo))
  done_steps  <- 0L
  tick <- function(k, detail = NULL) {
    done_steps <<- done_steps + k
    if (is.function(progress)) progress(done_steps, total_steps, detail)
  }

  samples <- unique(skey[todo])

  for (s in samples) {

    rows_s <- which(skey == s & todo)
    path <- resolve_file(s)

    if (is.na(path)) {
      diag$Status[rows_s] <- "sample_not_found"
      say("❌ 样品 %s：目录内找不到对应文件。", diag$Sample[rows_s[1]])
      tick(length(rows_s))
      next
    }

    diag$File[rows_s] <- basename(path)
    n_samples_done <- length(rows_s)

    idx <- tryCatch(rtg_ms1_index(path), error = function(e) {
      say("❌ %s：读取索引失败 —— %s", basename(path), conditionMessage(e))
      NULL
    })

    if (is.null(idx) || nrow(idx) == 0) {
      diag$Status[rows_s] <- "no_index"
      tick(n_samples_done)
      next
    }

    diag$MS1_scans[rows_s] <- nrow(idx)

    # 同一样品内按 RT_min 分组，一个窗口只读一次谱
    rtv <- diag$RT_min[rows_s]
    gkey <- format(rtv, trim = TRUE, scientific = FALSE)
    for (g in unique(gkey)) {

      rows_g <- rows_s[gkey == g]
      rt_min <- rtv[gkey == g][1]
      lo <- rt_min - 1
      hi <- rt_min

      diag$Window[rows_g] <- sprintf("(%.3f, %.3f]", lo, hi)

      win <- idx[idx$StartTime > lo & idx$StartTime <= hi, , drop = FALSE]

      if (nrow(win) == 0) {
        diag$Status[rows_g] <- "empty_window"
        diag$MS1_scans[rows_g] <- 0L
        say("⚠️ %s：区间 %s 内没有 MS1 扫描。", basename(path),
            diag$Window[rows_g[1]])
        tick(length(rows_g))
        next
      }

      win <- win[order(win$StartTime), , drop = FALSE]
      diag$MS1_scans[rows_g] <- nrow(win)

      spectra <- tryCatch(rtg_read_scans(path, win$read_key), error = function(e) {
        say("❌ %s：读取谱图失败 —— %s", basename(path), conditionMessage(e))
        NULL
      })

      if (is.null(spectra)) {
        diag$Status[rows_g] <- "read_error"
        tick(length(rows_g))
        next
      }

      for (r in rows_g) {
        a <- rtg_pick_apex(spectra, win, diag$MZ[r], tol, unit)
        diag$Status[r]   <- a$status
        diag$Scans_hit[r] <- as.integer(a$n_hit)
        if (isTRUE(a$ok)) {
          diag$RT[r]        <- a$rt
          diag$Intensity[r] <- a$intensity
          diag$Scan[r]      <- a$scan
          diag$MZ_found[r]  <- a$mz_found
          diag$Error_ppm[r] <- a$err_ppm
        }
      }

      tick(length(rows_g), detail = sprintf("%s · %s", basename(path),
                                            diag$Window[rows_g[1]]))
    }

    say("✅ %s：%d 张 MS1 扫描，%d 行查询。", basename(path), nrow(idx),
        n_samples_done)
  }

  # ---- 组装输出：输入原有各列 + RT ----
  out <- df
  rt_col <- "RT"
  if (rt_col %in% names(out)) rt_col <- "RT_RtGeter"
  out[[rt_col]] <- diag$RT

  n_ok <- sum(!is.na(diag$RT))
  say("完成：%d 行，成功 %d 行，未命中 %d 行。", n, n_ok, n - n_ok)

  list(result = out, diag = diag, log = logs)
}


# ============================================================
# RtGeter 运行日志落盘
#
# 原来日志只写进 reactiveVal（页面那个「运行日志」框），刷新页面或重启
# 应用就没了，事后想复盘只能重跑一遍。这里额外写一份到
# .workbuddy/logs/rgeter/ 下，同时镜像到控制台（shiny 启动日志）。
# 任何写盘异常都被 tryCatch 吞掉，绝不影响主流程。
# ============================================================
RTG_LOG_DIR <- file.path(".workbuddy", "logs", "rgeter")

rtg_file_logger <- function() {
  path <- NULL
  function(lines) {
    if (length(lines) == 0L) return(invisible(NULL))
    tryCatch({
      if (is.null(path)) {
        dir.create(RTG_LOG_DIR, recursive = TRUE, showWarnings = FALSE)
        path <<- file.path(RTG_LOG_DIR, sprintf(
          "rgeter_%s_pid%d.log",
          format(Sys.time(), "%Y%m%d_%H%M%S"), Sys.getpid()))
        writeLines(enc2utf8(sprintf("# RtGeter session @ %s",
                                    format(Sys.time(), "%Y-%m-%d %H:%M:%S"))),
                   path, useBytes = TRUE)
      }
      cat(enc2utf8(lines), file = path, sep = "\n", append = TRUE)
      cat(enc2utf8(lines), sep = "\n", file = stderr())
    }, error = function(e) invisible(NULL))
    invisible(path)
  }
}


# ============================================================
# RtGeter module
# ============================================================
RtGeter_server <- function(id) {

  moduleServer(id, function(input, output, session) {

    log_text <- reactiveVal("")
    write_log_file <- rtg_file_logger()
    append_log <- function(msg) {
      if (length(msg) == 0) return(invisible(NULL))
      stamp <- format(Sys.time(), "[%H:%M:%S] ")
      log_text(paste0(log_text(), paste0(stamp, msg, "\n", collapse = "")))
      write_log_file(paste0(stamp, msg))
    }
    output$log <- renderText(log_text())

    output$dl_log <- downloadHandler(
      filename = function() sprintf("RtGeter_log_%s.txt",
                                    format(Sys.time(), "%Y%m%d_%H%M%S")),
      content = function(file) writeLines(enc2utf8(log_text()), file, useBytes = TRUE)
    )

    # ---------------- 目录内的质谱文件 ----------------
    files <- reactive({
      rtg_list_ms_files(input$workdir)
    })

    observeEvent(files(), {
      f <- files()
      if (nrow(f) == 0) {
        append_log("⚠️ 原始数据文件夹内未找到 .raw / .mzML / .mzXML。")
      } else {
        append_log(sprintf("发现 %d 个质谱文件：%s%s", nrow(f),
                           paste(utils::head(f$name, 6), collapse = ", "),
                           if (nrow(f) > 6) " …" else ""))
      }
    }, ignoreNULL = FALSE)

    # ---------------- 峰表 ----------------
    tbl <- reactive({
      up <- input$peak_table
      if (is.null(up) || nrow(up) == 0) return(NULL)
      tryCatch(rtg_read_table(up$datapath[1]), error = function(e) {
        append_log(paste("❌ 表格读取失败：", conditionMessage(e)))
        NULL
      })
    })

    observeEvent(tbl(), {
      df <- tbl()
      if (is.null(df)) return(invisible(NULL))
      if (ncol(df) < 4) {
        append_log(sprintf("❌ 峰表只有 %d 列，至少需要四列（峰 id / 样品名称 / MZ / RT_min）。",
                           ncol(df)))
        return(invisible(NULL))
      }
      append_log(sprintf("峰表：%d 行 × %d 列 —— %s", nrow(df), ncol(df),
                         paste(names(df), collapse = " | ")))
    }, ignoreNULL = TRUE)

    # 自动识别出的列映射，作为下列下拉框的初值
    auto_cols <- reactive({
      df <- tbl()
      if (is.null(df)) return(NULL)
      rtg_detect_cols(df)
    })

    output$file_info <- renderUI({
      up <- input$peak_table
      if (is.null(up) || nrow(up) == 0) return(NULL)
      df <- tbl()
      n <- if (is.null(df)) "读取失败" else sprintf("%d 行 × %d 列", nrow(df), ncol(df))
      div(class = "rtg-meta", sprintf("%s · %s", up$name[1], n))
    })

    # ---------------- 列映射 ----------------
    output$col_map <- renderUI({
      df <- tbl()
      if (is.null(df)) {
        return(div(class = "hint-neutral",
                   icon("circle-info"),
                   span("上传峰表后会自动识别四列，可在此手动纠正。")))
      }
      ac <- auto_cols()
      nm <- names(df)
      pick <- function(id, label, sel) {
        selectInput(session$ns(id), label, choices = nm, selected = sel,
                    width = "100%")
      }
      tagList(
        fluidRow(
          column(6, pick("col_id",     "Peak ID",   ac$names[["id"]])),
          column(6, pick("col_sample", "Sample",    ac$names[["sample"]]))
        ),
        fluidRow(
          column(6, pick("col_mz",     "MZ",        ac$names[["mz"]])),
          column(6, pick("col_rtmin",  "RT_min",    ac$names[["rt_min"]]))
        ),
        if (!isTRUE(ac$auto)) {
          format_hint("列名没能全部自动识别，已按前四列顺序预填，请核对。",
                      "triangle-exclamation", "warning")
        }
      )
    })

    # 用户确认后的列下标
    user_cols <- reactive({
      df <- tbl()
      if (is.null(df)) return(NULL)
      p <- function(x) {
        i <- match(as.character(x), names(df))
        if (is.na(i)) NA_integer_ else i
      }
      idx <- c(id = p(input$col_id), sample = p(input$col_sample),
               mz = p(input$col_mz), rt_min = p(input$col_rtmin))
      if (anyNA(idx)) return(NULL)
      # names 必须逐项按名构造：names(df)[idx] 取子集后名字会丢，
      # 后面 cols$names[["id"]] 就会越界。
      list(id = unname(idx[["id"]]), sample = unname(idx[["sample"]]),
           mz = unname(idx[["mz"]]), rt_min = unname(idx[["rt_min"]]),
           names = c(id     = names(df)[idx[["id"]]],
                     sample = names(df)[idx[["sample"]]],
                     mz     = names(df)[idx[["mz"]]],
                     rt_min = names(df)[idx[["rt_min"]]]),
           auto = TRUE)
    })

    # ---------------- MS1 索引缓存 ----------------
    idx_store <- reactiveVal(list())

    get_index <- function(path) {
      key <- paste0(normalizePath(path, winslash = "/", mustWork = FALSE),
                    "|", as.numeric(file.info(path)$mtime))
      store <- idx_store()
      if (!is.null(store[[key]])) return(store[[key]])

      idx <- rtg_ms1_index(path)

      # 只保留最近 4 个文件的索引，避免缓存无限增长
      store[[key]] <- idx
      if (length(store) > 4) store <- store[tail(seq_along(store), 4)]
      idx_store(store)
      idx
    }

    # ---------------- 运行结果 ----------------
    result <- reactiveVal(NULL)
    running <- reactiveVal(FALSE)

    observeEvent(input$run, {

      df <- tbl()
      if (is.null(df)) {
        append_log("❌ 请先上传峰表。")
        return(invisible(NULL))
      }

      f <- files()
      if (nrow(f) == 0) {
        append_log("❌ 原始数据文件夹无效，或其中没有 .raw / .mzML / .mzXML。")
        return(invisible(NULL))
      }

      cols <- user_cols()
      if (is.null(cols)) {
        append_log("❌ 列映射不完整，请在上方为四个字段各选一列。")
        return(invisible(NULL))
      }

      tol <- input$tol
      if (is.null(tol) || is.na(tol) || !is.finite(tol) || tol <= 0) {
        append_log("❌ 质量容差必须大于 0。")
        return(invisible(NULL))
      }
      unit <- if (identical(input$tol_unit, "Da")) "Da" else "ppm"

      append_log(sprintf("开始：%d 行 | 四列 = %s / %s / %s / %s | 容差 %s %s",
                         nrow(df), cols$names[["id"]], cols$names[["sample"]],
                         cols$names[["mz"]], cols$names[["rt_min"]],
                         format(tol, trim = TRUE, scientific = FALSE), unit))

      running(TRUE)
      on.exit(running(FALSE), add = TRUE)

      out <- NULL
      withProgress(message = "RtGeter", detail = "准备中…", value = 0, {
        pg <- function(done, total, detail = NULL) {
          setProgress(
            value  = if (isTRUE(total > 0)) min(1, done / total) else 0,
            detail = if (is.null(detail)) "" else detail
          )
        }
        # 注意：withProgress 的表达式在**调用者环境**求值，
        # 所以这里用普通赋值即可，写成 <<- 反而会跑到全局变量里去。
        out <- tryCatch(
          rtg_run_batch(df, cols, f, tol, unit, progress = pg),
          error = function(e) {
            append_log(paste("❌ 运行失败：", conditionMessage(e)))
            NULL
          })
      })

      if (is.null(out)) return(invisible(NULL))

      append_log(out$log)
      result(out)
    })

    observeEvent(input$clear, {
      result(NULL)
      log_text("")
    })

    # ---------------- 摘要 ----------------
    output$summary_box <- renderUI({

      r <- result()
      if (is.null(r)) {
        return(div(class = "status-box status-info",
                   icon("circle-info"),
                   span("上传峰表、指定原始数据文件夹，然后点击 Run。")))
      }

      d <- r$diag
      n <- nrow(d)
      n_ok <- sum(!is.na(d$RT))
      n_win <- sum(d$Status == "empty_window", na.rm = TRUE)
      n_peak <- sum(d$Status == "no_peak", na.rm = TRUE)
      n_smp <- sum(d$Status == "sample_not_found", na.rm = TRUE)
      n_bad <- sum(d$Status %in% c("bad_sample", "bad_mz", "bad_rt_min",
                                   "no_index", "read_error"), na.rm = TRUE)

      pct <- if (n > 0) sprintf("%.1f%%", 100 * n_ok / n) else "—"

      div(class = "rtg-result",
        div(class = "rtg-hero",
          span(class = "rtg-hero__label", "Resolved"),
          span(class = "rtg-hero__value", n_ok),
          span(class = "rtg-hero__unit", sprintf("/ %d 行 · %s", n, pct))
        ),
        div(class = "kv-grid",
          div(class = "kv", span(class = "kv__k", "No peak in window"),
              span(class = "kv__v", n_peak)),
          div(class = "kv", span(class = "kv__k", "Empty window"),
              span(class = "kv__v", n_win)),
          div(class = "kv", span(class = "kv__k", "Sample not found"),
              span(class = "kv__v", n_smp)),
          div(class = "kv", span(class = "kv__k", "Bad / unreadable"),
              span(class = "kv__v", n_bad))
        )
      )
    })

    # ---------------- 预览表 ----------------
    # 预览里额外带一列状态，方便定位没算出来的行；
    # 导出的文件严格是「输入各列 + RT」。
    preview <- reactive({
      r <- result()
      if (is.null(r)) return(NULL)
      df <- r$result
      chk <- "Status"
      while (chk %in% names(df)) chk <- paste0(chk, "_")
      df[[chk]] <- r$diag$Status
      utils::head(df, 2000)
    })

    output$preview_empty <- renderUI({
      if (!is.null(result())) return(NULL)
      p(class = "text-muted",
        "运行后在这里预览结果。导出文件为「输入各列 + RT」，不加任何诊断列。")
    })

    output$preview <- DT::renderDataTable({
      df <- preview()
      if (is.null(df)) return(NULL)
      rt_col <- if ("RT" %in% names(df)) "RT" else "RT_RtGeter"
      # preview() 把状态列追加在最后一列
      chk <- names(df)[ncol(df)]

      dt <- DT::datatable(
        df,
        rownames = FALSE,
        options = list(pageLength = 15, dom = "tip", scrollX = TRUE),
        class = "compact stripe"
      )
      if (rt_col %in% names(df)) dt <- DT::formatRound(dt, rt_col, 4)
      if (nzchar(chk) && chk %in% names(df)) {
        dt <- DT::formatStyle(
          dt, chk,
          backgroundColor = DT::styleEqual(
            c("ok", "no_peak", "empty_window", "sample_not_found",
              "bad_sample", "bad_mz", "bad_rt_min", "no_index", "read_error"),
            c("#ecfdf5", "#fef2f2", "#fffbeb", "#fef2f2",
              "#fef2f2", "#fef2f2", "#fef2f2", "#fef2f2", "#fef2f2")
          ),
          color = DT::styleEqual(
            c("ok", "no_peak", "empty_window", "sample_not_found",
              "bad_sample", "bad_mz", "bad_rt_min", "no_index", "read_error"),
            c("#0b6b45", "#991b1b", "#92400e", "#991b1b",
              "#991b1b", "#991b1b", "#991b1b", "#991b1b", "#991b1b")
          )
        )
      }
      dt
    })

    # ---------------- 下载 ----------------
    stamp <- function() format(Sys.time(), "%Y%m%d_%H%M%S")

    output$dl_csv <- downloadHandler(
      filename = function() paste0("RtGeter_", stamp(), ".csv"),
      content  = function(file) {
        r <- result(); req(r)
        # 先写临时文件，再在前面补 UTF-8 BOM：
        # 中文 Windows 的 Excel 双击打开不带 BOM 的 UTF-8 CSV 会乱码。
        tmp <- tempfile(fileext = ".csv")
        on.exit(unlink(tmp), add = TRUE)
        utils::write.csv(r$result, tmp, row.names = FALSE, na = "",
                         fileEncoding = "UTF-8")
        raw <- readBin(tmp, what = "raw", n = file.size(tmp))
        con <- file(file, open = "wb")
        on.exit(close(con), add = TRUE)
        writeBin(c(as.raw(c(0xEF, 0xBB, 0xBF)), raw), con)
      }
    )

    output$dl_xlsx <- downloadHandler(
      filename = function() paste0("RtGeter_", stamp(), ".xlsx"),
      content  = function(file) {
        r <- result(); req(r)
        writexl::write_xlsx(
          list(Results = r$result, Diagnostics = r$diag), file)
      }
    )
  })
}

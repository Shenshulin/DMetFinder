# ============================================================
# cli/lib/msg_extract.R -- msg-extract：MS1 分钟桶 / MS2 扫描表 / MSP
# ------------------------------------------------------------
# 对应界面：MSGeter › Ms1Geter（FeatureGeter_server.R 第 481–862 行）
#
# 与界面版的三处差异，都是为了让它可以无人值守地跑：
#   1. 产物路径参数化。界面版硬编码 "MS2_MGF" 与 "MS2_Group_Info.csv"，
#      直接写到进程当前目录；CLI 必须写进 --out，否则会污染调用方目录。
#   2. 去卷积走向量化实现（结果等价，约 50 倍快），--slow-deconv 可切回
#      上游 R 循环版做审计。等价性由 tests/agent/test_msg_equiv.R 验证。
#   3. MS1 表按"长表"输出（一行一个峰），而不是界面的 6 列块并排。
#      CSV 没有视觉分组的需要，长表才能被 pandas / fread / MS-DIAL 直接吃。
#      --xlsx 仍按原块式写，方便回灌界面与 diff。
# ============================================================

msx_default_params <- function() {
  list(
    rt_min        = 1,        # 实际采集时间下限（分钟）；输出 RT = 该值 + 1
    rt_max        = 18,       # 实际采集时间上限（分钟）
    max_mz        = 1500,     # 去卷积 m/z 上限（与上游一致）
    min_intensity = 10000,    # 去卷积后强度下限（与上游硬编码一致）
    ppm           = 10,       # 去卷积 ppm 窗口（与上游一致）
    ms2_group_gap = 0.9       # MS2 前体 m/z 分组间隔（与上游一致）
  )
}

# ------------------------------------------------------------
# 去卷积：clean_spectrum_keep_max 的向量化等价实现
#
# 上游算法（FeatureGeter_server.R 第 208–226 行）：按 m/z 升序，以组首为锚点，
# 只要 mz[j] - mz[anchor] < tol(anchor) 就并入同组，取组内最强峰，然后
# 从第一个不满足的下标继续。因为已按 m/z 升序排列且阈值只依赖锚点，整组
# 必然是 [anchor, hi] 的连续区间，hi 可以用一次二分查找得到——这正是
# findInterval() 做的事。因此这里不是近似，是同一算法的闭式写法。
# ------------------------------------------------------------
msx_clean_fast <- function(peaks, min_mz = 0, max_mz = 1500, ppm = 10,
                           da = -1, min_intensity = 0) {
  peaks <- as.matrix(peaks)
  if (nrow(peaks) == 0L) return(peaks)

  # 前两列固定按 mz / intensity 解释；若输入带有额外列（如 rt_scan），
  # 一律原样保留——去卷积只挑行，不生成新行，所以额外列跟着选中行走。
  cn <- colnames(peaks)
  if (length(cn) < 2L) stop("peaks 至少需要 mz / intensity 两列")
  cn[1L] <- "mz"
  cn[2L] <- "intensity"
  colnames(peaks) <- cn

  ok <- peaks[, "mz"] > 0 & peaks[, "intensity"] > 0
  peaks <- peaks[ok, , drop = FALSE]
  if (nrow(peaks) == 0L) return(peaks)

  if (min_mz > 0) peaks <- peaks[peaks[, "mz"] >= min_mz, , drop = FALSE]
  if (max_mz > 0) peaks <- peaks[peaks[, "mz"] <= max_mz, , drop = FALSE]
  if (nrow(peaks) == 0L) return(peaks)

  peaks <- peaks[order(peaks[, "mz"]), , drop = FALSE]
  mz <- peaks[, "mz"]
  it <- peaks[, "intensity"]
  n  <- length(mz)

  idx <- integer(n)
  m <- 0L
  i <- 1L
  p <- 0L          # 上一组结束的位置；阈值随锚点单调递增，故 p 只前进不后退
  while (i <= n) {
    thr <- if (da > 0) mz[i] + da else mz[i] * (1 + ppm * 1e-6)
    if (p < i) p <- i - 1L
    # 找最后一个 mz < thr 的下标（上游用的是严格小于）
    while (p < n && mz[p + 1L] < thr) p <- p + 1L
    hi <- if (p >= i) p else i
    m <- m + 1L
    idx[m] <- i + which.max(it[i:hi]) - 1L
    i <- hi + 1L
  }

  out <- peaks[idx[seq_len(m)], , drop = FALSE]
  if (min_intensity > 0) out <- out[out[, "intensity"] > min_intensity, , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' 统一的去卷积入口：默认向量化，slow=TRUE 走上游实现
#'
#' peaks 可以带额外列（如每峰所属扫描的 RT）。快速路径直接按行下标取子集，
#' 额外列自动跟着走；上游 Java 同款实现只认两列，故先按 (mz, intensity)
#' 精确回接，接不上就报错，避免静默错位。
msx_deconvolve <- function(core, peaks, prm, slow = FALSE) {
  cn <- colnames(peaks)
  extra <- setdiff(cn, c("mz", "intensity"))
  if (!isTRUE(slow) || length(extra) == 0L) {
    if (isTRUE(slow)) {
      return(core$clean_spectrum_keep_max(
        peaks, min_mz = 0, max_mz = prm$max_mz, noise_threshold = 0,
        min_ms2_difference_in_da = -1,
        min_ms2_difference_in_ppm = prm$ppm,
        max_peak_num = -1, normalize_intensity = FALSE
      ))
    }
    return(msx_clean_fast(peaks, min_mz = 0, max_mz = prm$max_mz, ppm = prm$ppm))
  }

  keep <- core$clean_spectrum_keep_max(
    peaks[, c("mz", "intensity"), drop = FALSE], min_mz = 0,
    max_mz = prm$max_mz, noise_threshold = 0,
    min_ms2_difference_in_da = -1,
    min_ms2_difference_in_ppm = prm$ppm,
    max_peak_num = -1, normalize_intensity = FALSE
  )
  key_in  <- paste(as.numeric(peaks$mz), as.numeric(peaks$intensity), sep = "|")
  key_out <- paste(as.numeric(keep[, 1L]), as.numeric(keep[, 2L]), sep = "|")
  idx <- match(key_out, key_in)
  if (anyNA(idx) || anyDuplicated(key_in[idx[!is.na(idx)]])) {
    stop("slow 模式无法按 (mz, intensity) 回接额外列，请改用快速路径")
  }
  cbind(keep, peaks[idx, extra, drop = FALSE])
}

# ------------------------------------------------------------
# MS2 扫描表：按前体 m/z 升序后，相邻差值超过 gap 就换组
# 与界面版一致（含 NA 前体的处理：NA 留在当前组，阈值由首个非 NA 播种）
# ------------------------------------------------------------
msx_ms2_table <- function(st, sample_id, gap = 0.9) {
  if (nrow(st) == 0L) {
    return(data.frame(scan = numeric(0), StartTime = numeric(0),
                      scanType = character(0), ms2_value = numeric(0),
                      group = numeric(0), Sample = character(0),
                      stringsAsFactors = FALSE))
  }

  sel <- !is.na(st$msLevel) & st$msLevel == 2
  d <- st[sel, , drop = FALSE]
  if (nrow(d) == 0L) {
    return(data.frame(scan = numeric(0), StartTime = numeric(0),
                      scanType = character(0), ms2_value = numeric(0),
                      group = numeric(0), Sample = character(0),
                      stringsAsFactors = FALSE))
  }
  # dplyr::arrange 把 NA 排最后，base 的 order() 默认也是 na.last=TRUE
  d <- d[order(d$ms2_value), , drop = FALSE]

  v <- as.numeric(d$ms2_value)
  n <- length(v)
  groups <- numeric(n)
  current <- 1
  fv <- which(!is.na(v))
  threshold <- if (length(fv) > 0L) v[fv[1L]] + gap else Inf
  for (k in seq_len(n)) {
    vk <- v[k]
    if (!is.na(vk) && vk > threshold) {
      current <- current + 1
      threshold <- vk + gap
    }
    groups[k] <- current
  }

  data.frame(
    scan      = as.numeric(d$scan),
    StartTime = as.numeric(d$StartTime),
    scanType  = as.character(d$scanType),
    ms2_value = v,
    group     = groups,
    Sample    = rep(sample_id, n),
    stringsAsFactors = FALSE
  )
}

# ------------------------------------------------------------
# MS1：同一分钟桶内的所有 MS1 扫描合并 -> 去卷积 -> 强度过滤 -> RT = 桶号+1
# ------------------------------------------------------------
msx_ms1_table <- function(core, st, spectra, prm, sample_id, slow = FALSE) {
  empty <- data.frame(Sample = character(0), RT = numeric(0),
                      RT_mz = numeric(0), mz = numeric(0),
                      intensity = numeric(0), RT_apex = numeric(0),
                      stringsAsFactors = FALSE)

  is1 <- which(!is.na(st$msLevel) & as.integer(st$msLevel) == 1L)
  if (length(is1) == 0L) return(empty)

  labels <- floor(as.numeric(st$StartTime[is1]))
  chunks <- list()
  keys_of <- as.character(labels)

  for (k in seq_along(is1)) {
    i <- is1[k]
    spec <- spectra[[as.character(st$scan[i])]]
    if (is.null(spec) || is.null(spec$mz) || length(spec$mz) == 0L) next
    key <- keys_of[k]
    # rt_scan：这条质心来自哪张扫描。去卷积按行取子集，因此 RT_apex 会跟着
    # 被选中的那条峰走 —— F3 的亚分钟 RT 就来自这里，不需要二次读谱。
    chunks[[key]][[length(chunks[[key]]) + 1L]] <-
      data.frame(mz = spec$mz, intensity = spec$intensity,
                 rt_scan = as.numeric(st$StartTime[i]))
  }
  if (length(chunks) == 0L) return(empty)

  cleaned <- list()
  for (key in names(chunks)) {
    peaks <- do.call(rbind, chunks[[key]])
    if (is.null(peaks) || nrow(peaks) < 2L) next
    mat <- msx_deconvolve(core, peaks, prm, slow)
    if (nrow(mat) == 0L) next
    df <- data.frame(mz = as.numeric(mat[, "mz"]),
                     intensity = as.numeric(mat[, "intensity"]),
                     stringsAsFactors = FALSE)
    # RT_apex：簇内最强峰所属扫描的保留时间（分钟，亚分钟精度）。
    # 上游实现拿不到它时填 NA，下游按缺失处理。
    df$RT_apex <- if ("rt_scan" %in% colnames(mat)) {
      as.numeric(mat[, "rt_scan"])
    } else {
      NA_real_
    }
    df <- df[df$intensity > prm$min_intensity, , drop = FALSE]
    df$RT <- as.numeric(key) + 1
    cleaned[[key]] <- df
  }
  rm(chunks)
  if (length(cleaned) == 0L) return(empty)

  # rt_min / rt_max 是「实际采集时间」，不是写进 RT 列的值。
  # RT 列 = 桶号 + 1（桶号覆盖 (桶号, 桶号+1]），所以实际 1-10 min 输出 RT 2-11。
  b_from <- ceiling(prm$rt_min)
  b_to   <- floor(prm$rt_max)
  # 窗口窄到取不出整数分钟（如 1.2-1.8）时直接空表，不能让 seq.int 倒序
  if (b_to < b_from) return(empty)
  want <- seq.int(b_from, b_to)
  keep <- intersect(want, as.integer(names(cleaned)))
  if (length(keep) == 0L) return(empty)
  keep <- sort(keep)

  sub <- do.call(rbind, cleaned[as.character(keep)])
  if (is.null(sub) || nrow(sub) == 0L) return(empty)

  sub$mz <- round(sub$mz, 4)
  sub$intensity <- round(sub$intensity, 0)
  sub$RT_apex <- round(sub$RT_apex, 4)
  sub$RT_mz <- as.numeric(paste0(sub$RT, sprintf("%.4f", sub$mz)))
  sub$Sample <- sample_id
  sub[, c("Sample", "RT", "RT_mz", "mz", "intensity", "RT_apex")]
}

# ------------------------------------------------------------
# 逐样品写 MSP（上游同款块结构）
# 上游写的是 "IONMODE: Positive" / "Num Peaks: N"（冒号后带空格），而
# readMSP() 只裁前缀，于是 ionmode 实际是 " Positive"。这里统一不带空格，
# 两个读取器都能正确解析（readMSP 的 grep("^Num Peaks:") 与
# sub("^IONMODE:", ...) 都不依赖那个空格）。
# ------------------------------------------------------------
msx_write_msp <- function(path, sample_id, ion_mode, ms2_df, spectra) {
  n <- nrow(ms2_df)
  if (n == 0L) {
    writeLines(character(0), path)
    return(0L)
  }

  blocks <- vector("list", n)
  written <- 0L
  for (i in seq_len(n)) {
    scan_num <- ms2_df$scan[i]
    spec <- spectra[[as.character(scan_num)]]
    if (is.null(spec) || is.null(spec$mz) || is.null(spec$intensity)) next

    written <- written + 1L
    blocks[[written]] <- c(
      paste0("NAME:", sample_id, "_scan", scan_num),
      paste0("PRECURSORMZ:", round(ms2_df$ms2_value[i], 4)),
      paste0("IONMODE:", ion_mode),
      paste0("RETENTIONTIME:", round(ms2_df$StartTime[i], 2)),
      paste0("Num Peaks:", length(spec$mz)),
      paste(paste(spec$mz, spec$intensity), collapse = "\n"),
      ""
    )
  }
  if (written == 0L) {
    writeLines(character(0), path)
    return(0L)
  }
  writeLines(unlist(blocks[seq_len(written)], use.names = FALSE), path)
  written
}

# ------------------------------------------------------------
# 样品 -> 分组
# ------------------------------------------------------------
msx_read_groups <- function(path) {
  ext <- tolower(tools::file_ext(path))
  df <- if (ext %in% c("xlsx", "xls")) {
    as.data.frame(readxl::read_excel(path, sheet = 1), stringsAsFactors = FALSE)
  } else {
    utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                    fileEncoding = "UTF-8-BOM")
  }
  names(df) <- trimws(names(df))
  if (!all(c("Sample", "Group") %in% names(df))) {
    stop(sprintf("分组文件必须包含 Sample 与 Group 两列，实际列名：%s",
                 paste(names(df), collapse = ", ")), call. = FALSE)
  }
  df$Sample <- trimws(as.character(df$Sample))
  df$Group  <- trimws(as.character(df$Group))
  df[!duplicated(df$Sample), , drop = FALSE]
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
msx_run <- function(core, files, ids, group_of, prm, out_dir, prog,
                    env = NULL, slow = FALSE, write_xlsx = FALSE,
                    bom = FALSE) {
  tables_dir <- file.path(out_dir, "tables")
  msp_dir <- file.path(out_dir, "ms2_msp")
  util_ensure_dir(tables_dir)
  util_ensure_dir(msp_dir)

  n_files <- length(files)
  ms2_all <- vector("list", n_files)
  ms1_by_sample <- vector("list", n_files)
  names(ms2_all) <- ids
  names(ms1_by_sample) <- ids
  summary_rows <- vector("list", n_files)

  for (k in seq_len(n_files)) {
    path <- files[[k]]
    sid <- ids[[k]]
    t1 <- Sys.time()

    prog$set(frac = 0.85 * (k - 1L) / n_files, phase = "read",
             done = k - 1L,
             detail = sprintf("读取 %d/%d：%s", k, n_files, sid))

    ms_core_check_reader(path)
    ms <- core$read_ms_file(path)
    st <- ms$scan_table
    spectra <- ms$spectra

    prog$set(phase = "ms2", detail = sprintf("MS2 扫描表 %s", sid))
    ms2 <- msx_ms2_table(st, sid, gap = prm$ms2_group_gap)
    ms2_all[[sid]] <- ms2

    prog$set(phase = "ms1", detail = sprintf("MS1 分钟桶 %s", sid))
    ms1 <- msx_ms1_table(core, st, spectra, prm, sid, slow)
    ms1_by_sample[[sid]] <- ms1

    prog$set(phase = "msp", detail = sprintf("写 MSP %s", sid))
    n_written <- msx_write_msp(file.path(msp_dir, paste0(sid, ".msp")),
                               sid, ms$ion_mode, ms2, spectra)

    summary_rows[[k]] <- data.frame(
      Sample          = sid,
      File            = basename(path),
      Format          = tolower(tools::file_ext(path)),
      Ion_mode        = as.character(ms$ion_mode),
      N_scans         = nrow(st),
      N_MS1_scans     = sum(as.integer(st$msLevel) == 1L, na.rm = TRUE),
      N_MS2_scans     = sum(as.integer(st$msLevel) == 2L, na.rm = TRUE),
      N_MS2_in_msp    = n_written,
      N_MS1_peaks     = nrow(ms1),
      RT_min_observed = round(min(as.numeric(st$StartTime), na.rm = TRUE), 3),
      RT_max_observed = round(max(as.numeric(st$StartTime), na.rm = TRUE), 3),
      Msp_bytes       = util_file_size(file.path(msp_dir, paste0(sid, ".msp"))),
      Seconds         = round(as.numeric(difftime(Sys.time(), t1, units = "secs")), 1),
      stringsAsFactors = FALSE
    )

    # 谱图是这一轮最大的对象，写完 MSP 立刻放掉（界面上靠人工观察内存，
    # 命令行没有看门狗，只能自己保证峰值不叠加）
    rm(ms, st, spectra, ms2, ms1)
    invisible(gc(verbose = FALSE))
    prog$log(sprintf("sample=%s done %.1fs", sid, summary_rows[[k]]$Seconds))
  }

  # ---- 01 MS2 扫描表 ----
  prog$set(frac = 0.87, phase = "export", detail = "写 MS2_Group_Info")
  ms2_out <- do.call(rbind, ms2_all)
  if (is.null(ms2_out)) {
    ms2_out <- data.frame(scan = numeric(0), StartTime = numeric(0),
                          scanType = character(0), ms2_value = numeric(0),
                          group = numeric(0), Sample = character(0))
  }
  rownames(ms2_out) <- NULL
  ms2_path <- file.path(tables_dir, "01_MS2_Group_Info.csv")
  csv_write_one(ms2_out, ms2_path, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", ms2_path, sheet = "MS2_Group_Info",
                   rows = nrow(ms2_out), cols = ncol(ms2_out))
  }

  # ---- 02 样品汇总 ----
  sum_df <- do.call(rbind, summary_rows)
  rownames(sum_df) <- NULL
  sum_path <- file.path(tables_dir, "02_sample_summary.csv")
  csv_write_one(sum_df, sum_path, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", sum_path, sheet = "sample_summary",
                   rows = nrow(sum_df), cols = ncol(sum_df))
  }

  # ---- 03.. MS1 长表（按分组）----
  grp_levels <- unique(group_of[ids])
  grp_levels <- grp_levels[!is.na(grp_levels)]
  seq_no <- 3L
  for (g in grp_levels) {
    members <- ids[group_of[ids] == g]
    members <- members[members %in% names(ms1_by_sample)]
    if (length(members) == 0L) next

    parts <- lapply(members, function(s) ms1_by_sample[[s]])
    df <- do.call(rbind, parts)
    if (is.null(df)) next
    rownames(df) <- NULL

    fname <- sprintf("%02d_MS1_Group_%s.csv", seq_no, util_safe_filename(g))
    path <- file.path(tables_dir, fname)
    csv_write_one(df, path, bom)
    if (!is.null(env)) {
      env_add_output(env, "table", path, sheet = paste0("Clean_MS1_Data_Group", g),
                     rows = nrow(df), cols = ncol(df))
    }
    seq_no <- seq_no + 1L

    if (isTRUE(write_xlsx)) {
      msx_write_block_xlsx(df, members, g, file.path(out_dir, "xlsx"), env)
    }
  }

  prog$set(frac = 0.99, phase = "export", detail = "完成")
  list(summary = sum_df, ms2_rows = nrow(ms2_out))
}

#' --xlsx：按界面的 6 列块式写 Clean_MS1_Data_Group<g>.xlsx
msx_write_block_xlsx <- function(df, members, group, dir, env = NULL) {
  util_ensure_dir(dir)
  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, paste0("Group_", group, "_MS1"))
  col_start <- 1
  for (s in members) {
    d <- df[df$Sample == s, , drop = FALSE]
    if (nrow(d) == 0L) next
    nid <- regmatches(s, regexpr("[0-9]+", s))
    if (length(nid) == 0L) nid <- s
    d$Sample <- rep(nid, nrow(d))
    openxlsx::writeData(wb, 1, d, startCol = col_start, startRow = 1,
                        keepNA = FALSE, na.string = "")
    col_start <- col_start + ncol(d) + 1L
  }
  out_file <- file.path(dir, paste0("Clean_MS1_Data_Group", group, ".xlsx"))
  openxlsx::saveWorkbook(wb, out_file, overwrite = TRUE)
  rm(wb)
  invisible(gc(verbose = FALSE))
  if (!is.null(env)) env_add_output(env, "xlsx", out_file)
  invisible(out_file)
}

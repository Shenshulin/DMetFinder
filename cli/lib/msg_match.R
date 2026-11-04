# ============================================================
# cli/lib/msg_match.R -- msg-match：峰表 -> MS2 扫描号 -> 提取谱图
# ------------------------------------------------------------
# 对应界面：MSGeter › Ms2Geter（Ms2Geter_server.R 第 231–330 行）
#
# 上游模块里 matchScan() 其实定义了却没人调用，真正在跑的是 observeEvent
# 里那段逐行 for 循环，且用 data.table 非标准求值直接引用裸列名
# （Sample / ms2_value / StartTime / scan）。传普通 data.frame 进去会报
# "object 'Sample' not found"。所以这里重写成显式列契约的版本，并把
# 上游的三条隐含规则显式化：
#   1. 候选窗口是 |前体 m/z - 查询 m/z| <= 0.01（含端点）
#   2. 排序键是 (RT 差, m/z 差)，取第一个；同键时保持原有扫描顺序
#   3. RT 本身不设阈值（上游完全不看 RT 距离），这里默认 Inf 保持兼容，
#      但允许 --rt-tol 收严，避免"最近的也在 5 分钟外"这种静默错配
# ============================================================

msm_default_params <- function() {
  list(mz_tol = 0.01, rt_tol = Inf)
}

# ------------------------------------------------------------
# MSP 读取：core$readMSP 的等价实现，但不依赖 stringr
# （readMSP 只用 stringr 做一件事：从 NAME 里抽 scan 号）
# ------------------------------------------------------------
msm_msp_read <- function(path) {
  txt <- readLines(path, warn = FALSE)
  idx <- grep("^NAME:", txt)
  if (length(idx) == 0L) return(list())

  res <- vector("list", length(idx))
  for (i in seq_along(idx)) {
    start <- idx[i]
    end <- if (i < length(idx)) idx[i + 1L] - 1L else length(txt)
    block <- txt[start:end]

    name <- sub("^NAME:", "", block[1L])
    grab <- function(prefix) {
      h <- grep(prefix, block, value = TRUE)
      if (length(h) == 0L) return(NA_character_)
      trimws(sub(prefix, "", h[1L]))
    }

    peak_start <- grep("^Num Peaks:", block)
    peaks <- if (length(peak_start) == 0L) character(0) else
      block[(peak_start[1L] + 1L):length(block)]
    peaks <- peaks[nzchar(trimws(peaks))]

    if (length(peaks) > 0L) {
      mat <- do.call(rbind, strsplit(trimws(peaks), "\\s+"))
      mz <- suppressWarnings(as.numeric(mat[, 1L]))
      it <- suppressWarnings(as.numeric(mat[, 2L]))
    } else {
      mz <- numeric(0); it <- numeric(0)
    }

    scan <- suppressWarnings(as.numeric(sub("^.*scan", "", name)))

    res[[i]] <- list(
      scan        = scan,
      precursorMz = suppressWarnings(as.numeric(grab("^PRECURSORMZ:"))),
      ionmode     = grab("^IONMODE:"),
      rtime       = suppressWarnings(as.numeric(grab("^RETENTIONTIME:"))),
      mz          = mz,
      intensity   = it
    )
  }
  names(res) <- vapply(res, function(x) as.character(x$scan), character(1L))
  res
}

# ------------------------------------------------------------
# 列解析：显式契约优先，别名次之，绝不静默回退到"前几列"
# ------------------------------------------------------------
msm_norm_name <- function(x) {
  x <- tolower(as.character(x))
  x <- gsub("[[:space:][:punct:]]", "", x)
  gsub("\uff1a", "", x, fixed = TRUE)
}

MSM_ALIAS <- list(
  sample = c("sample", "样品", "样本", "样品名称", "样本名称", "样品名", "样本名",
             "samplename", "sampleid", "name", "filename", "文件名称"),
  mz     = c("mz", "mz值", "母离子mz", "母离子", "precursormz", "质荷比", "mass"),
  rt     = c("rt", "rtmin", "rt分钟", "保留时间", "保留时间分钟", "rt值")
)

#' @param overrides list(sample=, mz=, rt=) 用户显式给的列名
#' @return list(sample=, mz=, rt=, names=c(...), how=c(...))
msm_resolve_cols <- function(df, overrides = list()) {
  nn <- msm_norm_name(names(df))
  out <- list()
  how <- list()

  for (key in c("sample", "mz", "rt")) {
    ov <- overrides[[key]]
    if (!is.null(ov) && nzchar(ov)) {
      hit <- which(names(df) == ov)
      if (length(hit) == 0L) {
        hit <- which(nn == msm_norm_name(ov))
      }
      if (length(hit) == 0L) {
        stop(sprintf("指定的 %s 列不存在：%s（实际列名：%s）",
                     key, ov, paste(names(df), collapse = ", ")), call. = FALSE)
      }
      out[[key]] <- hit[1L]
      how[[key]] <- "explicit"
      next
    }

    aliases <- MSM_ALIAS[[key]]
    hit <- which(nn %in% aliases)
    if (length(hit) == 0L) {
      stop(sprintf(paste0("峰表里找不到 %s 列。\n  期望之一：%s\n  实际列名：%s\n",
                          "  用 --%s-col 显式指定。"),
                   key, paste(aliases, collapse = ", "),
                   paste(names(df), collapse = ", "), key), call. = FALSE)
    }
    if (length(hit) > 1L) {
      stop(sprintf(paste0("峰表里有 %d 列都可能被当成 %s 列：%s。\n",
                          "  请求歧义时不猜，请用 --%s-col 指定。"),
                   length(hit), key, paste(names(df)[hit], collapse = ", "), key),
           call. = FALSE)
    }
    out[[key]] <- hit[1L]
    how[[key]] <- "alias"
  }

  if (length(unique(unlist(out))) != 3L) {
    stop(sprintf("解析出的三列有重复：%s。请用 --sample-col / --mz-col / --rt-col 指定。",
                 paste(sprintf("%s=%s", names(out), names(df)[unlist(out)]),
                       collapse = ", ")), call. = FALSE)
  }

  list(sample = out$sample, mz = out$mz, rt = out$rt,
       names = c(sample = names(df)[out$sample],
                 mz = names(df)[out$mz],
                 rt = names(df)[out$rt]),
       how = how)
}

# ------------------------------------------------------------
# 匹配
# ------------------------------------------------------------
msm_match <- function(features, all_ms2, cols, mz_tol = 0.01, rt_tol = Inf) {
  n <- nrow(features)
  samp <- trimws(as.character(features[[cols$sample]]))
  qmz  <- suppressWarnings(as.numeric(features[[cols$mz]]))
  qrt  <- suppressWarnings(as.numeric(features[[cols$rt]]))

  scan   <- rep(NA_real_, n)
  mzdiff <- rep(NA_real_, n)
  rtdiff <- rep(NA_real_, n)
  ncand  <- rep(0L, n)
  reason <- rep("", n)

  bad_mz <- is.na(qmz)
  reason[bad_mz] <- "bad_mz"
  bad_rt <- !bad_mz & is.na(qrt)
  reason[bad_rt] <- "bad_rt"

  ms2_s <- as.character(all_ms2$Sample)
  present <- unique(ms2_s)

  for (s in unique(samp[!bad_mz & !bad_rt])) {
    rows <- which(samp == s & !bad_mz & !bad_rt)
    if (length(rows) == 0L) next
    if (!s %in% present) {
      reason[rows] <- "no_ms2_for_sample"
      next
    }

    sub <- all_ms2[ms2_s == s, , drop = FALSE]
    v   <- as.numeric(sub$ms2_value)
    keep <- !is.na(v)
    sub <- sub[keep, , drop = FALSE]
    v   <- v[keep]
    if (nrow(sub) == 0L) {
      reason[rows] <- "no_precursor"
      next
    }
    o <- order(v)
    sub <- sub[o, , drop = FALSE]
    v <- v[o]
    rt_v <- as.numeric(sub$StartTime)
    sc_v <- as.numeric(sub$scan)
    nv <- length(v)

    q <- qmz[rows]
    # findInterval 返回 #{v <= x}，两次向量化调用即可得到全部窗口端点
    lo <- findInterval(q - mz_tol, v)
    hi <- findInterval(q + mz_tol, v)
    # 左端点要含等号：v[lo] == q - mz_tol 时该点仍在窗口内
    start <- lo
    eq <- lo >= 1L & v[pmax(lo, 1L)] >= (q - mz_tol)
    start <- ifelse(eq, lo, lo + 1L)

    for (k in seq_along(rows)) {
      r <- rows[k]
      if (start[k] > hi[k] || hi[k] < 1L) {
        reason[r] <- "no_mz_window"
        ncand[r] <- 0L
        next
      }
      cand <- seq.int(start[k], hi[k])
      ncand[r] <- length(cand)
      rd <- abs(rt_v[cand] - qrt[r])
      if (is.finite(rt_tol)) {
        ok <- rd <= rt_tol
        if (!any(ok)) {
          reason[r] <- "rt_tol_excluded"
          next
        }
        cand <- cand[ok]
        rd <- rd[ok]
      }
      md <- abs(v[cand] - q[r])
      pick <- order(rd, md)[1L]        # order() 稳定：同键保持扫描顺序
      scan[r]   <- sc_v[cand[pick]]
      mzdiff[r] <- md[pick]
      rtdiff[r] <- rd[pick]
      reason[r] <- "matched"
    }
  }

  diag <- data.frame(
    row              = seq_len(n),
    sample           = samp,
    mz               = qmz,
    rt               = qrt,
    matched          = !is.na(scan),
    scan             = scan,
    n_candidates     = ncand,
    match_mz_diff    = mzdiff,
    match_rt_diff    = rtdiff,
    reason           = reason,
    stringsAsFactors = FALSE
  )
  list(diag = diag, scan = scan)
}

# ------------------------------------------------------------
# 生成 matched MSP（块结构与界面版一致）
# ------------------------------------------------------------
msm_build_msp <- function(features, diag, cols, msp_list, sample_label = "sample") {
  keep <- which(!is.na(diag$scan))
  if (length(keep) == 0L) return(character(0))

  blocks <- vector("list", length(keep))
  w <- 0L
  for (i in keep) {
    s <- diag$sample[i]
    lst <- msp_list[[s]]
    if (is.null(lst)) next
    spec <- lst[[as.character(diag$scan[i])]]
    if (is.null(spec)) next

    w <- w + 1L
    blocks[[w]] <- c(
      paste0("NAME:", s, "_scan", diag$scan[i]),
      paste0("FEATURE_INFO:", s, "&", round(diag$rt[i], 4), "&", round(diag$mz[i], 6)),
      paste0("PRECURSORMZ:", round(spec$precursorMz, 6)),
      paste0("IONMODE:", trimws(as.character(spec$ionmode))),
      paste0("RETENTIONTIME:", round(spec$rtime, 4)),
      paste0("Num Peaks:", length(spec$mz)),
      paste(paste(spec$mz, spec$intensity), collapse = "\n"),
      ""
    )
  }
  if (w == 0L) return(character(0))
  unlist(blocks[seq_len(w)], use.names = FALSE)
}

#' 主流程
msm_run <- function(features, cols, all_ms2, msp_dir, out_dir, prm,
                    env = NULL, prog = NULL, bom = FALSE) {
  tables_dir <- file.path(out_dir, "tables")
  util_ensure_dir(tables_dir)

  need <- c("Sample", "ms2_value", "StartTime", "scan")
  miss <- need[!need %in% names(all_ms2)]
  if (length(miss) > 0L) {
    dmf_stop_input(sprintf(
      "MS2 扫描表缺少列：%s。该文件应由 `dmf.R msg-extract` 生成的 01_MS2_Group_Info.csv 提供。",
      paste(miss, collapse = ", ")))
  }

  if (!is.null(prog)) prog$set(frac = 0.1, phase = "match", detail = "匹配扫描号")
  m <- msm_match(features, all_ms2, cols, prm$mz_tol, prm$rt_tol)

  if (!is.null(prog)) prog$set(frac = 0.6, phase = "msp", detail = "生成 matched MSP")
  msp_files <- list.files(msp_dir, pattern = "\\.msp$", full.names = TRUE,
                          ignore.case = TRUE)
  msp_list <- list()
  for (f in msp_files) {
    msp_list[[tools::file_path_sans_ext(basename(f))]] <- msm_msp_read(f)
  }

  msp_lines <- msm_build_msp(features, m$diag, cols, msp_list)
  msp_path <- file.path(out_dir, "ms2_matched.msp")
  writeLines(msp_lines, msp_path)

  # ---- 输出表 ----
  out_df <- features
  out_df$scan <- m$diag$scan
  matched_df <- out_df[!is.na(m$diag$scan), , drop = FALSE]

  p1 <- file.path(tables_dir, "01_matched_features.csv")
  csv_write_one(matched_df, p1, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", p1, sheet = "matched_features",
                   rows = nrow(matched_df), cols = ncol(matched_df))
  }

  p2 <- file.path(tables_dir, "02_match_diagnostics.csv")
  csv_write_one(m$diag, p2, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", p2, sheet = "match_diagnostics",
                   rows = nrow(m$diag), cols = ncol(m$diag))
  }

  if (!is.null(env)) env_add_output(env, "msp", msp_path)

  # ---- 汇总 ----
  reason_tab <- table(m$diag$reason)
  reason_tab <- reason_tab[!names(reason_tab) %in% c("matched", "")]
  n_matched <- sum(!is.na(m$diag$scan))
  summary <- data.frame(
    metric = c("n_features", "n_matched", "match_rate",
               "n_msp_files", "n_msp_spectra",
               paste0("unmatched_", names(reason_tab))),
    value = c(nrow(features), n_matched,
              round(n_matched / max(1L, nrow(features)), 4),
              length(msp_files), sum(lengths(msp_list)),
              as.integer(reason_tab)),
    stringsAsFactors = FALSE
  )
  p3 <- file.path(tables_dir, "03_match_summary.csv")
  csv_write_one(summary, p3, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", p3, sheet = "match_summary",
                   rows = nrow(summary), cols = ncol(summary))
  }

  if (!is.null(prog)) prog$set(frac = 0.99, phase = "export", detail = "完成")

  list(n_matched = n_matched, n_features = nrow(features),
       n_msp_files = length(msp_files), diag = m$diag)
}

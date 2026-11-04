# ============================================================
# cli/lib/inspect_xlsx.R -- A 层结构检查（不读谱图）
# ------------------------------------------------------------
# 只回答一个问题：这个 xlsx 交给 dmetfinder_run() 会不会读错、读少、
# 或者把两个样品合并成一个。所有判据都来自 dmf_read_samples() 的实际逻辑，
# 不是凭格式约定猜的。
#
# 已核实的关键行为（对应 R/dmetfinder_functions.R:358-447）：
#   * 每样品块宽 6 列（v1.0.4 起 Ms1Geter 输出含 RT_apex，块宽 7），
#     只读前 5 列（no / rt / rt_mz / mz / intensity），第 6 列起不参与计算；
#     count 是后续 dmf_create_matrix() 现算的
#   * 一个块至少要有 5 列才被接受（starts + 4 <= n_col），不足则整块丢弃
#   * 样品号取该块第一行第一列；非数值 -> 整块丢弃
#   * 样品名做 unique()，编号重复的两块会被并成同一个样品
# 因此"列数不是 6 的整数倍"本身不致命（末块缺第 6 列仍可读），
# 真正致命的是末块不足 5 列 —— 那是静默的数据丢失。检查按此区分。
# ============================================================

inspect_finding <- function(severity, code, message, block = NA_integer_) {
  list(severity = severity, code = code, message = message,
       block = if (is.na(block)) NA_integer_ else as.integer(block))
}

#' @param block_width 每样品块宽（列）。NA = 按表头自动识别：
#'   v1.0.4 起 Ms1Geter 输出多一列 `RT_apex`，块宽 6 -> 7；与
#'   dmf_read_samples() 用的是同一条判据，避免两处对不齐。
#' @return list(ok, findings, blocks, summary)
inspect_xlsx <- function(path, block_width = NA_integer_) {
  findings <- list()
  blocks <- data.frame(
    block = integer(0), sample_no = numeric(0), col_from = integer(0),
    col_to = integer(0), n_cols_used = integer(0), ions = integer(0),
    stringsAsFactors = FALSE
  )
  add <- function(sev, code, msg, block = NA_integer_) {
    findings[[length(findings) + 1L]] <<- inspect_finding(sev, code, msg, block)
    invisible(NULL)
  }

  if (!file.exists(path)) {
    add("fatal", "file_missing", sprintf("找不到文件：%s", path))
    return(list(ok = FALSE, findings = findings, blocks = blocks,
                summary = list(n_rows = NA, n_cols = NA, n_blocks = 0L,
                               sample_ids = character(0))))
  }

  raw <- tryCatch(
    readxl::read_excel(path, col_names = FALSE, .name_repair = "minimal"),
    error = function(e) e
  )
  if (inherits(raw, "error")) {
    add("fatal", "unreadable", sprintf("无法读取为 Excel：%s", conditionMessage(raw)))
    return(list(ok = FALSE, findings = findings, blocks = blocks,
                summary = list(n_rows = NA, n_cols = NA, n_blocks = 0L,
                               sample_ids = character(0))))
  }

  raw <- as.data.frame(raw, stringsAsFactors = FALSE)
  n_raw_rows <- nrow(raw)
  if (n_raw_rows < 2L) {
    add("fatal", "too_few_rows", "除表头外没有数据行")
    return(list(ok = FALSE, findings = findings, blocks = blocks,
                summary = list(n_rows = 0L, n_cols = ncol(raw), n_blocks = 0L,
                               sample_ids = character(0))))
  }

  # 第一行被当作表头丢弃（与 dmf_read_samples 一致）
  data <- raw[-1L, , drop = FALSE]
  n_col <- ncol(data)

  # 块宽自动识别：有 RT_apex 列就是 7 列一块，否则 6 列（旧格式）
  if (length(block_width) != 1L || is.na(block_width)) {
    hdr <- trimws(as.character(raw[1L, ]))
    block_width <- if (any(hdr == "RT_apex")) 7L else 6L
  }
  block_width <- as.integer(block_width)

  if (n_col < 5L) {
    add("fatal", "too_few_cols",
        sprintf("只有 %d 列，不足一个样品块（需 5 列）", n_col))
    return(list(ok = FALSE, findings = findings, blocks = blocks,
                summary = list(n_rows = nrow(data), n_cols = n_col, n_blocks = 0L,
                               sample_ids = character(0))))
  }

  starts_all <- seq.int(1L, n_col, by = block_width)
  accepted   <- starts_all[starts_all + 4L <= n_col]
  rejected   <- setdiff(starts_all, accepted)

  if (length(rejected) > 0L) {
    add("error", "last_block_dropped",
        sprintf(paste0("末块起始于第 %d 列，只剩 %d 列（至少需 5 列），",
                       "dmf_read_samples 会整块丢弃 —— 该样品的全部离子静默缺失"),
                rejected[[1L]], n_col - rejected[[1L]] + 1L))
  }
  # 注意：这里刻意不检查 n_col %% 6。
  # 实测 demo_data/groupA.xlsx 是 59 列 = 10 块 x 6 列 - 1，因为每块第 6 列是
  # 空分隔列（表头为 NA），Excel 导出时把末尾空列截掉了。该列本来就不被读取，
  # 所以"列数不是 6 的整数倍"是正常形态，不构成警告。
  tail_cols <- if (length(rejected) == 0L) n_col - accepted[[length(accepted)]] + 1L else NA_integer_

  if (length(accepted) == 0L) {
    add("fatal", "no_complete_block", "没有任何完整样品块")
    return(list(ok = FALSE, findings = findings, blocks = blocks,
                summary = list(n_rows = nrow(data), n_cols = n_col, n_blocks = 0L,
                               sample_ids = character(0))))
  }

  # ---- 逐块读取 ----
  first_no <- vapply(accepted, function(s) {
    suppressWarnings(as.numeric(data[[s]][[1L]]))
  }, numeric(1L))

  ok_no <- !is.na(first_no)
  if (any(!ok_no)) {
    add("error", "sample_no_non_numeric",
        sprintf("第 %s 块的首行样品编号不是数值，整块会被丢弃：%s",
                paste(which(!ok_no), collapse = ","),
                paste(unique(as.character(vapply(accepted[!ok_no], function(s)
                  data[[s]][[1L]], character(1L)))), collapse = " / ")))
  }

  dup <- first_no[ok_no][duplicated(first_no[ok_no])]
  if (length(dup) > 0L) {
    add("error", "sample_no_duplicate",
        sprintf("样品编号重复：%s。unique() 会把重复编号并成同一个样品，两组数据被叠加",
                paste(unique(dup), collapse = ", ")))
  }

  ord <- sort(first_no[ok_no])
  gap_codes <- integer(0)
  if (length(ord) > 1L) {
    gap <- diff(ord)
    gap_codes <- which(gap > 1L)
    # 只有"看起来就是 1..N 序列"时才把跳号当异常。
    # 实测 data_for_paper 的样品号是 173/176/237/… 这类任意 ID，
    # 无条件报跳号会让每次运行都带一条警告，把警告本身变成噪声。
    span <- diff(range(ord)) + 1
    density <- length(ord) / span
    if (length(gap_codes) > 0L && density >= 0.5) {
      add("warning", "sample_no_gap",
          sprintf("样品编号在 1..N 式序列中跳号（密度 %.0f%%）：%s",
                  density * 100,
                  paste(sprintf("%s->%s", ord[gap_codes], ord[gap_codes + 1L]),
                        collapse = ", ")))
    }
  }

  blk <- vector("list", length(accepted))
  for (j in seq_along(accepted)) {
    s <- accepted[[j]]
    cols <- s:min(s + 4L, n_col)
    no    <- suppressWarnings(as.numeric(data[[s]]))
    rt    <- suppressWarnings(as.numeric(data[[cols[2L]]]))
    rtmz  <- suppressWarnings(as.numeric(data[[cols[3L]]]))
    mz    <- suppressWarnings(as.numeric(data[[cols[4L]]]))
    inten <- suppressWarnings(as.numeric(data[[cols[5L]]]))
    ok <- !is.na(no) & !is.na(rt) & !is.na(rtmz) & !is.na(mz) & !is.na(inten)

    blk[[j]] <- data.frame(
      block = j, sample_no = first_no[[j]],
      col_from = s, col_to = min(s + block_width - 1L, n_col),
      n_cols_used = length(cols), ions = sum(ok),
      stringsAsFactors = FALSE
    )
    if (sum(ok) == 0L) {
      add("warning", "block_empty",
          sprintf("第 %d 块（样品 %s，第 %d-%d 列）没有任何有效离子",
                  j, format(first_no[[j]]), s, min(s + block_width - 1L, n_col)), j)
    }
  }
  blocks <- do.call(rbind, blk)

  # 离子数离群：低于组内中位数的 10%
  pos <- blocks$ions[blocks$ions > 0L]
  if (length(pos) >= 3L) {
    med <- stats::median(pos)
    thr <- max(1, floor(med * 0.1))
    low <- blocks[blocks$ions > 0L & blocks$ions < thr, , drop = FALSE]
    if (nrow(low) > 0L) {
      for (r in seq_len(nrow(low))) {
        add("warning", "block_sparse",
            sprintf("第 %d 块（样品 %s）只有 %d 个离子，低于组内中位数 %.0f 的 10%%",
                    low$block[[r]], format(low$sample_no[[r]]), low$ions[[r]], med),
            low$block[[r]])
      }
    }
  }

  sev <- vapply(findings, function(f) f$severity, character(1L))
  list(
    ok = !any(sev %in% c("fatal", "error")),
    findings = findings,
    blocks = blocks,
    summary = list(
      n_rows = nrow(data),
      n_cols = n_col,
      n_blocks = nrow(blocks),
      n_dropped_blocks = length(rejected),
      tail_block_cols = tail_cols,
      n_samples_unique = length(unique(first_no[ok_no])),
      sample_ids = ifelse(is.na(blocks$sample_no), NA_character_,
                          format(blocks$sample_no)),
      ions_total = sum(blocks$ions),
      errors = sum(sev %in% c("fatal", "error")),
      warnings = sum(sev == "warning")
    )
  )
}

#' 把 findings / blocks 写成两张 CSV
inspect_write_csv <- function(res, dir) {
  util_ensure_dir(dir)

  fpath <- file.path(dir, "inspect_findings.csv")
  if (length(res$findings) == 0L) {
    df <- data.frame(severity = character(0), code = character(0),
                     block = integer(0), message = character(0),
                     stringsAsFactors = FALSE)
  } else {
    df <- data.frame(
      severity = vapply(res$findings, function(f) f$severity, character(1L)),
      code     = vapply(res$findings, function(f) f$code, character(1L)),
      block    = vapply(res$findings, function(f) f$block, integer(1L)),
      message  = vapply(res$findings, function(f) f$message, character(1L)),
      stringsAsFactors = FALSE
    )
  }
  csv_write_one(df, fpath)

  bpath <- file.path(dir, "inspect_blocks.csv")
  csv_write_one(res$blocks, bpath)

  c(fpath, bpath)
}

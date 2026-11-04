# ============================================================
# cli/lib/csv_out.R -- sheet -> CSV 写出层
# ------------------------------------------------------------
# 一个 sheet 一个 CSV，落在 <out>/tables/<NN>_<sheet 名>.csv。
# 序号来自遍历顺序（与 dmetfinder_run() 的写盘顺序一致），不手工维护映射表。
#
# 三个必须守住的规则：
#   1. 列名只取最后一个表头行（只有它与数据列对齐），上层表头写入 schema.csv
#   2. 全空且无名的列默认丢弃（CSV 没有视觉分组需求），schema.csv 留 dropped 标记
#   3. 编号与 sheet 名逐项断言，不匹配直接报错，防止版本演进时序号静默漂移
# ============================================================

csv_ctx_new <- function(out_dir, keep_empty = FALSE, bom = FALSE) {
  ctx <- new.env(parent = emptyenv())
  ctx$out_dir    <- out_dir
  ctx$tables_dir <- file.path(out_dir, "tables")
  ctx$keep_empty <- isTRUE(keep_empty)
  ctx$bom        <- isTRUE(bom)
  util_ensure_dir(ctx$tables_dir)
  ctx
}

#' 按 dmetfinder_run() 的写盘顺序展平 18 个 sheet
csv_collect <- function(res) {
  s <- res$sheets
  c(s$A,
    list(s$compare_ab),
    list(s$diff_ab),
    list(s$diff_ba),
    s$B,
    list(s$compare_ba))
}

#' 期望的 18 个 sheet 名（顺序敏感，用于断言）
csv_expected_names <- function(g1, g2, p80) {
  one <- function(g) c(
    paste0(g, "离子分布初筛"),
    paste0(g, "50%分布频率离子"),
    paste0(g, p80, "分布频率离子"),
    paste0(g, "50%离子单独打分"),
    paste0(g, "总离子平均得分"),
    paste0(g, "离子打分汇总"),
    paste0(g, "同位素离子查找")
  )
  c(one(g1),
    paste0(g1, p80, "离子和", g2, "比对"),
    sprintf("%s和%s差异离子(%s比%s)", g1, g2, g1, g2),
    sprintf("%s和%s差异离子(%s比%s)", g2, g1, g2, g1),
    one(g2),
    paste0(g2, p80, "离子和", g1, "比对"))
}

#' 对应的原 xlsx 名（仅用于 schema.csv 追溯，不实际写出）
#' 必须与 dmetfinder_run() 里的 sprintf 逐字一致，否则追溯会断。
csv_workbook_names <- function(g1, g2, p80) {
  filt <- function(g) sprintf("%s-筛选50%%和%s离子.xlsx", g, p80)
  scor <- function(g) sprintf("%s-离子打分.xlsx", g)
  isot <- function(g) sprintf("%s-同位素离子查找.xlsx", g)
  cmpr <- function(g, o) sprintf("%s-%s离子与%s总离子比对分析.xlsx", g, p80, o)
  diff <- sprintf("%s-%s差异离子筛选汇总.xlsx", g1, g2)
  c(rep(filt(g1), 3), rep(scor(g1), 3), isot(g1), cmpr(g1, g2), diff, diff,
    rep(filt(g2), 3), rep(scor(g2), 3), isot(g2), cmpr(g2, g1))
}

#' 多行表头 -> 单行列名：只取最后一行，因为它与数据列一一对齐
#' 注意：这里**不做** make.unique。去重必须放在丢弃空列之后，否则第 2、3 个
#' "-" 会先变成 "-_1"/"-_2" 而躲过空列判定（曾导致 4 个分隔列只丢了 1 个）。
csv_flat_header <- function(header, n_col) {
  if (n_col <= 0L) return(character(0))
  if (length(header) == 0L) return(paste0("V", seq_len(n_col)))
  h <- as.character(unlist(header[[length(header)]], use.names = FALSE))
  h <- util_pad(h, n_col)
  h <- h[seq_len(n_col)]
  bad <- is.na(h) | !nzchar(trimws(h))
  if (any(bad)) h[bad] <- paste0("V", which(bad))
  h <- gsub("[\r\n\t]+", " ", h)
  trimws(h)
}

#' 丢弃全空且无名的列（分隔用的 "-" 之类）
#' "无名"包括：NA、空串、"-"、以及表头行不足时补出来的 V<n>。
csv_prepare <- function(cols, names, keep_empty = FALSE) {
  n <- length(cols)
  if (n == 0L) return(list(cols = cols, names = names, dropped = logical(0)))
  if (is.null(names) || length(names) != n) names <- rep(NA_character_, n)
  all_na <- vapply(cols, function(x) length(x) == 0L || all(is.na(x)), logical(1))
  blank <- is.na(names) | !nzchar(names) |
    names %in% c("-", "--", "\u2014") | grepl("^V[0-9]+$", names)
  drop <- all_na & blank
  if (isTRUE(keep_empty)) drop[] <- FALSE
  kept_names <- names[!drop]
  list(cols = cols[!drop], names = make.unique(kept_names, sep = "_"), dropped = drop)
}

csv_fwrite_formals <- function() names(formals(data.table::fwrite))

#' 强制 UTF-8 写出：Windows 中文系统的 native 编码是 GBK，
#' 不指定的话 agent 侧（pandas / fread 之外的读取器）会解码失败。
csv_write_one <- function(df, path, bom = FALSE) {
  util_ensure_dir(dirname(path))
  f <- csv_fwrite_formals()

  args <- list(x = df, file = path, na = "", quote = "auto", showProgress = FALSE)
  if ("encoding" %in% f) args$encoding <- "UTF-8"
  if ("bom" %in% f) args$bom <- isTRUE(bom)
  do.call(data.table::fwrite, args)

  # 老版 data.table 没有 bom 参数时手工加 BOM
  if (isTRUE(bom) && !("bom" %in% f)) {
    n <- file.info(path)$size
    raw <- readBin(path, "raw", n = n)
    con <- file(path, open = "wb")
    writeBin(c(as.raw(c(0xEF, 0xBB, 0xBF)), raw), con)
    close(con)
  }
  invisible(path)
}

#' 写出全部 18 个 CSV + schema.csv。返回 outputs 列表供信封使用。
csv_write_all <- function(res, ctx, groups, env = NULL) {
  sheets <- csv_collect(res)
  p80 <- as.character(res$p80_str)
  g1 <- groups[[1L]]
  g2 <- groups[[2L]]

  exp_names <- csv_expected_names(g1, g2, p80)
  got_names <- vapply(sheets, function(s) as.character(s$name), character(1L))

  if (length(sheets) != length(exp_names)) {
    stop(sprintf(paste0("sheet 数量与预期不符：实际 %d 个，预期 %d 个。",
                        "这通常意味着 dmetfinder_run() 的输出版本已变化，",
                        "请同步更新 csv_expected_names()。"),
                 length(sheets), length(exp_names)), call. = FALSE)
  }
  if (!identical(got_names, exp_names)) {
    bad <- which(got_names != exp_names)
    stop(sprintf(paste0("sheet 名与预期不符（第 %s 个）：\n  实际：%s\n  预期：%s\n",
                        "序号是按此顺序分配的，名字变了就会导致序号漂移，故中止。"),
                 paste(bad, collapse = ","),
                 paste(got_names[bad], collapse = " | "),
                 paste(exp_names[bad], collapse = " | ")), call. = FALSE)
  }

  wb_names <- csv_workbook_names(g1, g2, p80)
  schema <- vector("list", 0L)
  outputs <- vector("list", 0L)

  for (i in seq_along(sheets)) {
    sh   <- sheets[[i]]
    name <- got_names[[i]]
    cols <- sh$cols
    hdr  <- sh$header
    n_col <- length(cols)

    col_names <- csv_flat_header(hdr, n_col)
    prep <- csv_prepare(cols, col_names, ctx$keep_empty)

    df <- as.data.frame(prep$cols, stringsAsFactors = FALSE,
                        check.names = FALSE, optional = TRUE)
    if (length(prep$names) > 0L) names(df) <- prep$names

    fname <- sprintf("%02d_%s.csv", i, util_safe_filename(name))
    path  <- file.path(ctx$tables_dir, fname)
    csv_write_one(df, path, ctx$bom)

    keep_idx <- cumsum(!prep$dropped)
    keep_idx[prep$dropped] <- NA_integer_
    hr <- lapply(seq_len(min(3L, length(hdr))), function(j)
      util_pad(as.character(unlist(hdr[[j]], use.names = FALSE)), n_col))

    for (k in seq_len(n_col)) {
      schema[[length(schema) + 1L]] <- list(
        csv_file       = fname,
        seq            = i,
        sheet_name     = name,
        workbook       = wb_names[[i]],
        col_index      = k,
        csv_col_index  = keep_idx[[k]],
        column_name    = if (is.na(keep_idx[[k]])) col_names[[k]] else
                           prep$names[[keep_idx[[k]]]],
        internal_key   = if (!is.null(names(cols))) names(cols)[[k]] else NA_character_,
        header_r1      = if (length(hr) >= 1L) hr[[1L]][[k]] else NA_character_,
        header_r2      = if (length(hr) >= 2L) hr[[2L]][[k]] else NA_character_,
        header_r3      = if (length(hr) >= 3L) hr[[3L]][[k]] else NA_character_,
        dropped        = isTRUE(prep$dropped[[k]])
      )
    }

    outputs[[length(outputs) + 1L]] <- list(
      seq = i, sheet = name, path = path,
      rows = nrow(df), cols = ncol(df),
      dropped_cols = sum(prep$dropped)
    )

    if (!is.null(env)) {
      env_add_output(env, role = "table", path = path, sheet = name,
                     rows = nrow(df), cols = ncol(df))
    }
  }

  schema_path <- file.path(ctx$out_dir, "schema.csv")
  csv_write_schema(schema, schema_path, ctx$bom)
  if (!is.null(env)) {
    env_add_output(env, role = "schema", path = schema_path,
                   rows = length(schema), cols = 12L)
  }

  list(outputs = outputs, schema = schema, schema_path = schema_path)
}

csv_write_schema <- function(schema, path, bom = FALSE) {
  if (length(schema) == 0L) {
    util_atomic_write(path, "csv_file,seq,sheet_name\n")
    return(invisible(path))
  }
  cols <- c("csv_file", "seq", "sheet_name", "workbook", "col_index",
            "csv_col_index", "column_name", "internal_key",
            "header_r1", "header_r2", "header_r3", "dropped")
  df <- as.data.frame(lapply(cols, function(k)
    vapply(schema, function(r) {
      v <- r[[k]]
      if (is.null(v) || length(v) == 0L) return(NA_character_)
      as.character(v)[[1L]]
    }, character(1L))), stringsAsFactors = FALSE, check.names = FALSE)
  names(df) <- cols
  csv_write_one(df, path, bom)
  invisible(path)
}

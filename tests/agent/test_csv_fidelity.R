# ============================================================
# tests/agent/test_csv_fidelity.R
# ------------------------------------------------------------
# 验收"共用 core"的唯一硬证据：CLI 产出的 18 个 CSV，与**未修改的原写出
# 函数**产出的 xlsx 逐单元格一致。
#
# 前提：先用 --xlsx 跑一次
#   Rscript cli/dmf.R diff --a ... --b ... --out out/verify --xlsx
#
# 用法：Rscript tests/agent/test_csv_fidelity.R out/verify
# ============================================================

args <- commandArgs(trailingOnly = TRUE)
out_dir <- if (length(args) >= 1L) args[[1L]] else "out/verify"
out_dir <- normalizePath(out_dir, winslash = "/", mustWork = TRUE)

tables_dir <- file.path(out_dir, "tables")
xlsx_dir   <- file.path(out_dir, "xlsx")
schema_csv <- file.path(out_dir, "schema.csv")

for (p in c(tables_dir, xlsx_dir, schema_csv)) {
  if (!file.exists(p)) stop(sprintf("缺少：%s（请先用 --xlsx 跑一次 diff）", p))
}

schema <- read.csv(schema_csv, colClasses = "character", check.names = FALSE)
schema <- schema[!is.na(schema$csv_file) & nzchar(schema$csv_file), ]

# 同一个 sheet 的所有列必须来自同一个 csv；按出现顺序取唯一
sheets <- unique(schema[, c("csv_file", "sheet_name", "workbook")])
sheets <- sheets[order(as.integer(sub("_.*$", "", sheets$csv_file))), ]
rownames(sheets) <- NULL

cat(sprintf("待比对：%d 个 sheet，来自 %d 个 workbook\n",
            nrow(sheets), length(unique(sheets$workbook))))

fail <- 0L
checked_cells <- 0

for (i in seq_len(nrow(sheets))) {
  csv_file <- sheets$csv_file[[i]]
  sh_name  <- sheets$sheet_name[[i]]
  wb_name  <- sheets$workbook[[i]]
  xlsx_path <- file.path(xlsx_dir, wb_name)

  if (!file.exists(xlsx_path)) {
    cat(sprintf("[SKIP] %s：找不到 %s\n", csv_file, wb_name))
    fail <- fail + 1L
    next
  }

  # CSV
  csv <- read.csv(file.path(tables_dir, csv_file), colClasses = "character",
                  check.names = FALSE, na.strings = "", encoding = "UTF-8")

  # xlsx 的对应 sheet
  xl <- readxl::read_excel(xlsx_path, sheet = sh_name, col_names = FALSE,
                           .name_repair = "minimal")
  xl <- as.data.frame(xl, stringsAsFactors = FALSE)

  n_hdr <- nrow(xl) - nrow(csv)
  if (n_hdr < 1L) {
    cat(sprintf("[FAIL] %s：xlsx 行数 %d 不少于 csv 行数 %d\n",
                csv_file, nrow(xl), nrow(csv)))
    fail <- fail + 1L
    next
  }
  body <- xl[seq.int(n_hdr + 1L, nrow(xl)), , drop = FALSE]

  # 按 schema 的 dropped 标记，从 xlsx 侧删掉同样的列。
  # xlsx 侧列数可能少于 schema 的原始列数：末尾整列为空时 openxlsx 不写单元格，
  # readxl 就看不到那一列。先补齐宽度，再按原位置删，才能对齐。
  sc <- schema[schema$csv_file == csv_file, , drop = FALSE]
  sc <- sc[order(as.integer(sc$col_index)), , drop = FALSE]
  need <- max(as.integer(sc$col_index))
  keep_idx <- as.integer(sc$col_index[is.na(sc$dropped) | sc$dropped != "TRUE"])

  cells <- as.list(body)
  if (length(cells) < need) {
    cells <- c(cells, rep(list(rep(NA, nrow(body))), need - length(cells)))
  }
  cells <- cells[keep_idx]

  if (length(cells) != ncol(csv)) {
    cat(sprintf("[FAIL] %s：列数不一致 xlsx=%d csv=%d\n", csv_file, length(cells), ncol(csv)))
    fail <- fail + 1L
    next
  }

  bad_cols <- character(0)
  for (j in seq_len(ncol(csv))) {
    a <- cells[[j]]                # xlsx 侧
    b_raw <- csv[[j]]              # csv 侧，字符

    a_chr <- as.character(a); a_chr[is.na(a_chr)] <- ""
    b_chr <- as.character(b_raw); b_chr[is.na(b_chr)] <- ""

    ok <- a_chr == b_chr

    # 数值等价：xlsx 侧常把小数写成定点（0.0000742），csv 侧写成科学计数
    # （7.42e-05），字符串不等但数值相同。这属于格式差异，不是数据差异。
    an <- suppressWarnings(as.numeric(a_chr))
    bn <- suppressWarnings(as.numeric(b_chr))
    both <- !is.na(an) & !is.na(bn)
    if (any(both)) {
      ok[both] <- abs(an[both] - bn[both]) <= pmax(1e-12, abs(an[both]) * 1e-12)
    }
    ok[is.na(ok)] <- FALSE

    checked_cells <- checked_cells + length(ok)
    if (!all(ok)) {
      k <- which(!ok)[1L]
      bad_cols <- c(bad_cols, sprintf("第%d列(%s) 行%d: xlsx=%s csv=%s",
                                      j, names(csv)[j], k,
                                      substr(a_chr[[k]], 1, 24), substr(b_chr[[k]], 1, 24)))
    }
  }

  if (length(bad_cols) == 0L) {
    cat(sprintf("[ OK ] %-46s %6d 行 x %2d 列\n", csv_file, nrow(csv), ncol(csv)))
  } else {
    cat(sprintf("[FAIL] %-46s %d 列不一致\n", csv_file, length(bad_cols)))
    cat(paste0("        ", head(bad_cols, 3L), collapse = "\n"), "\n")
    fail <- fail + 1L
  }
}

cat(sprintf("\n比对单元格总数：%s\n", format(checked_cells, big.mark = ",")))
if (fail == 0L) {
  cat("结论：全部一致，CSV 与原 xlsx 写出函数等价。\n")
  quit(save = "no", status = 0L)
} else {
  cat(sprintf("结论：%d 个 sheet 未通过。\n", fail))
  quit(save = "no", status = 1L)
}

## 集成测试：差异离子表 -> xlsx，P 列必须是数值（t="n"），不能是文本或公式
suppressWarnings(source("R/dmetfinder_functions.R", encoding = "UTF-8"))

samples_a <- c("11", "12", "13", "14", "15")
samples_b <- c("21", "22", "23", "24", "25")
inten1 <- rbind(
  c(35894, 69524, 64426, 33134, 60352),
  c(3586126, 69524, 268608, 4119029, 5060052),
  c(260877, 207041, 169412, 116259, 102710)
)
inten2 <- rbind(
  c(70714, 66631, 72027, 24929, 79925),
  c(70714, 66631, 72027, 24929, 79925),
  c(259247, 178742, 161464, 210940, 210601)
)
fake <- data.frame(
  no_int = 1:3, rt = c(11, 11, 11),
  rt_mz = c(1100.0119, 1100.0141, 1100.0245),
  rt_no_mz = c(11100.0119, 11100.0141, 11100.0245),
  mz = c(100.0119, 100.0141, 100.0245),
  avg = c(52666, 2620667.8, 171259.8), count = c(5, 5, 5),
  b_rt_mz = c(1100.0114, 1100.0114, 1100.0244),
  b_avg = c(62845.2, 62845.2, 204198.8), b_count = c(5, 5, 5),
  a_b = c(0.838, 41.7, 0.839), b_rt = c(11, 11, 11),
  score_one = c(12, 100, 24), score_avg = c(21.43, 100, 12.8),
  m1_iso = c(0, 0, 0), m2_iso = c(0, 0, 0), m3_iso = c(0, 0, 0),
  stringsAsFactors = FALSE
)
fake$inten1 <- inten1
fake$inten2 <- inten2

## 故意用超长组名，顺带验证表名清洗（原来会 addWorksheet 报错中断）
sh <- .dmf_sheet_diff("Group A", "Group B", " 80%", fake, samples_a, samples_b)
cat("pval 类型:", class(sh$cols$pval), "值:",
    paste(signif(sh$cols$pval, 8), collapse = ", "), "\n")
stopifnot(is.numeric(sh$cols$pval), !any(is.na(sh$cols$pval)))

f <- file.path(tempdir(), "diff_sheet.xlsx")
dmf_write_sheets(list(sh), f)

ex <- file.path(tempdir(), "diff_unzip")
unlink(ex, recursive = TRUE); dir.create(ex)
utils::unzip(f, exdir = ex)
xml <- paste(readLines(file.path(ex, "xl", "worksheets", "sheet1.xml"), warn = FALSE),
             collapse = "")
wbx <- paste(readLines(file.path(ex, "xl", "workbook.xml"), warn = FALSE), collapse = "")

cat("工作表名:", regmatches(wbx, regexpr("<sheet [^>]*name=\"[^\"]*\"", wbx)) |>
      sub(pattern = ".*name=\"", replacement = "") |>
      sub(pattern = "\"$", replacement = ""), "\n")
cat("含 <f> 公式节点:", grepl("<f>", xml, fixed = TRUE), "\n")

cells <- regmatches(xml, gregexpr('<c r="P[0-9]+"( [^>]*)?>.*?</c>', xml))[[1]]
cells <- cells[grepl('r="P(3|4|5)"', cells)]   # 只取数据行（第 2 行是表头 "P值"）
cat("P 列数据行单元格:\n"); cat(paste("  ", cells), sep = "\n")
cat("P 列数据行文本单元格(t=\"s\")数:", sum(grepl('t="s"', cells)),
    " 数值单元格(t=\"n\")数:", sum(grepl('t="n"', cells)), "\n")
stopifnot(sum(grepl('t="s"', cells)) == 0L,
          sum(grepl('t="n"', cells)) == 3L)
cat("\n结论：P 列写盘后是数值单元格，Excel 打开即为数字。\n")

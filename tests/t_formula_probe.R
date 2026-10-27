## 探针：openxlsx::writeData 写入以 "=" 开头的字符串，到底是文本还是公式？
library(openxlsx)
f <- file.path(tempdir(), "probe_formula.xlsx")
wb <- createWorkbook(); addWorksheet(wb, "s1")
df <- data.frame(a = c(1, 2), b = c("=TTEST(A1:A2,A1:A2,2,2)", "x"), stringsAsFactors = FALSE)
writeData(wb, "s1", df, startCol = 1, startRow = 1, colNames = FALSE)
saveWorkbook(wb, f, overwrite = TRUE)

## 解开 xlsx 看 sheet1.xml
ex <- file.path(tempdir(), "probe_unzip")
unlink(ex, recursive = TRUE); dir.create(ex)
utils::unzip(f, exdir = ex)
xml <- paste(readLines(file.path(ex, "xl", "worksheets", "sheet1.xml"), warn = FALSE), collapse = "")
cat("SHEET_XML:\n", xml, "\n\n")
cat("HAS_<f> :", grepl("<f>", xml, fixed = TRUE), "\n")
cat("HAS_str :", grepl("t=\"str\"", xml, fixed = TRUE), "\n")

## 验证 dmf_ttest_pval 与 Excel TTEST(...,2,2) / t.test(var.equal=TRUE) 一致
suppressWarnings({
  src <- readLines("R/dmetfinder_functions.R", warn = FALSE, encoding = "UTF-8")
})
## 只取需要的函数，避免 source 整个文件（依赖 shiny 等）
start <- grep("^dmf_ttest_pval <- function", src)
end <- start - 1L + which(src[start:length(src)] == "}")[1]
eval(parse(text = paste(src[start:end], collapse = "\n")))

m1 <- rbind(
  c(35894, 69524, 64426, 33134, 60352),
  c(3586126, 69524, 268608, 4119029, 5060052),
  c(260877, 207041, 169412, 116259, 102710)
)
m2 <- rbind(
  c(70714, 66631, 72027, 24929, 79925),
  c(70714, 66631, 72027, 24929, 79925),
  c(259247, 178742, 161464, 210940, 210601)
)
## 加两种边界：含 NA、组内全相同
m1 <- rbind(m1, c(1, NA, 3, 4, 5), c(7, 7, 7, 7, 7))
m2 <- rbind(m2, c(2, 4, 6, NA, 8), c(7, 7, 7, 7, 7))

p_vec <- dmf_ttest_pval(m1, m2)
for (i in seq_len(nrow(m1))) {
  ref <- tryCatch(suppressWarnings(t.test(m1[i, ], m2[i, ], var.equal = TRUE)$p.value),
                  error = function(e) NA_real_)  # 组内全相同 -> t.test 报错，见下方说明
  cat(sprintf("row %d: R-vec = %.12g | t.test = %s | diff = %s\n",
              i, p_vec[i],
              ifelse(is.na(ref), "NA(常量组)", format(ref, digits = 12)),
              ifelse(is.na(ref), "-", format(abs(p_vec[i] - ref), scientific = TRUE, digits = 3))))
}
## 常量组：两组都恒定且相等 -> 视为无差异，p = 1
stopifnot(identical(p_vec[5], 1))
cat("\n常量组（两组强度全相同）判定为 p = 1，符合预期。\n")

## 旧公式若在图里被算出来，应该是多少（用 python 之外的方式核对量级）
cat("\n前 3 行 P 值（即表格 P 列应有的数值）:\n")
print(signif(p_vec[1:3], 6))

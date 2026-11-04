suppressMessages(library(readxl))

# 用 readxl（dmf_read_samples 用的就是它）看真实列布局，空列不会被丢
for (f in c("demo_data/groupA.xlsx",
            "out/ms1_real/xlsx/Clean_MS1_Data_GroupA.xlsx",
            "out/ms1_real/xlsx/Clean_MS1_Data_GroupB.xlsx")) {
  raw <- as.data.frame(read_excel(f, col_names = FALSE, .name_repair = "minimal"))
  cat("\n==== ", f, " ====\n", sep = "")
  cat("维度:", nrow(raw), "x", ncol(raw), "\n")
  # 每列是否全空
  empty <- vapply(raw, function(x) all(is.na(x)), logical(1))
  cat("全空列位置:", which(empty), "\n")
  # 按 6 列一块：首行第 s 列的值
  starts <- seq.int(1L, ncol(raw), by = 6L)
  starts <- starts[starts + 4L <= ncol(raw)]
  cat("块起始列:", starts, "\n")
  first <- vapply(starts, function(s) as.character(raw[[s]][1]), character(1))
  cat("首行样品号:", first, "\n")
  cnt <- vapply(starts, function(s) {
    v <- suppressWarnings(as.numeric(raw[[s + 3L]][-1]))
    sum(!is.na(v))
  }, numeric(1))
  cat("各块离子数(mz 非空):", cnt, "\n")
}

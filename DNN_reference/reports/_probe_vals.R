invisible(suppressWarnings(Sys.setlocale("LC_ALL","Chinese (Simplified)_China.utf8")))
suppressPackageStartupMessages(library(rhdf5))
f <- "source_data/EDML_trainTestCalData15.mat"

for (nm in c("trainY","calY","testY")) {
  y <- h5read(f, nm)
  cat(sprintf("%-7s n=%4d  values: %s\n", nm, length(y),
      paste(sort(unique(as.numeric(y))), collapse=",")))
  tb <- table(as.numeric(y))
  cat(sprintf("        class counts: 0=%d 1=%d\n", tb[["0"]], tb[["1"]]))
}
cat("\n")
# 读一个样本看像素
x <- h5read(f, "trainX", index=list(NULL, NULL, 1:4))
cat("trainX 前4个样本的 R 维度:", dim(x), "\n")
cat("注意: rhdf5 读出的维度顺序与 MATLAB 一致，但 h5py 会转置\n\n")
for (i in 1:4) {
  m <- x[,,i]
  cat(sprintf("样本 %d: dim=%dx%d  min=%.4f max=%.4f NA=%d 非零占比=%.3f\n",
      i, nrow(m), ncol(m), min(m,na.rm=TRUE), max(m,na.rm=TRUE),
      sum(is.na(m)), mean(m != 0, na.rm=TRUE)))
}
cat("\n== 第1个样本的前3行前8列 ==\n")
print(round(x[1:3, 1:8, 1], 4))
cat("\n== 最后一行（应为窗口标记行，0/1）==\n")
print(table(x[nrow(x[,,1]), , 1]))
cat("\n== 全矩阵最大值（跨4个样本）==\n")
cat(max(x, na.rm=TRUE), "\n")

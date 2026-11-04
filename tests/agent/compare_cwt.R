# 同一段 profile 谱：cwt 打峰 vs vendor 打峰 vs 局部极大
# 用法: Rscript compare_cwt.R <profile> <vendor_centroid> <cwt_slice>
suppressMessages({
  if (!requireNamespace("mzR", quietly = TRUE)) stop("需要 mzR")
})
args <- commandArgs(trailingOnly = TRUE)
pf <- args[1]; vf <- args[2]; wf <- args[3]

op <- function(p) { m <- mzR::openMSfile(p); list(m = m, h = mzR::header(m)) }
P <- op(pf); V <- op(vf); W <- op(wf)
on.exit({ mzR::close(P$m); mzR::close(V$m); mzR::close(W$m) }, add = TRUE)

# 用 RT 把 cwt 切片对回原文件
key <- function(x) sprintf("%.4f", x / 60)
pkey <- key(P$h$retentionTime); vkey <- key(V$h$retentionTime)

local_max <- function(y) {
  n <- length(y); if (n < 3) return(0L)
  sum(y[2:(n - 1)] > y[1:(n - 2)] & y[2:(n - 1)] >= y[3:n])
}
# 相邻 0.02 Da 内合并，数“成形的峰”
count_merged <- function(mz, tol = 0.02) {
  if (!length(mz)) return(0L)
  o <- sort(mz); g <- 1L
  for (i in 2:length(o)) if (o[i] - o[i - 1] > tol) g <- g + 1L
  g
}

rows <- list()
for (i in seq_len(nrow(W$h))) {
  k <- key(W$h$retentionTime[i])
  pi <- match(k, pkey); vi <- match(k, vkey)
  if (is.na(pi) || is.na(vi)) next
  pp <- mzR::peaks(P$m, pi); vp <- mzR::peaks(V$m, vi); wp <- mzR::peaks(W$m, i)
  y <- as.numeric(pp[, 2])
  rows[[length(rows) + 1L]] <- data.frame(
    rt = round(W$h$retentionTime[i] / 60, 3),
    level = W$h$msLevel[i],
    n_profile = nrow(pp),
    n_localmax = local_max(y),
    n_vendor = nrow(vp),
    n_cwt = nrow(wp),
    n_cwt_merged = count_merged(as.numeric(wp[, 1])),
    n_vendor_merged = count_merged(as.numeric(vp[, 1])),
    stringsAsFactors = FALSE
  )
}
res <- do.call(rbind, rows)
cat("\n== 逐张谱 ==\n"); print(res, row.names = FALSE)

cat("\n== 汇总 ==\n")
for (lv in sort(unique(res$level))) {
  s <- res[res$level == lv, ]
  cat(sprintf(paste0(
    "MS%d  n=%d 张\n",
    "  profile 点  中位 %6d   局部极大 中位 %6d\n",
    "  vendor     中位 %6d   (0.02Da 合并后 %6d)\n",
    "  cwt        中位 %6d   (0.02Da 合并后 %6d)\n",
    "  vendor/localmax = %.3f    cwt/localmax = %.3f    cwt/vendor = %.2f\n"),
    lv, nrow(s),
    as.integer(median(s$n_profile)), as.integer(median(s$n_localmax)),
    as.integer(median(s$n_vendor)), as.integer(median(s$n_vendor_merged)),
    as.integer(median(s$n_cwt)), as.integer(median(s$n_cwt_merged)),
    median(s$n_vendor / pmax(s$n_localmax, 1)),
    median(s$n_cwt / pmax(s$n_localmax, 1)),
    median(s$n_cwt / pmax(s$n_vendor, 1))
  ))
}

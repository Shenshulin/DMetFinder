# 检查真实 centroid mzML 上 looks_like_profile() 的判定，确认不会被二次收敛
# 用法: Rscript check_profile_heuristic.R <mzML 路径> [抽样张数]
suppressMessages({
  if (!requireNamespace("mzR", quietly = TRUE)) stop("需要 mzR")
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("用法: Rscript check_profile_heuristic.R <mzML> [n]")
path <- args[1]
nsample <- if (length(args) >= 2) as.integer(args[2]) else 200L

# 取被测函数本体（与 FeatureGeter_server.R 逐字相同）
looks_like_profile <- function(mz) {
  if (length(mz) < 20) return(FALSE)
  d <- diff(sort(mz))
  d <- d[d > 0]
  if (length(d) < 5) return(FALSE)
  stats::median(d) < 0.005
}

ms <- mzR::openMSfile(path)
on.exit(mzR::close(ms), add = TRUE)
hdr <- mzR::header(ms)
n <- nrow(hdr)

# 均匀抽样，覆盖整个 RT 范围
idx <- unique(round(seq(1, n, length.out = min(nsample, n))))

res <- data.frame(
  seq = idx,
  msLevel = hdr$msLevel[idx],
  rt_min = round(hdr$retentionTime[idx] / 60, 3),
  npeaks = NA_integer_,
  med_gap = NA_real_,
  is_profile = NA,
  stringsAsFactors = FALSE
)

for (k in seq_along(idx)) {
  p <- mzR::peaks(ms, idx[k])
  mz <- as.numeric(p[, 1])
  mz <- sort(mz)
  d <- if (length(mz) > 1) diff(mz) else numeric(0)
  d <- d[d > 0]
  res$npeaks[k] <- length(mz)
  res$med_gap[k] <- if (length(d)) stats::median(d) else NA_real_
  res$is_profile[k] <- looks_like_profile(mz)
}

cat("\n文件: ", basename(path), "\n", sep = "")
cat("谱图总数: ", n, "  抽样: ", length(idx), " 张\n\n", sep = "")

cat("== 判定结果 ==\n")
tb <- table(res$msLevel, res$is_profile, useNA = "no")
print(tb)
cat("\n被判成 profile 的张数: ", sum(res$is_profile, na.rm = TRUE), " / ", nrow(res), "\n", sep = "")

cat("\n== 峰数与峰间距（按 MS 级别）==\n")
for (lv in sort(unique(res$msLevel))) {
  s <- res[res$msLevel == lv, ]
  cat(sprintf("MS%d  n=%3d  峰数 min/中位/max = %d / %d / %d   间距中位 min/中位/max = %.5f / %.5f / %.5f\n",
              lv, nrow(s),
              min(s$npeaks), as.integer(median(s$npeaks)), max(s$npeaks),
              min(s$med_gap, na.rm = TRUE),
              median(s$med_gap, na.rm = TRUE),
              max(s$med_gap, na.rm = TRUE)))
}

# 临界样本：间距最接近 0.005 的几张
cat("\n== 间距最小的 5 张（越接近 0.005 越危险）==\n")
o <- order(res$med_gap)
print(res[o[seq_len(min(5, nrow(res)))], ], row.names = FALSE, digits = 5)

cat("\n判定: ")
if (sum(res$is_profile, na.rm = TRUE) == 0) {
  cat("全部 FALSE，不会被二次收敛。OK\n")
} else {
  cat("存在 TRUE，会被 centroid_profile_peaks() 二次收敛。需处理。\n")
}

# profile vs centroid mzML：同一张谱上三条路径的峰数、局部极大、离子流保留
#   A) profile 原始点数
#   B) DMetFinder 对 profile 的即时收敛（centroid_profile_peaks，20 ppm）
#   C) msconvert vendor centroid（ABI/Analyst peak picking）
# 用法: Rscript compare_centroid.R <profile.mzML> <centroid.mzML> [n]
suppressMessages({
  if (!requireNamespace("mzR", quietly = TRUE)) stop("需要 mzR")
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("用法: Rscript compare_centroid.R <profile> <centroid> [n]")
pf <- args[1]; cf <- args[2]
nsample <- if (length(args) >= 3) as.integer(args[3]) else 30L

core <- new.env(parent = globalenv())
sys.source("shiny_app/server/FeatureGeter_server.R", envir = core, keep.source = FALSE)

msp <- mzR::openMSfile(pf); msc <- mzR::openMSfile(cf)
on.exit({ mzR::close(msp); mzR::close(msc) }, add = TRUE)
hp <- mzR::header(msp)
stopifnot(nrow(hp) == nrow(mzR::header(msc)))

# profile 谱上的局部极大（严格大于左右邻）
local_max <- function(y) {
  n <- length(y)
  if (n < 3) return(integer(0))
  which(y[2:(n - 1)] > y[1:(n - 2)] & y[2:(n - 1)] >= y[3:n]) + 1L
}

rows <- list()
for (lv in c(1L, 2L)) {
  ids <- which(hp$msLevel == lv)
  ids <- ids[round(seq(1, length(ids), length.out = min(nsample, length(ids))))]
  for (i in ids) {
    pp <- mzR::peaks(msp, i); cp <- mzR::peaks(msc, i)
    mzp <- as.numeric(pp[, 1]); itp <- as.numeric(pp[, 2])
    mzc <- as.numeric(cp[, 1]); itc <- as.numeric(cp[, 2])

    o <- order(mzp); mzp <- mzp[o]; itp <- itp[o]
    b <- core$centroid_profile_peaks(mzp, itp)
    lmx <- local_max(itp)

    rows[[length(rows) + 1L]] <- data.frame(
      level = lv, seq = i, rt_min = round(hp$retentionTime[i] / 60, 3),
      n_profile = length(mzp),
      n_localmax = length(lmx),
      n_dmf_20ppm = length(b$mz),
      n_vendor = length(mzc),
      tic_keep_20ppm = if (sum(itp) > 0) sum(b$intensity) / sum(itp) else NA_real_,
      tic_keep_vendor = if (sum(itp) > 0) sum(itc) / sum(itp) else NA_real_,
      gap_profile = stats::median(diff(mzp)),
      stringsAsFactors = FALSE
    )
  }
}

res <- do.call(rbind, rows)
cat("\n== 逐张谱（前 12 行）==\n")
show <- res[seq_len(min(12, nrow(res))), ]
show$tic_keep_20ppm <- round(100 * show$tic_keep_20ppm, 1)
show$tic_keep_vendor <- round(100 * show$tic_keep_vendor, 1)
show$gap_profile <- signif(show$gap_profile, 3)
print(show, row.names = FALSE)

cat("\n== 汇总 ==\n")
for (lv in c(1L, 2L)) {
  s <- res[res$level == lv, ]
  cat(sprintf(paste0(
    "MS%d  n=%d 张\n",
    "   profile 点        : 中位 %6d  (min %d / max %d)\n",
    "   局部极大          : 中位 %6d\n",
    "   DMetFinder 20ppm : 中位 %6d  (保留 %.1f%%，是局部极大的 %.1f 倍)\n",
    "   vendor centroid  : 中位 %6d  (保留 %.1f%%，是局部极大的 %.1f 倍)\n",
    "   20ppm / vendor   : %.1f 倍\n",
    "   离子流保留         : 20ppm %.1f%%  /  vendor %.1f%%\n",
    "   profile 点间距     : 中位 %.5f Da\n"),
    lv, nrow(s),
    as.integer(median(s$n_profile)), min(s$n_profile), max(s$n_profile),
    as.integer(median(s$n_localmax)),
    as.integer(median(s$n_dmf_20ppm)),
    100 * median(s$n_dmf_20ppm / s$n_profile),
    median(s$n_dmf_20ppm / pmax(s$n_localmax, 1)),
    as.integer(median(s$n_vendor)),
    100 * median(s$n_vendor / s$n_profile),
    median(s$n_vendor / pmax(s$n_localmax, 1)),
    median(s$n_dmf_20ppm / pmax(s$n_vendor, 1)),
    100 * median(s$tic_keep_20ppm, na.rm = TRUE),
    100 * median(s$tic_keep_vendor, na.rm = TRUE),
    median(s$gap_profile)
  ))
}

cat("\n== 20 ppm 窗口 vs 实测点间距（窗口比间距窄则不合并）==\n")
g <- median(res$gap_profile)
for (mz in c(100, 300, 500, 800, 1200)) {
  w <- mz * 20e-6
  cat(sprintf("  m/z %4d : 20 ppm = %.5f Da，点间距 %.5f Da -> 每组合并约 %.1f 个点\n",
              mz, w, g, w / g))
}

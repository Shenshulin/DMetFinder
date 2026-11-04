# 真实 profile 样品上，DMetFinder 的即时收敛（20 ppm）到底要多久
# 用法: Rscript time_profile_path.R <profile.mzML>
suppressMessages({
  if (!requireNamespace("mzR", quietly = TRUE)) stop("需要 mzR")
})
args <- commandArgs(trailingOnly = TRUE)
pf <- args[1]

core <- new.env(parent = globalenv())
sys.source("shiny_app/server/FeatureGeter_server.R", envir = core, keep.source = FALSE)

ms <- mzR::openMSfile(pf); on.exit(mzR::close(ms), add = TRUE)
hdr <- mzR::header(ms)
n1 <- sum(hdr$msLevel == 1); n2 <- sum(hdr$msLevel == 2)

res <- list()
for (lv in c(1L, 2L)) {
  ids <- which(hdr$msLevel == lv)
  ids <- ids[round(seq(1, length(ids), length.out = min(5L, length(ids))))]
  for (i in ids) {
    p <- mzR::peaks(ms, i)
    mz <- as.numeric(p[, 1]); it <- as.numeric(p[, 2])
    o <- order(mz); mz <- mz[o]; it <- it[o]
    t <- system.time(core$centroid_profile_peaks(mz, it))[["elapsed"]]
    res[[length(res) + 1L]] <- data.frame(
      level = lv, seq = i, npoints = length(mz), sec = t,
      is_profile = core$looks_like_profile(mz), stringsAsFactors = FALSE)
  }
}
r <- do.call(rbind, res)
print(r, row.names = FALSE)

cat("\n== 外推到全文件 ==\n")
for (lv in c(1L, 2L)) {
  s <- r[r$level == lv, ]
  per <- mean(s$sec)
  n <- if (lv == 1L) n1 else n2
  cat(sprintf("MS%d: 单谱 %.2f s（中位 %d 点）x %d 张 = %.0f s（%.1f 小时）\n",
              lv, per, as.integer(median(s$npoints)), n, per * n, per * n / 3600))
}
tot <- mean(r$sec[r$level == 1]) * n1 + mean(r$sec[r$level == 2]) * n2
cat(sprintf("合计约 %.0f s（%.1f 小时）—— 仅即时收敛一项，不含读盘与后续分组\n", tot, tot / 3600))
cat(sprintf("判定：is_profile 全部 %s\n", if (all(r$is_profile)) "TRUE（会走收敛）" else "FALSE"))

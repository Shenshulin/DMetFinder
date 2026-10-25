# ============================================================
# Derive a DEMO peak table from the real Thermo .raw files
# ============================================================
# The two *_features.csv files in MSDIAL_TEST are MS2 feature lists
# (peak_name / precursor_mz / neutral-loss flags) - they carry NO retention
# time, so they cannot be used as an XIC input table.
#
# This script therefore performs a small, documented peak-picking pass on the
# MS1 scans of each real .raw file, randomly draws N features per sample
# (reproducible seed) and writes a peak table with
# feature_id / mz / rt / sample_id.
#
# IMPORTANT: this is a DERIVED demo table (real m/z and real apex RTs taken
# from real data, but not an MS-DIAL / MZmine export). It only exists to
# exercise the Peak Quality module on real Thermo data.
#
# Usage:
#   Rscript make_demo_peak_table.R [n_per_sample] [out_csv] [sample1,sample2,...]
# Examples:
#   Rscript make_demo_peak_table.R 8   .../peak_quality_demo_features.csv    P173,P181
#   Rscript make_demo_peak_table.R 100 .../peak_quality_demo_features100.csv  (all 4)
# ============================================================

invisible(tryCatch(Sys.setlocale("LC_ALL", "Chinese (Simplified)_China.utf8"),
                   error = function(e) NULL))
args <- commandArgs(trailingOnly = TRUE)

proj <- "G:/20170828 P_35D Seeds _screen 10Y and 10B _190315/DMetFinder1.0.3/DMetFinder"
source(file.path(proj, "shiny_app/server/FeatureGeter_server.R"), encoding = "UTF-8")

raw_dir  <- "G:/method_ms2/MSDIAL_TEST"
n_per    <- if (length(args) >= 1) as.integer(args[1]) else 8L
out_csv  <- if (length(args) >= 2) args[2] else file.path(raw_dir, "peak_quality_demo_features.csv")
samples  <- if (length(args) >= 3) strsplit(args[3], ",")[[1]] else c("P173", "P176", "P181", "P528")

SEED <- 20261019
cat(sprintf("n per sample: %d | samples: %s | out: %s\n",
            n_per, paste(samples, collapse = ", "), out_csv))

# ------------------------------------------------------------
# Peak-picking on the MS1 scans of one file
# ------------------------------------------------------------
pick_candidates <- function(file, floor_int = 2e5, min_int = 1e6) {
  cat("  reading", basename(file), "...\n")
  t0 <- Sys.time()
  ms <- read_ms_file(file)
  cat("    done in", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "s\n")

  st  <- ms$scan_table
  ms1 <- st[st$msLevel == 1, , drop = FALSE]
  cat("    MS1 scans:", nrow(ms1), "\n")

  rt_all <- numeric(0); mz_all <- numeric(0); int_all <- numeric(0)
  for (i in seq_len(nrow(ms1))) {
    sp <- ms$spectra[[as.character(ms1$scan[i])]]
    if (is.null(sp)) next
    keep <- sp$intensity >= floor_int
    if (!any(keep)) next
    rt_all  <- c(rt_all,  rep(ms1$StartTime[i], sum(keep)))
    mz_all  <- c(mz_all,  sp$mz[keep])
    int_all <- c(int_all, sp$intensity[keep])
  }
  rm(ms, st); invisible(gc(FALSE))
  cat("    MS1 peaks above floor:", length(rt_all), "\n")

  bin <- floor(mz_all / 0.01)
  ub  <- sort(unique(bin))
  mx  <- vapply(ub, function(b) max(int_all[bin == b]), numeric(1))
  ns  <- vapply(ub, function(b) sum(bin == b), integer(1))
  apx <- vapply(ub, function(b) rt_all[bin == b][which.max(int_all[bin == b])], numeric(1))
  mzc <- vapply(ub, function(b) mz_all[bin == b][which.max(int_all[bin == b])], numeric(1))

  cand <- data.frame(mz = mzc, apex_rt = apx, apex_int = mx,
                     n_scans = as.integer(ns), stringsAsFactors = FALSE)
  cand <- cand[cand$n_scans >= 6 & cand$apex_int >= min_int &
               cand$apex_rt >= 3 & cand$apex_rt <= 15, , drop = FALSE]
  cand
}

# ------------------------------------------------------------
# One block per sample: pick candidates, draw N at random
# ------------------------------------------------------------
blocks <- list()
for (k in seq_along(samples)) {
  s <- samples[k]
  cat("[", k, "/", length(samples), "] sample ", s, "\n", sep = "")
  cand <- pick_candidates(file.path(raw_dir, paste0(s, ".raw")))
  cat("    candidate features:", nrow(cand), "\n")

  # relax the intensity cut if a sample does not yield enough features
  if (nrow(cand) < n_per) {
    cand <- pick_candidates(file.path(raw_dir, paste0(s, ".raw")),
                            floor_int = 1e5, min_int = 3e5)
    cat("    relaxed threshold ->", nrow(cand), "candidates\n")
  }

  n_take <- min(n_per, nrow(cand))
  set.seed(SEED + k)                      # reproducible per sample
  idx <- sample.int(nrow(cand), n_take)
  sel <- cand[idx, , drop = FALSE]
  sel <- sel[order(sel$apex_rt), , drop = FALSE]

  blocks[[s]] <- data.frame(
    feature_id = sprintf("%s_F%03d", s, seq_len(n_take)),
    mz         = round(sel$mz, 4),
    rt         = round(sel$apex_rt, 3),
    sample_id  = s,
    stringsAsFactors = FALSE
  )
  cat("    drew", n_take, "feature(s)\n")
}

rows <- do.call(rbind, blocks)
rownames(rows) <- NULL
utils::write.csv(rows, out_csv, row.names = FALSE)
cat("\nwritten:", out_csv, "\n")
cat("rows:", nrow(rows), "| per sample:",
    paste(names(table(rows$sample_id)), table(rows$sample_id), sep = "=", collapse = ", "), "\n")
print(head(rows, 6))

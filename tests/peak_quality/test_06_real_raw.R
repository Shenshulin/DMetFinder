# ============================================================
# Test 06: real Thermo .raw file (optional, environment dependent)
# ============================================================
# This test only runs when a real .raw file and the Thermo RawFileReader
# .NET library are available. If they are not, it reports SKIP explicitly and
# does NOT claim that RAW parsing was verified.
#
# Default file: G:/method_ms2/MSDIAL_TEST/P173.raw
# Override with the environment variable PQ_RAW_TEST_FILE.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))

ROOT <- normalizePath(file.path(here, "../.."), winslash = "/")
pq_source_project(ROOT)

raw_file <- Sys.getenv("PQ_RAW_TEST_FILE", unset = "")
if (!nzchar(raw_file)) raw_file <- "G:/method_ms2/MSDIAL_TEST/P173.raw"

pq_section("real .raw availability")

if (!file.exists(raw_file)) {
  pq_skip(paste("real .raw not found:", raw_file,
                "- RAW parsing is NOT verified by this run"))
  pq_summary()
  quit(save = "no", status = 0)
}

cat("  file:", raw_file, "(",
    round(file.size(raw_file) / 1024^2, 1), "MB )\n")

ms <- tryCatch(pq_load_ms_file(raw_file), error = function(e) {
  pq_skip(paste("rawrr could not open the file:", conditionMessage(e),
                "- RAW parsing is NOT verified by this run"))
  NULL
})

if (is.null(ms)) {
  pq_summary()
  quit(save = "no", status = 0)
}

pq_assert(nrow(ms$scan_table) > 100, "real .raw: scans read")
pq_assert(all(ms$scan_table$msLevel == 1L), "real .raw: MS1-only view")
pq_assert(range(ms$scan_table$StartTime)[2] < 200,
          "real .raw: RT is in minutes, not seconds")
cat("  MS1 scans:", nrow(ms$scan_table), " RT:",
    round(range(ms$scan_table$StartTime), 2), "min\n")

pq_section("pick the strongest real MS1 peak as a feature")
# scan with the highest total intensity
tot <- vapply(ms$spectra, function(s) sum(s$intensity), numeric(1))
apex_scan <- names(which.max(tot))
sp <- ms$spectra[[apex_scan]]
idx <- which.max(sp$intensity)
target_mz <- sp$mz[idx]
apex_rt <- ms$scan_table$StartTime[ms$scan_table$scan == as.numeric(apex_scan)][1]
cat(sprintf("  m/z %.5f at RT %.3f min (scan %s, %d peaks)\n",
            target_mz, apex_rt, apex_scan, length(sp$mz)))

p <- pq_default_params()
p$rt_window <- 0.5

ms1 <- pq_ms1_index(ms)
x <- pq_extract_xic(ms, ms1, target_mz, apex_rt, p$rt_window, 10, "ppm", "max")
pq_assert(x$status == "ok", "real .raw: XIC extracted")
pq_assert(nrow(x$xic) > 10, "real .raw: XIC has more than 10 scans")
win <- pq_mz_window(target_mz, 10, "ppm")
in_win <- sp$intensity[sp$mz >= win[1] & sp$mz <= win[2]]
v_at_scan <- x$xic$intensity[x$xic$scan == as.numeric(apex_scan)]
pq_assert(length(v_at_scan) == 1 && abs(v_at_scan - max(in_win)) < 1e-6,
          "real .raw: XIC value equals the tallest raw peak in the m/z window for that scan")

pq_section("full pipeline on the real file")
feat <- pq_standardize_features(
  data.frame(feature_id = "REAL_APEX", mz = target_mz, rt = apex_rt,
             sample_id = "P173", stringsAsFactors = FALSE),
  list(feature_id = "feature_id", mz = "mz", rt = "rt", sample_id = "sample_id",
       area = "", height = "", polarity = "", charge = "", software = "",
       original_id = ""),
  "min")
lookup <- pq_match_samples("P173", raw_file)
pq_assert_equal(lookup$match[1], "exact", "real .raw: file matched by sample name")

res <- pq_process_features(feat$ok, p, lookup, ms_cache = new.env(parent = emptyenv()))
row <- res$rows[1, ]
print(row[, c("feature_id", "mz", "input_rt", "start_rt", "apex_rt", "end_rt",
              "n_points", "peak_cor", "SNR", "boundary_status", "score_status")])

pq_assert(row$score_status %in% c("ok", "skipped"),
          "real .raw: scoring ran (never silently dropped)")
pq_assert(!is.na(row$apex_rt), "real .raw: boundaries located")
pq_assert(row$boundary_status %in% names(PQ_STATUS_LABELS),
          "real .raw: boundary status is a documented value")
pq_assert(abs(row$apex_rt - apex_rt) < 1.0,
          "real .raw: detected apex close to the strongest scan")
if (row$score_status == "ok") {
  pq_assert(row$peak_cor > 0, "real .raw: peak_cor computed from the real XIC")
  pq_assert(row$SNR > 0, "real .raw: SNR computed from the real XIC")
}

pq_summary()

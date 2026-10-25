# ============================================================
# Test 08: job size (no silent truncation) and peak presence
# ============================================================
# Covers the two issues reported after the first real 20-file run:
#   1. a 3450-feature aligned table x 20 raw files was cut down to 5000 rows,
#      so 18 samples were never evaluated;
#   2. a compound that is simply not in a sample was reported as a scoring
#      failure and dragged the per-feature summary down.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))

ROOT <- normalizePath(file.path(here, "../.."), winslash = "/")
pq_source_project(ROOT)
source(file.path(here, "fixtures/make_fixtures.R"))

# ------------------------------------------------------------
# 1. Job planning: expansion must never be truncated
# ------------------------------------------------------------
pq_section("job size: an aligned table x 20 files is processed in full")
plan <- pq_plan_job(3450, 20, broadcast = TRUE)
pq_assert_equal(plan$rows_planned, 69000L, "3450 features x 20 files = 69000 rows")
pq_assert(!plan$truncate_features, "3450 features are below the 20000 default cap")
pq_assert(!plan$abort, "69000 rows are below the 200000 default limit")
pq_assert(length(plan$messages) == 0, "nothing to report when the job fits")

pq_section("job size: the feature cap is applied to the peak table, not the expansion")
plan2 <- pq_plan_job(30000, 20, broadcast = TRUE, max_features = 20000)
pq_assert(plan2$truncate_features, "30000 features exceed the 20000 cap")
pq_assert_equal(plan2$keep_features, 20000L, "the cap keeps 20000 features")
pq_assert_equal(plan2$rows_planned, 400000L, "which expands to 400000 rows")
pq_assert(plan2$abort, "that also exceeds the row limit and aborts")
pq_assert_contains(plan2$messages[1], "only the first 20000",
                   "the truncation is reported, never silent")

pq_section("job size: an over-large job aborts instead of dropping rows")
plan3 <- pq_plan_job(20000, 20, broadcast = TRUE, max_features = 20000,
                     max_rows = 200000)
pq_assert(plan3$abort, "400000 rows > 200000 limit -> abort")
pq_assert_contains(plan3$messages, "Nothing was processed",
                   "the message states that nothing ran")

pq_section("job size: a by-column table is not multiplied")
plan4 <- pq_plan_job(500, 20, broadcast = FALSE)
pq_assert_equal(plan4$rows_planned, 500L, "no expansion in by-column mode")
pq_assert(!plan4$abort, "500 rows are fine")

# ------------------------------------------------------------
# 2. Presence rules, exercised directly
# ------------------------------------------------------------
pq_section("presence: rules in isolation")
mk_diag <- function(n_scans = 121, n_mz = 121, noise = 100) {
  list(n_scans_in_window = n_scans, n_scans_with_signal = n_scans,
       n_scans_missing = 0L, n_mz_matched = n_mz, median_ppm_dev = 0,
       noise = noise)
}
# a smooth peak: 60 points, apex 10000 above a baseline of 500
mk_xic_peak <- function(amp = 10000, n = 61, base = 500) {
  k <- seq_len(n)
  data.frame(rt = 5.5 + k * 0.005,
             intensity = base + amp * exp(-((k - 31)^2) / (2 * 8^2)),
             scan = k, n_mz = 1L, ppm_dev = 0,
             stringsAsFactors = FALSE)
}
mk_peak <- function(xic) {
  i <- which.max(xic$intensity)
  list(apex_intensity = xic$intensity[i], baseline = min(xic$intensity),
       apex_rt = xic$rt[i], start_rt = xic$rt[1], end_rt = xic$rt[nrow(xic)],
       n_points = nrow(xic))
}
pp <- pq_default_params()

x <- mk_xic_peak()
pr <- pq_assess_presence(mk_diag(), x, mk_peak(x), pp)
pq_assert_equal(pr$presence, "present", "a 100x peak is present")
pq_assert(pr$snr > 5, "height/noise is reported for audit")

pr <- pq_assess_presence(mk_diag(n_mz = 0), x, mk_peak(x), pp)
pq_assert_equal(pr$presence, "absent", "no ion in the window -> absent")
pq_assert_contains(pr$reason, "no ion inside the m/z tolerance window",
                   "absence reason is explicit")

pr <- pq_assess_presence(mk_diag(n_scans = 0, n_mz = 0), x, mk_peak(x), pp)
pq_assert_equal(pr$presence, "unknown",
                "no MS1 scan in the window -> presence not determined")

# signal present, but far below the noise
x_low <- mk_xic_peak(amp = 200, base = 500)
pr <- pq_assess_presence(mk_diag(noise = 300), x_low, mk_peak(x_low), pp)
pq_assert_equal(pr$presence, "absent", "0.7x noise -> absent")
pq_assert_contains(pr$reason, "point-to-point noise", "the noise test is explained")

# the same trace is present when the test is disabled
pp_off <- pp
pp_off$detect_absent <- FALSE
pr <- pq_assess_presence(mk_diag(noise = 300), x_low, mk_peak(x_low), pp_off)
pq_assert_equal(pr$presence, "present", "detect_absent = FALSE disables the test")

# a constant background ion (no peak at all)
x_flat <- data.frame(rt = 5.5 + seq_len(30) * 0.005,
                     intensity = rep(500, 30), scan = 1:30, n_mz = 1L,
                     ppm_dev = 0, stringsAsFactors = FALSE)
pr <- pq_assess_presence(mk_diag(noise = 0), x_flat, mk_peak(x_flat), pp)
pq_assert_equal(pr$presence, "absent",
                "constant background ion -> absent, not a flat peak")

# too few points to form a peak
x_sparse <- x[1:2, , drop = FALSE]
pr <- pq_assess_presence(mk_diag(), x_sparse, mk_peak(x_sparse), pp)
pq_assert_equal(pr$presence, "absent", "2 points -> absent")
pq_assert_contains(pr$reason, "absent_min_points", "the point rule is explained")

# a narrow but real peak with few points must NOT be called absent: with
# fewer than PQ_NOISE_MIN_POINTS the noise test is skipped on purpose
x_narrow <- x[10:14, , drop = FALSE]
pr <- pq_assess_presence(mk_diag(noise = 1e9), x_narrow, mk_peak(x_narrow), pp)
pq_assert_equal(pr$presence, "present",
                "a sparse but strong peak is present (noise test skipped < 6 points)")

# ------------------------------------------------------------
# 3. Pipeline: a background ion is absent, a real peak is scored
# ------------------------------------------------------------
pq_section("pipeline: absent rows are kept, not scored and not failures")
fx <- pq_fixture_make(file.path(tempdir(), "pq_fix_presence"))

# 301.1234 carries a real peak; 120.0500 is a constant background ion in the
# fixture, i.e. an ion that is there but a compound that is not
tab <- data.frame(
  feature_id = c("REAL", "BACKGROUND", "NOTHING"),
  mz = c(301.1234, 120.0500, 999.9000),
  rt = c(6.00, 6.00, 6.00),
  sample_id = "S1",
  stringsAsFactors = FALSE
)
tab_p <- file.path(tempdir(), "pq_fix_presence", "presence_table.csv")
utils::write.csv(tab, tab_p, row.names = FALSE)

map <- list(feature_id = "feature_id", mz = "mz", rt = "rt",
            sample_id = "sample_id", area = "", height = "", polarity = "",
            charge = "", software = "", original_id = "")
std <- pq_standardize_features(pq_read_table(tab_p), map, "min")
lookup <- pq_match_samples("S1", fx$mzml)
pres <- pq_process_features(std$ok, pp, lookup,
                            ms_cache = new.env(parent = emptyenv()))
r <- pres$rows
rownames(r) <- r$feature_id

pq_assert_equal(nrow(r), 3L, "all three rows are reported")
pq_assert_equal(r["REAL", "presence"], "present", "real peak -> present")
pq_assert_equal(r["REAL", "score_status"], "ok", "real peak -> scored")
pq_assert_equal(r["BACKGROUND", "presence"], "absent",
                "constant background ion -> absent")
pq_assert_equal(r["BACKGROUND", "score_status"], "absent",
                "absent row is not scored")
pq_assert(is.na(r["BACKGROUND", "peak_cor"]), "no score is invented for it")
pq_assert_equal(r["NOTHING", "presence"], "absent",
                "an m/z that is not in the file -> absent")

fails <- pq_failures(r)
abst <- pq_absent_table(r)
pq_assert_equal(nrow(fails), 0L, "no failure is reported for absent peaks")
pq_assert_equal(nrow(abst), 2L, "both absent rows appear in the absent table")
pq_assert_contains(names(abst), "presence_snr", "the audit columns are exported")

# ------------------------------------------------------------
# 4. Feature summary: absent samples do not penalise the feature
# ------------------------------------------------------------
pq_section("summary: percentages are computed over present samples only")
mkrow <- function(fid, sid, presence, score, cor, snr, bstat = "ok") {
  data.frame(feature_id = fid, sample_id = sid, mz = 300, input_rt = 6,
             start_rt = 5.9, apex_rt = 6, end_rt = 6.1, n_points = 40,
             peak_cor = cor, SNR = snr, presence = presence,
             boundary_status = bstat, score_status = score,
             failure_reason = NA_character_, file = paste0(sid, ".raw"),
             median_ppm_dev = 1, apex_offset = 0.01,
             stringsAsFactors = FALSE)
}
rows <- rbind(
  mkrow("F1", "S1", "present", "ok", 0.95, 100),
  mkrow("F1", "S2", "present", "ok", 0.85, 80),
  mkrow("F1", "S3", "present", "skipped", NA, NA, "too_few_points"),
  mkrow("F1", "S4", "absent", "absent", NA, NA, "no_signal"),
  mkrow("F1", "S5", "absent", "absent", NA, NA, "no_signal"),
  mkrow("F2", "S1", "absent", "absent", NA, NA, "no_signal"),
  mkrow("F2", "S2", "absent", "absent", NA, NA, "no_signal")
)
sm <- pq_feature_summary(rows)
f1 <- sm[sm$feature_id == "F1", ]
f2 <- sm[sm$feature_id == "F2", ]

pq_assert_equal(f1$n_samples, 5L, "F1: 5 samples")
pq_assert_equal(f1$n_present, 3L, "F1: present in 3 samples")
pq_assert_equal(f1$n_absent, 2L, "F1: absent in 2 samples")
pq_assert_equal(f1$pct_absent, 40, "F1: 40% absent")
pq_assert_equal(f1$pct_scored, round(100 * 2 / 3, 1),
                "F1: 66.7% of the PRESENT samples scored (not 40% of 5)")
pq_assert_equal(f1$median_peak_cor, 0.9, "F1: median over present samples")
pq_assert_equal(f1$min_peak_cor, 0.85, "F1: worst over present samples")
pq_assert_equal(f1$consistency, "variable", "F1: 2/3 scored -> variable")
pq_assert_equal(f2$consistency, "absent_everywhere",
                "F2: absent in every sample has its own class")
pq_assert(is.na(f2$pct_scored), "F2: no percentage is computed from zero samples")

pq_section("summary: an absent row can never influence the median")
rows$peak_cor[rows$presence == "absent"] <- 0.01  # deliberately absurd
sm2 <- pq_feature_summary(rows)
pq_assert_equal(sm2$median_peak_cor[sm2$feature_id == "F2"], NA_real_,
                "F2: scores from absent rows are ignored")
pq_assert_equal(sm2$min_peak_cor[sm2$feature_id == "F1"], 0.85,
                "F1: worst value still comes from a present sample")

# ------------------------------------------------------------
# 5. Exports carry the split
# ------------------------------------------------------------
pq_section("exports: absent peaks have their own sheet and csv")
xl <- file.path(tempdir(), "pq_presence.xlsx")
pq_export_xlsx(xl, r, pres$detail, pp,
               mapping = map, lookup = lookup,
               summary = pq_feature_summary(r))
sheets <- readxl::excel_sheets(xl)
pq_assert("AbsentPeaks" %in% sheets, "XLSX has an AbsentPeaks sheet")
pq_assert("Failures" %in% sheets, "XLSX still has the Failures sheet")
pq_assert("presence" %in% names(readxl::read_excel(xl, "Results")),
          "Results sheet carries the presence column")
pq_assert_equal(nrow(readxl::read_excel(xl, "AbsentPeaks")), 2L,
                "AbsentPeaks holds both absent rows")

zp <- file.path(tempdir(), "pq_presence.zip")
pq_export_report_zip(zp, file.path(tempdir(), "pq_presence_zip"), r,
                     pres$detail, pp, mapping = map, lookup = lookup,
                     max_plots = 1,
                     summary = pq_feature_summary(r))
zn <- utils::unzip(zp, list = TRUE)$Name
pq_assert("peak_quality_absent.csv" %in% zn, "ZIP carries peak_quality_absent.csv")
pq_assert("peak_quality_failures.csv" %in% zn, "ZIP still carries the failure list")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

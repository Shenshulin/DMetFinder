# ============================================================
# Test 07: aligned peak tables (MS-DIAL style) + feature summary
# ============================================================
# An MS-DIAL alignment result is ONE ROW PER FEATURE with the cohort-average
# m/z and RT and no sample column. This file covers:
#   - column-name guessing for the aligned layout
#   - expansion to feature x raw file
#   - running the pipeline on the expanded table
#   - the feature-level summary (median + worst value, consistency classes)
#   - the new export sheets / csv files
# ============================================================

here <- dirname(normalizePath(sub("^--file=", "",
  commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))])))
ROOT <- normalizePath(file.path(here, "../.."), winslash = "/", mustWork = FALSE)
source(file.path(here, "helpers.R"))
pq_source_project(ROOT)
source(file.path(here, "fixtures/make_fixtures.R"))

fx <- pq_fixture_make(file.path(tempdir(), "pq_fix_aligned"))

# ------------------------------------------------------------
pq_section("MS-DIAL aligned layout: column guessing")
# ------------------------------------------------------------
# the three features really exist in the synthetic mzML files, so the run
# exercises the whole chain instead of only the plumbing
tr <- fx$truth[fx$truth$feature_id %in% c("F_CLEAN", "F_NOISY", "F_TWO"), ]
al <- data.frame(
  `Alignment ID`    = seq_len(nrow(tr)),
  `Average Rt(min)` = tr$rt,
  `Average Mz`      = tr$mz,
  `Metabolite name` = c("a", "b", "c"),
  `P173 Height`     = c(1.2e6, 3.4e6, 9.9e5),
  `P181 Height`     = c(1.1e6, 3.1e6, 8.7e5),
  check.names = FALSE
)
g <- pq_guess_mapping(names(al))
pq_assert_equal(g$feature_id, "Alignment ID", "Alignment ID -> feature_id")
pq_assert_equal(g$mz, "Average Mz", "Average Mz -> mz")
pq_assert_equal(g$rt, "Average Rt(min)", "Average Rt(min) -> rt")
pq_assert_equal(g$sample_id, "", "aligned table has no sample_id column")
pq_assert_equal(g$height, "",
  "per-sample '<name> Height' columns are NOT mistaken for the height field")

good <- data.frame(AlignmentID = 1, Height = 5, check.names = FALSE)
pq_assert_equal(pq_guess_mapping(names(good))$height, "Height",
                "a plain 'Height' column is still detected")

# ------------------------------------------------------------
pq_section("expansion of an aligned table")
# ------------------------------------------------------------
mapping <- list(feature_id = "Alignment ID", mz = "Average Mz",
                rt = "Average Rt(min)", sample_id = "", area = "", height = "",
                polarity = "", charge = "", software = "", original_id = "")
std <- pq_standardize_features(al, mapping, "min")
pq_assert(nrow(std$ok) == 3 && length(std$errors) == 0, "aligned table standardised")
pq_assert(all(is.na(std$ok$sample_id)), "no sample id in the aligned table")

files <- c(fx$mzml, fx$mzml2, fx$mzxml)
exp3 <- pq_expand_features(std$ok, files)
pq_assert(nrow(exp3) == 9, "3 features x 3 files = 9 rows")
real_mz <- tr$mz[match(as.character(exp3$feature_id), as.character(std$ok$feature_id))]
pq_assert(length(unique(exp3$sample_id)) == 3, "one sample per raw file")
pq_assert(all(table(exp3$feature_id) == 3), "every feature present in every sample")
pq_assert(all(table(exp3$sample_id) == 3), "every sample holds every feature")
pq_assert(all(exp3$mz == real_mz), "the shared average m/z is kept for all samples")
pq_assert(nrow(unique(exp3[, c("feature_id", "mz", "rt_min")])) == 3,
          "the shared average m/z and RT are identical across samples")
pq_assert(isTRUE(all(exp3$aligned)), "rows are flagged as aligned")
pq_assert(nrow(pq_expand_features(std$ok, character(0))) == 3,
          "no files -> table returned unchanged")

# ------------------------------------------------------------
pq_section("running the pipeline on an aligned table")
# ------------------------------------------------------------
lookup <- pq_match_samples(unique(exp3$sample_id), files, NULL)
pq_assert(all(lookup$match %in% c("exact", "contains")),
          "expanded sample ids match the raw files")

params <- pq_default_params()
params$rt_window <- 0.30
params$sample_scope <- "all_files"
res <- pq_process_features(exp3, params, lookup,
                           ms_cache = new.env(parent = emptyenv()),
                           log_fun = function(...) invisible(NULL),
                           progress_fun = function(v, d) invisible(NULL))
pq_assert(nrow(res$rows) == 9, "one result row per feature x sample")
pq_assert(sum(!is.na(res$rows$peak_cor)) >= 6,
          "most aligned rows are scored (aligned RT is an average, some drift)")
pq_assert(all(res$rows$rt_unit == "min"), "RT unit recorded")
pq_assert(!any(is.na(res$rows$sample_id)), "every result row carries a sample id")
pq_assert(all(res$rows$mz_tol == "10 ppm") ||
          all(grepl("ppm", res$rows$mz_tol)), "m/z tolerance recorded per row")

# ------------------------------------------------------------
pq_section("feature-level summary")
# ------------------------------------------------------------
sm <- pq_feature_summary(res$rows)
pq_assert(nrow(sm) == 3, "one summary row per feature")
pq_assert(all(sm$n_samples == 3), "n_samples counts the evaluated samples")
pq_assert(all(sm$n_scored == sm$n_samples - sm$n_unsuccessful), "counts add up")
pq_assert(!any(is.na(sm$consistency)), "every feature gets a consistency class")
pq_assert(all(sm$consistency %in% c("consistent", "variable", "poor",
                                    "single_sample", "not_evaluated")),
          "consistency uses a documented value")

# hand-made rows so the median/worst arithmetic can be checked exactly
mk <- function(id, cors, snrs, offs, bstat = "ok") {
  data.frame(feature_id = id, mz = 100, input_rt = 5,
             score_status = "ok", boundary_status = bstat,
             peak_cor = cors, SNR = snrs, apex_offset = offs,
             median_ppm_dev = 0, stringsAsFactors = FALSE)
}
rows2 <- rbind(
  mk("A", c(0.90, 0.80, 0.70), c(10, 20, 30), c(0.01, -0.02, 0.03)),
  mk("B", c(0.50, NA, NA), c(5, NA, NA), c(0.5, NA, NA))
)
sm2 <- pq_feature_summary(rows2)
a <- sm2[sm2$feature_id == "A", ]
pq_assert_equal(a$median_peak_cor, 0.80, "median peak_cor (middle value)")
pq_assert_equal(a$min_peak_cor, 0.70, "worst peak_cor kept")
pq_assert_equal(a$median_SNR, 20, "median SNR")
pq_assert_equal(a$min_SNR, 10, "worst SNR kept")
pq_assert_equal(a$median_apex_offset, 0.01, "signed median apex offset")
pq_assert_equal(a$median_abs_apex_offset, 0.02, "median absolute apex offset")
pq_assert_equal(a$max_abs_apex_offset, 0.03, "largest absolute apex offset")
pq_assert_equal(a$consistency, "consistent", "3/3 scored and boundaries ok")
b <- sm2[sm2$feature_id == "B", ]
pq_assert_equal(b$n_scored, 1, "NA scores are not counted as scored")
pq_assert(!is.na(b$median_peak_cor), "median computed from the scored sample only")

pq_assert(length(pq_feature_summary(res$rows[0, ])$feature_id) == 0,
          "empty input -> empty summary")
pq_assert(nrow(pq_feature_summary(NULL)) == 0, "NULL input -> empty summary")

# consistency classes driven by the thresholds
th <- pq_summary_thresholds()
mkst <- function(sc, ns, bok) {
  data.frame(feature_id = "X", mz = 1, input_rt = 1,
             score_status = c(rep("ok", sc), rep("not_run", ns - sc)),
             boundary_status = c(rep("ok", bok), rep("boundary_unclear", ns - bok)),
             peak_cor = c(rep(0.9, sc), rep(NA, ns - sc)),
             SNR = c(rep(10, sc), rep(NA, ns - sc)),
             apex_offset = rep(0, ns), median_ppm_dev = rep(0, ns),
             stringsAsFactors = FALSE)
}
pq_assert_equal(pq_feature_summary(mkst(10, 10, 10), th)$consistency, "consistent",
                "all samples good -> consistent")
pq_assert_equal(pq_feature_summary(mkst(7, 10, 5), th)$consistency, "variable",
                "70% scored -> variable")
pq_assert_equal(pq_feature_summary(mkst(3, 10, 2), th)$consistency, "poor",
                "30% scored -> poor")
pq_assert_equal(pq_feature_summary(mkst(0, 4, 0), th)$consistency, "not_evaluated",
                "nothing scored -> not_evaluated")
pq_assert_equal(pq_feature_summary(mkst(1, 1, 1), th)$consistency, "single_sample",
                "one sample -> single_sample")
pq_assert(all(pq_feature_summary(mkst(10, 10, 10), th)$pct_scored == 100),
          "pct_scored reported")

# ------------------------------------------------------------
pq_section("summary reaches the exports")
# ------------------------------------------------------------
xp <- file.path(tempdir(), "pq_aligned.xlsx")
pq_export_xlsx(xp, res$rows, res$detail, params, mapping, lookup, summary = sm)
sheets <- readxl::excel_sheets(xp)
pq_assert("FeatureSummary" %in% sheets, "XLSX gains a FeatureSummary sheet")
pq_assert("Results" %in% sheets, "XLSX still has the per-sample Results sheet")
back <- as.data.frame(readxl::read_excel(xp, sheet = "FeatureSummary"))
pq_assert("median_peak_cor" %in% names(back) && "min_peak_cor" %in% names(back),
          "summary sheet keeps median and worst value")
pq_assert("consistency" %in% names(back), "summary sheet keeps the consistency class")

zp <- file.path(tempdir(), "pq_aligned.zip")
wd <- file.path(tempdir(), "pq_aligned_wd")
pq_export_report_zip(zp, wd, res$rows, res$detail, params, mapping, lookup,
                     summary = sm, max_plots = 3)
zn <- utils::unzip(zp, list = TRUE)$Name
pq_assert("feature_summary.csv" %in% zn, "ZIP contains feature_summary.csv")
pq_assert("peak_quality_results.csv" %in% zn, "ZIP still contains the per-sample csv")

# ------------------------------------------------------------
ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

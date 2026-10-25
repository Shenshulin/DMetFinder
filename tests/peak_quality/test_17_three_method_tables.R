# ============================================================
# Three-method result tables: schema, granularity, and the rules that
# must never be broken
# ============================================================
# What this file locks down
#   * GroupResults holds ONE row per feature (the DNN's unit of analysis).
#   * SampleResults holds ONE row per feature x sample (CPC / Kumler's unit).
#   * MethodMetrics is long, carries a unit and a status, and marks the DNN
#     rows scope = peak_group with an empty sample_id.
#   * Absence, failure and "never ran" stay three different things.
#   * Nothing is combined, weighted, ranked or dropped.
#   * The exports keep the three tables, the parameters and the provenance.
# ============================================================

source(file.path(dirname(sub("^--file=", "",
  commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))])),
  "helpers.R"), encoding = "UTF-8")
pq_source_project(pq_proj_root())

# ------------------------------------------------------------
# Fixture: 2 features x 3 samples, deliberately mixed states
# ------------------------------------------------------------
mk_rows <- function() {
  rows <- pq_empty_row()[rep(1, 6), , drop = FALSE]
  rows$feature_id <- c("f1", "f1", "f1", "f2", "f2", "f2")
  rows$sample_id  <- c("S1", "S2", "S3", "S1", "S2", "S3")
  rows$mz <- c(300.1, 300.1, 300.1, 410.2, 410.2, 410.2)
  rows$input_rt <- c(3.20, 3.20, 3.20, 5.60, 5.60, 5.60)
  rows$apex_rt  <- c(3.21, 3.19, NA, NA, 5.61, 5.58)
  rows$start_rt <- c(3.15, 3.14, NA, NA, 5.55, 5.52)
  rows$end_rt   <- c(3.27, 3.25, NA, NA, 5.67, 5.64)
  rows$n_points <- c(11L, 9L, NA, NA, 13L, 12L)
  rows$peak_cor <- c(0.98, 0.95, NA, NA, 0.88, 0.91)
  rows$SNR      <- c(120, 95, NA, NA, 40, 55)
  rows$presence <- c("present", "present", "absent", "unknown", "present", "present")
  rows$boundary_status <- c("ok", "ok", "no_signal", "sample_unmatched", "ok", "ok")
  rows$score_status <- c("ok", "ok", "absent", "not_run", "ok", "ok")
  rows$failure_reason <- c(NA, NA, "no MS1 signal inside the m/z tolerance window",
                           "no raw file could be matched to this sample_id",
                           NA, NA)
  rows$file <- c("a.mzML", "b.mzML", "c.mzML", "", "b.mzML", "c.mzML")
  rows$rt_window <- 0.15
  rows$mz_tol <- c("5 ppm", "5 ppm", "5 ppm", "12 Da", "5 ppm", "5 ppm")
  rows$eic_smoothing <- c("none", "none", "none", "none",
                          "Savitzky-Golay (window 7, order 2)",
                          "Savitzky-Golay (window 7, order 2)")
  rows
}

mk_cpc <- function(n) {
  c <- pq_cpc_empty_row()[rep(1, n), , drop = FALSE]
  c$cpc_status <- c("ok", "ok", "not_detected", "not_detected", "ok", "ok")
  c$cpc_rt <- c(3.20, 3.18, NA, NA, 5.60, 5.57)
  c$cpc_rtmin <- c(3.14, 3.13, NA, NA, 5.54, 5.51)
  c$cpc_rtmax <- c(3.26, 3.24, NA, NA, 5.66, 5.63)
  c$cpc_fwhm <- c(0.05, 0.05, NA, NA, 0.06, 0.058)
  c$cpc_tf <- c(1.05, 1.20, NA, NA, 1.10, 1.02)
  c$cpc_area <- c(1e5, 9e4, NA, NA, 8e4, 7.5e4)
  c$cpc_sn <- c(40, 35, NA, NA, 20, 22)
  c$cpc_front_code <- c("B", "B", NA, NA, "V", "B")
  c$cpc_tail_code <- c("B", "S", NA, NA, "B", "B")
  c$cpc_n_points <- c(12L, 10L, NA_integer_, NA_integer_, 14L, 13L)
  c$cpc_boundary_status <- c("ok", "boundary_unclear", NA, NA, "ambiguous", "ok")
  c$cpc_reason <- c(NA, NA, "CPC did not detect a peak at the supplied apex",
                    "CPC did not detect a peak at the supplied apex", NA, NA)
  c
}

# A prediction table as the predictor would return it: one row per feature.
mk_pred <- function() {
  data.frame(
    feature_id = c("f1", "f2"),
    dnn_prediction = c(1, 0),
    dnn_score = c(0.94, 0.21),
    dnn_threshold = c(0.5, 0.5),
    dnn_input_status = c("ok", "ok"),
    dnn_error = c("", ""),
    stringsAsFactors = FALSE
  )
}

rows <- mk_rows()
cpc <- mk_cpc(nrow(rows))
model_info <- list(available = TRUE, status = "available",
                   sha256 = "0123456789abcdef0123456789abcdef")

# ============================================================
# A. GroupResults
# ============================================================
cat("\n== GroupResults ==\n")
g <- pq_group_results(rows)

pq_assert_equal(nrow(g), 2L, "GroupResults has one row per feature, not per sample")
pq_assert_equal(sort(g$feature_id), c("f1", "f2"), "every feature is represented")
pq_assert_equal(length(unique(g$feature_id)), nrow(g), "no feature appears twice")
pq_assert_true(all(g$n_samples == 3L), "each group knows how many samples it spans")
pq_assert_equal(g$n_present[g$feature_id == "f1"], 2L, "f1 counts two present samples")
pq_assert_equal(g$n_absent[g$feature_id == "f1"], 1L, "f1 counts one absent sample")
pq_assert_equal(g$n_unknown[g$feature_id == "f2"], 1L,
                "an unjudgeable sample is counted as unknown, not as absent")
pq_assert_true(all(g$n_present + g$n_absent + g$n_unknown == g$n_samples),
               "present + absent + unknown accounts for every sample")
pq_assert_true(all(g$rt_reference_source == "aligned_table"),
               "a shared RT is reported as the aligned table's reference")
pq_assert_true(all(!is.na(g$rt_reference)), "the reference RT is carried")

# Scope exists even when the model never ran, so a reader cannot mistake the
# absence of a score for a per-sample measurement.
pq_assert_true(all(g$dnn_scope == "peak_group"),
               "dnn_scope is peak_group even when nothing was scored")
pq_assert_true(all(g$dnn_status == "not_run"),
               "an unscored group says not_run rather than leaving the status blank")

# With predictions attached the group carries them exactly once.
att <- pq_dnn_attach(rows, mk_pred(), model_info)
g2 <- pq_group_results(att)
pq_assert_equal(nrow(g2), 2L, "attaching predictions does not change the group count")
pq_assert_equal(g2$dnn_score[g2$feature_id == "f1"], 0.94,
                "the group carries the model's score for that group")
pq_assert_equal(g2$dnn_prediction[g2$feature_id == "f2"], 0,
                "the group carries the model's class for that group")
pq_assert_true(all(g2$dnn_scope == "peak_group"), "scope survives the join")
pq_assert_equal(g2$dnn_model_version[1], "0123456789ab",
                "the model version travels with the score")

# ============================================================
# B. SampleResults
# ============================================================
cat("\n== SampleResults ==\n")
s <- pq_sample_results(rows, cpc)
pq_assert_equal(nrow(s), nrow(rows), "SampleResults has one row per feature x sample")
pq_assert_equal(nrow(pq_sample_results(rows)), nrow(rows),
                "CPC not running changes nothing about the row count")

need <- c("feature_id", "sample_id", "raw_file", "mz", "rt_reference",
          "sample_rt_apex", "presence_status", "boundary_status",
          "kumler_peak_cor", "kumler_snr", "kumler_status",
          "cpc_rt", "cpc_rtmin", "cpc_rtmax", "cpc_fwhm", "cpc_wb",
          "cpc_a", "cpc_b", "cpc_tf", "cpc_height", "cpc_area", "cpc_sn",
          "cpc_front_code", "cpc_tail_code", "cpc_status",
          "xic_smoothing", "ppm_tolerance", "rt_window", "method_errors")
pq_assert(all(need %in% names(s)), "SampleResults carries every required field")

pq_assert_equal(sum(s$presence_status == "unknown"), 1L,
                "unknown stays its own presence state")
pq_assert_equal(sum(s$presence_status == "absent"), 1L,
                "absent stays its own presence state")
pq_assert_equal(s$kumler_status[s$sample_id == "S3" & s$feature_id == "f1"],
                "absent", "an absent sample is not a failed Kumler score")
pq_assert_equal(s$cpc_status[s$sample_id == "S3" & s$feature_id == "f1"],
                "absent", "an absent sample is not a failed CPC score")
pq_assert_true(is.na(s$kumler_peak_cor[s$sample_id == "S3" & s$feature_id == "f1"]),
               "an absent sample keeps NA, never 0")

pq_assert_equal(s$cpc_status[s$feature_id == "f1" & s$sample_id == "S1"], "ok",
                "a scored CPC row keeps its own status")
pq_assert_equal(s$method_errors[s$feature_id == "f1" & s$sample_id == "S1"], "",
                "a clean row has an empty method_errors field")
pq_assert_contains(s$method_errors[s$feature_id == "f2" & s$sample_id == "S1"],
                   "cpc:", "method_errors names the method that reported the problem")
pq_assert_contains(s$method_errors[s$feature_id == "f2" & s$sample_id == "S1"],
                   "kumler:", "both methods are named when both report a problem")

pq_assert_equal(s$ppm_tolerance[s$feature_id == "f1" & s$sample_id == "S1"], 5,
                "ppm tolerance is parsed when the run used ppm")
pq_assert_true(is.na(s$ppm_tolerance[s$feature_id == "f2" & s$sample_id == "S1"]),
               "a Da tolerance is not silently reported as ppm")
pq_assert_equal(s$mz_tolerance[s$feature_id == "f2" & s$sample_id == "S1"], "12 Da",
                "the original tolerance string is kept next to the number")

pq_assert_contains(s$xic_smoothing[s$feature_id == "f2" & s$sample_id == "S2"],
                   "Savitzky", "the smoothing actually applied is recorded per row")
pq_assert_equal(s$xic_smoothing[s$feature_id == "f1" & s$sample_id == "S1"], "none",
                "an unsmoothed row says none")

# A method that did not run must not look like a method that failed.
s_nocpc <- pq_sample_results(rows)
pq_assert_true(all(s_nocpc$cpc_status[s_nocpc$presence_status == "present"] == "not_run"),
               "CPC that never ran is not_run, not failed")
pq_assert_true(all(is.na(s_nocpc$cpc_fwhm)), "CPC metrics stay NA when CPC did not run")
pq_assert_true(all(is.na(s_nocpc$cpc_area)), "no CPC area is invented")

# ============================================================
# C. Granularity: one DNN call per group, one CPC/Kumler call per sample
# ============================================================
cat("\n== granularity ==\n")
s_att <- pq_sample_results(att, cpc)
sc <- s_att$dnn_score[s_att$feature_id == "f1"]
pq_assert_equal(length(unique(sc[!is.na(sc)])), 1L,
                "the group score is a single value repeated across its samples")
pq_assert_equal(sum(!is.na(sc)), 3L,
                "it is attached to all three rows of the group, not to one")
pq_assert_true(all(s_att$dnn_scope == "peak_group"),
               "every sample row declares that the score is group-level")
n_cpc_ok <- sum(s_att$cpc_status == "ok")
n_kumler_ok <- sum(s_att$kumler_status == "ok")
pq_assert_true(n_kumler_ok > 1L && n_cpc_ok > 1L,
               "the single-sample methods produce per-sample values")
pq_assert_true(n_kumler_ok != 1L,
               "Kumler is not reduced to one value per feature")

# ============================================================
# D. MethodMetrics
# ============================================================
cat("\n== MethodMetrics ==\n")
m <- pq_method_metrics(att, cpc)
pq_assert(all(c("feature_id", "sample_id", "method", "metric", "value",
                "unit", "status", "scope", "model_version") %in% names(m)),
          "MethodMetrics is long and carries unit, status, scope and version")
pq_assert_equal(sort(unique(m$method)), c("cpc", "dnn", "kumler"),
                "all three methods appear in the long table")
pq_assert_true(all(m$scope[m$method == "dnn"] == "peak_group"),
               "DNN metric rows are marked peak_group")
pq_assert_true(all(m$scope[m$method != "dnn"] == "single_sample"),
               "CPC and Kumler metric rows are marked single_sample")
pq_assert_true(all(m$sample_id[m$method == "dnn"] == ""),
               "a group-level metric has no sample_id, rather than borrowing one")
pq_assert_true(all(nzchar(m$unit)), "every metric declares a unit")
pq_assert_contains(m$unit[m$method == "cpc" & m$metric == "area"],
                   "scan count",
                   "CPC area is labelled intensity x scan count, not intensity x time")
pq_assert_contains(m$note[m$method == "cpc" & m$metric == "sn"], "Reported, never filtered",
                   "CPC sn is documented as reported, never filtered")
pq_assert_contains(m$model_version[m$method == "dnn"][1], "0123456789ab",
                   "DNN metric rows carry the model version")
pq_assert_contains(m$model_version[m$method == "kumler"][1], "2f4038ce",
                   "Kumler metric rows carry the vendored commit")

# ============================================================
# E. The rules: no composite, no weighting, no automatic deletion
# ============================================================
cat("\n== no composite ==\n")
banned <- c("total", "combined", "composite", "overall_score", "rank",
            "aggregate", "final_score", "weighted")
for (nm in banned) {
  pq_assert(!any(grepl(nm, names(g2), ignore.case = TRUE)),
            sprintf("GroupResults has no '%s' column", nm))
  pq_assert(!any(grepl(nm, names(s_att), ignore.case = TRUE)),
            sprintf("SampleResults has no '%s' column", nm))
}
pq_assert(!any(grepl("^(final|composite|total)_", names(m), ignore.case = TRUE)),
          "MethodMetrics has no composite row type")
pq_assert_equal(sum(grepl("dnn.*cpc|cpc.*dnn", names(m))), 0L,
                "no metric mixes two methods in one name")

# Every row that came in is still there: nothing is dropped for being bad.
pq_assert_equal(nrow(s_att), nrow(rows), "no peak is deleted by any method")
pq_assert_equal(sum(s_att$presence_status == "absent"), 1L,
                "the absent peak is still in the table")

# A DNN verdict never rewrites a quality class.
q <- pq_classify_rows(rows, cpc)
q_att <- pq_classify_rows(att, cpc)
pq_assert_equal(q$quality_class, q_att$quality_class,
                "attaching DNN predictions does not change quality_class")
pq_assert_true("quality_class" %in% names(q_att),
               "the quality class column still exists after the join")

# ============================================================
# F. Provenance
# ============================================================
cat("\n== provenance ==\n")
pv <- pq_provenance_block(methods_run = c("kumler", "cpc"))
pv_txt <- paste(pv, collapse = "\n")
pq_assert_contains(pv_txt, "doi", "provenance carries paper identifiers")
pq_assert_contains(pv_txt, "KUMLER", "kumler is listed")
pq_assert_contains(pv_txt, "CPC", "cpc is listed")
pq_assert_contains(pv_txt, "DNN", "dnn is listed")
pq_assert_contains(pv_txt, "executed=yes",
                   "provenance states which methods actually executed")
pq_assert_contains(pv_txt, "executed=no",
                   "a method that did not run is stated as such")
pq_assert_contains(pv_txt, "scope=peak_group",
                   "the DNN's scope is in the provenance")
pq_assert_contains(pv_txt, "license",
                   "licences are recorded")
pq_assert_contains(pv_txt, "squallms",
                   "the executed scoring code is named")

# ============================================================
# G. Exports keep the three tables, the parameters and the provenance
# ============================================================
cat("\n== export ==\n")
map <- list(feature_id = "feature_id", mz = "mz", rt = "input_rt",
            sample_id = "sample_id")
lookup <- data.frame(sample_id = c("S1", "S2", "S3"),
                     file = c("a.mzML", "b.mzML", "c.mzML"),
                     match = c("exact", "exact", "exact"),
                     stringsAsFactors = FALSE)
pp <- list(rt_window = 0.15, mz_tol_unit = "ppm", mz_tol_ppm = 5,
           mz_tol_da = 0.01, xic_aggregate = "max",
           eic_smooth_method = "none", eic_smooth_window = 7,
           eic_smooth_order = 2)

xl <- file.path(tempdir(), "pq_three.xlsx")
pq_export_xlsx(xl, att, list(), pp, map, lookup, cpc = cpc,
               metrics = m, methods_run = c("kumler", "cpc", "dnn"))
sh <- openxlsx::getSheetNames(xl)
pq_assert(all(c("Results", "GroupResults", "SampleResults", "MethodMetrics",
                "Parameters", "Provenance") %in% sh),
          "XLSX carries the three tables, the parameters and the provenance")

gr_sheet <- openxlsx::read.xlsx(xl, sheet = "GroupResults")
pq_assert_equal(nrow(gr_sheet), 2L, "the GroupResults sheet is one row per feature")
pq_assert_true("dnn_scope" %in% names(gr_sheet), "the sheet keeps the DNN scope")

sr_sheet <- openxlsx::read.xlsx(xl, sheet = "SampleResults")
pq_assert_equal(nrow(sr_sheet), 6L, "the SampleResults sheet is one row per feature x sample")
pq_assert_true(all(c("kumler_status", "cpc_status", "method_errors") %in%
                     names(sr_sheet)),
               "the sheet keeps both method statuses and the error field")

mm_sheet <- openxlsx::read.xlsx(xl, sheet = "MethodMetrics")
pq_assert_true(all(c("unit", "status", "scope") %in% names(mm_sheet)),
               "the long sheet keeps unit, status and scope")

prov_sheet <- openxlsx::read.xlsx(xl, sheet = "Provenance")
prov_txt <- paste(prov_sheet[[1]], collapse = "\n")
pq_assert_contains(prov_txt, "executed=", "the XLSX provenance states what ran")
pq_assert_contains(prov_txt, "scope=peak_group", "the XLSX provenance states the DNN scope")

zp <- file.path(tempdir(), "pq_three.zip")
pq_export_report_zip(zp, file.path(tempdir(), "pq_three_work"), att, list(),
                     pp, map, lookup, max_plots = 0, cpc = cpc,
                     metrics = m, methods_run = c("kumler", "cpc", "dnn"))
zl <- utils::unzip(zp, list = TRUE)
pq_assert(any(grepl("group_results.csv", zl$Name)), "ZIP contains group_results.csv")
pq_assert(any(grepl("sample_results.csv", zl$Name)), "ZIP contains sample_results.csv")
pq_assert(any(grepl("method_metrics_long.csv", zl$Name)),
          "ZIP contains the long metric table")
pq_assert(any(grepl("provenance.txt", zl$Name)), "ZIP contains the provenance")

# ============================================================
# H. The paper benchmark still reproduces
# ============================================================
# Not a re-run (that takes minutes and belongs to pq_dnn_train.py); this only
# asserts that the frozen artefact still claims the published numbers, so a
# swapped or retrained model cannot slip through unnoticed.
cat("\n== paper benchmark ==\n")
mp <- file.path(pq_proj_root(), "DNN_reference", "models", "edml15_train_log.json")
if (!file.exists(mp)) {
  pq_skip("no training log on disk; benchmark check skipped")
} else {
  log <- jsonlite::fromJSON(mp, simplifyVector = FALSE)
  unl <- function(x) if (is.null(x)) NA_real_ else as.numeric(unlist(x))[1]
  te <- unl(log$evaluation$test$auc)
  tr <- unl(log$evaluation$train$auc)
  # The paper reports 0.992 (training) and 0.988 (test). We allow a band wide
  # enough for a seed change but narrow enough to catch a broken model.
  pq_assert_true(is.finite(te) && abs(te - 0.988) < 0.01,
                 sprintf("test AUC is still near the paper's 0.988 (got %.4f)", te))
  pq_assert_true(is.finite(tr) && abs(tr - 0.992) < 0.01,
                 sprintf("training AUC is still near the paper's 0.992 (got %.4f)", tr))
}

# ---- results() must always keep the list shape ---------------------------
# The run observer stores the list returned by pq_process_features() (rows +
# detail) in results(), and ~30 places read det$rows. One branch stored the
# bare DNN-attached data.frame instead; det$rows then became NULL and the
# Results tab died with "Error in if: missing value where TRUE/FALSE needed"
# and "Error in [: incorrect number of dimensions" - only when the DNN had
# actually scored. This check pins the shape at the source.
srv <- readLines(file.path(pq_proj_root(), "R/peak_quality/peak_quality_server.R"),
                 encoding = "UTF-8", warn = FALSE)
srv <- srv[!grepl("^\\s*#", srv)]          # ignore comments
bad_store <- grep("results\\(\\s*(dr\\$rows|rows|df|tbl|det\\$rows)\\s*\\)", srv,
                  value = TRUE)
pq_assert_equal(length(bad_store), 0L,
                paste("results() is never assigned a bare table:",
                      paste(bad_store, collapse = " / ")))
pq_assert_true(any(grepl("results\\(det\\)", srv)),
               "results() is assigned the whole det list (rows + detail)")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

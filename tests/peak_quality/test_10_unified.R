# ============================================================
# Stage-2 tests: unified result structure
# ============================================================
# The task fixes the unified fields and forbids combining method scores.
# These checks assert the STRUCTURE, not any quality of the numbers.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))
root <- pq_source_project()
# --vanilla does not read .Renviron; pick the CPC library pointer up by hand
if (!nzchar(Sys.getenv("DMETFINDER_CPC_LIB"))) {
  renv <- file.path(root, ".Renviron")
  if (file.exists(renv)) readRenviron(renv)
}
if (!nzchar(Sys.getenv("DMETFINDER_CPC_LIB"))) {
  ref <- file.path(root, ".workbuddy/reference/rlib")
  if (dir.exists(ref)) Sys.setenv(DMETFINDER_CPC_LIB = ref)
}

run <- pq_make_synthetic_run(n_samples = 3L, features = c("F1", "F2"))
rows <- run$rows
params <- run$params

# ------------------------------------------------------------
pq_section("unified table without a second method")
# ------------------------------------------------------------
u1 <- pq_unified_from_run(rows, NULL, params)
pq_assert_equal(nrow(u1), nrow(rows), "one unified row per result row when CPC is not run")
pq_assert_equal(names(u1), PQ_UNIFIED_COLUMNS,
                "the unified table has exactly the agreed columns, in order")
core <- c("feature_id", "sample_id", "mz", "input_rt", "start_rt", "apex_rt",
          "end_rt", "n_points", "method", "raw_score", "quality_probability",
          "boundary_status", "score_status", "failure_reason")
pq_assert(all(core %in% names(u1)), "all 14 required fields are present")
pq_assert(all(u1$method %in% "kumler"), "only kumler rows exist without CPC")

# ------------------------------------------------------------
pq_section("unified table with both methods")
# ------------------------------------------------------------
want_cpc <- isTRUE(pq_cpc_available()$ok)
if (!want_cpc) {
  pq_skip("cpc not installed: the two-method section is skipped")
} else {
  cpc <- pq_run_cpc(run$detail, rows, params)$table
  u2 <- pq_unified_from_run(rows, cpc, params, cpc_settings = pq_cpc_settings(61, list()))

  pq_assert_equal(nrow(u2), 2L * nrow(rows),
                  "two unified rows per peak (one per method)")
  pq_assert_equal(sort(unique(u2$method)), c("cpc", "kumler"),
                  "method column records the method that produced the row")
  pq_assert_equal(names(u2), PQ_UNIFIED_COLUMNS,
                  "the column set does not change when a second method is added")

  k <- u2[u2$method == "kumler", , drop = FALSE]
  c_ <- u2[u2$method == "cpc", , drop = FALSE]
  pq_assert(all(is.na(k$raw_score_name) | k$raw_score_name %in% "peak_cor"),
            "kumler raw_score is named peak_cor (empty only where the peak is absent)")
  pq_assert_equal(k$raw_score, rows$peak_cor,
                  "kumler raw_score carries the native peak_cor value")
  pq_assert(all(is.na(c_$raw_score)),
            "cpc raw_score is empty: the package has no single scalar score")
  pq_assert(all(is.na(c_$raw_score_name)),
            "cpc raw_score_name is empty as well")
  pq_assert(all(is.na(u2$quality_probability)),
            "quality_probability is never filled (no method here emits one)")

  # the two methods really start from the same candidate peak
  pq_assert_equal(k$input_rt, c_$input_rt, "both methods see the same input RT")
  pq_assert_equal(k$mz, c_$mz, "both methods see the same m/z")
  pq_assert(sum(!is.na(c_$start_rt)) > 0,
            "CPC provides its own start_rt (not a copy of the Kumler boundary)")
  d_apex <- abs(c_$apex_rt - k$apex_rt)
  pq_assert(any(is.finite(d_apex) & d_apex > 0),
            "the two methods can place the apex differently (values are not copied)")

  # absent samples are reported, not hidden
  ab <- rows$presence %in% "absent"
  if (any(ab)) {
    pq_assert(all(u2$score_status[rep(ab, each = 2)] %in% "absent"),
              "absent samples appear in the unified table as 'absent'")
  }

  # no composite column may exist anywhere
  bad <- grep("total|combined|composite|overall|final_score|mean_score",
              names(u2), ignore.case = TRUE, value = TRUE)
  pq_assert_equal(length(bad), 0L, "the unified table has no composite score column")

  # ----------------------------------------------------------
  pq_section("native metrics long table")
  # ----------------------------------------------------------
  m <- pq_metrics_long(rows, cpc)
  pq_assert(all(c("feature_id", "sample_id", "method", "metric", "label",
                  "unit", "value", "note") %in% names(m)),
            "the metric table stores the metric NAME next to its value")
  pq_assert(all(c("kumler", "cpc") %in% m$method), "both methods contribute metric rows")
  kum_names <- unique(m$metric[m$method == "kumler"])
  pq_assert_equal(sort(kum_names), sort(c("peak_cor", "SNR")),
                  "kumler contributes exactly its two native metrics")
  cpc_names <- unique(m$metric[m$method == "cpc"])
  pq_assert(all(c("area", "fwhm", "tf", "sn", "height") %in% cpc_names),
            "cpc contributes area / fwhm / tf / sn / height")
  area_row <- m[m$method == "cpc" & m$metric == "area", , drop = FALSE]
  pq_assert(all(area_row$unit == "intensity x scan count"),
            "every cpc area row carries the index-unit label")
  pq_assert_equal(nrow(m),
                  nrow(rows) * (2L + length(cpc_names)),
                  "the metric table has one row per sample, method and metric")

  # ----------------------------------------------------------
  pq_section("wide comparison table")
  # ----------------------------------------------------------
  w <- pq_wide_compare(rows, cpc)
  pq_assert_equal(nrow(w), nrow(rows), "the wide table has one row per peak")
  pq_assert(all(c("kumler_peak_cor", "cpc_fwhm") %in% names(w)),
            "the wide table keeps method-prefixed metric columns")
  pq_assert(all(c("d_start_rt", "d_apex_rt", "d_end_rt") %in% names(w)),
            "boundary differences between the methods are reported")
  pq_assert(all(w$method_agreement %in% c("both_scored", "kumler_only", "cpc_only",
                                          "neither", "absent", "not_run")),
            "the agreement column uses the documented categories")
  pq_assert(sum(w$method_agreement == "both_scored") > 0,
            "at least one peak is scored by both methods")

  sm <- pq_agreement_summary(w)
  pq_assert_equal(sum(sm$n, na.rm = TRUE), nrow(w),
                  "the agreement counts add up to the number of peaks")
  pq_assert(any(sm$category == "median |d apex RT| (min)"),
            "the summary reports a median apex difference")
  pq_assert(!any(grepl("score", sm$category, ignore.case = TRUE) &
                   grepl("total|combined", sm$category, ignore.case = TRUE)),
            "the summary contains no combined score row")

  dv <- pq_divergent_cases(w, c("kumler_only", "cpc_only", "neither"))
  pq_assert(!is.null(dv), "divergent cases can be extracted for review")
  pq_assert(all(dv$method_agreement %in% c("kumler_only", "cpc_only", "neither")),
            "divergent cases contain only rows where the methods differ")

  mismatch <- tryCatch({
    pq_unified_from_run(rows, cpc = cpc[1:2, , drop = FALSE], params = params)
    "no error"
  }, error = function(e) conditionMessage(e))
  pq_assert(grepl("aligned", mismatch),
            "a misaligned CPC table is rejected instead of silently recycled")
}

# ------------------------------------------------------------
pq_section("column dictionary")
# ------------------------------------------------------------
dict <- pq_unified_dictionary()
pq_assert_equal(nrow(dict), length(PQ_UNIFIED_COLUMNS),
                "every unified column is documented")
pq_assert(all(c("raw_score", "quality_probability") %in% dict$column),
          "the two fields with special semantics are documented")
pq_assert(grepl("composite", dict$meaning[dict$column == "raw_score"]),
          "raw_score is documented as never being a composite score")
pq_assert(grepl("only when a model",
                dict$meaning[dict$column == "quality_probability"]),
          "quality_probability is documented as model-only")

# ------------------------------------------------------------
pq_section("empty / edge inputs")
# ------------------------------------------------------------
e <- pq_unified_empty()
pq_assert_equal(nrow(e), 0L, "the empty unified table has no rows")
pq_assert_equal(names(e), PQ_UNIFIED_COLUMNS, "the empty table keeps the column set")
pq_assert_equal(nrow(pq_unified_from_run(rows[0, , drop = FALSE], NULL, params)), 0L,
                "an empty result set yields an empty unified table")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

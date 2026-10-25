# ============================================================
# test_13 - provisional four-class quality verdict
# ============================================================
# What is pinned here:
#   * the rule-order contract (exactly one rule id per row),
#   * that `absent` is NEVER turned into a noise verdict,
#   * that an ambiguous / unscorable row stays `unknown`,
#   * that CPC cannot change a verdict (no cross-method combination),
#   * that every row carries a reason and the evidence string,
#   * that the classifier never changes row count or row order,
#   * that summaries report their denominator and that the CI stays in [0,100],
#   * that the verdict is stamped unverified.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))
pq_source_project()

pq_section("rule order and class mapping")

mk <- function(presence = "present", score = "ok", boundary = "ok",
               peak_cor = NA_real_, presence_snr = NA_real_, n_points = 20L,
               failure = NA_character_, software = NA_character_) {
  data.frame(
    feature_id = "F1", sample_id = "S1", mz = 300, input_rt = 5,
    rt_unit = "min", start_rt = 4.9, apex_rt = 5, end_rt = 5.1,
    n_points = n_points, n_xic_points = 61L,
    peak_cor = peak_cor, SNR = 50,
    presence = presence, boundary_status = boundary, score_status = score,
    failure_reason = failure, file = "S1.raw", rt_window = 0.3,
    mz_tol = "10 ppm", xic_aggregate = "max",
    n_scans_in_window = 61L, n_scans_missing = 0L, n_mz_matched = 61L,
    n_scans_multi = 0L, median_ppm_dev = 0,
    peak_height = 2e5, xic_noise = 1e4, presence_snr = presence_snr,
    n_candidates = 1L, edge_touched = NA_character_, apex_offset = 0,
    eic_smoothing = "none", eic_smoothing_applied = FALSE,
    software = software, original_id = NA_character_,
    rt_source = "per_sample", stringsAsFactors = FALSE)
}

# R7 high quality
r <- pq_classify_rows(mk(peak_cor = 0.92, presence_snr = 20))
pq_assert_equal(r$quality_class[1], "high_quality", "good shape + good SNR -> high_quality")
pq_assert_equal(r$quality_rule[1], "R7", "high_quality comes from R7")

# R6 poor quality: signal present, shape wrong
r <- pq_classify_rows(mk(peak_cor = 0.31, presence_snr = 20))
pq_assert_equal(r$quality_class[1], "poor_quality", "low peak_cor with real signal -> poor_quality")
pq_assert_equal(r$quality_rule[1], "R6", "poor_quality comes from R6")

# R5 likely noise
r <- pq_classify_rows(mk(peak_cor = 0.95, presence_snr = 1.4))
pq_assert_equal(r$quality_class[1], "likely_noise", "signal barely above noise -> likely_noise")
pq_assert_equal(r$quality_rule[1], "R5", "likely_noise comes from R5")
pq_assert_contains(r$quality_reason[1], "noise", "the noise verdict names the noise ratio")

# R8 middle band stays unknown instead of being forced
r <- pq_classify_rows(mk(peak_cor = 0.65, presence_snr = 20))
pq_assert_equal(r$quality_class[1], "unknown", "intermediate peak_cor -> unknown (R8)")
pq_assert_equal(r$quality_rule[1], "R8", "middle band is rule R8")
r <- pq_classify_rows(mk(peak_cor = 0.92, presence_snr = 4))
pq_assert_equal(r$quality_class[1], "unknown", "good shape but weak SNR -> unknown (R8)")

pq_section("absent is never noise")

r <- pq_classify_rows(mk(presence = "absent", score = "absent",
                         boundary = NA_character_, failure = "no MS1 signal"))
pq_assert_equal(r$quality_class[1], "unknown", "absent row is unknown, not likely_noise")
pq_assert_equal(r$quality_rule[1], "R2", "absent row fires R2")
pq_assert(!identical(r$quality_class[1], "likely_noise"),
          "absent is explicitly not classified as likely_noise")
pq_assert_contains(r$quality_reason[1], "absence is not evidence",
                   "the reason states that absence is not evidence of noise")

pq_section("no verdict without interpretable evidence")

r <- pq_classify_rows(mk(presence = "unknown", score = "not_run",
                         boundary = "file_error", failure = "raw file read error"))
pq_assert_equal(r$quality_rule[1], "R1", "presence unknown fires R1")

r <- pq_classify_rows(mk(score = "skipped", boundary = "too_few_points",
                         n_points = 3L, failure = "fewer than 5 scans"))
pq_assert_equal(r$quality_rule[1], "R3", "unscored row fires R3 before the boundary rule")
pq_assert_equal(r$quality_class[1], "unknown", "unscored row is unknown")

r <- pq_classify_rows(mk(score = "ok", boundary = "ambiguous",
                         peak_cor = 0.95, presence_snr = 30))
pq_assert_equal(r$quality_rule[1], "R4", "ambiguous boundary fires R4")
pq_assert_equal(r$quality_class[1], "unknown",
                "ambiguous boundary blocks a positive verdict even with a high peak_cor")
pq_assert_contains(r$quality_reason[1], "boundary", "the reason names the boundary problem")

pq_section("CPC is corroboration only")

rows <- rbind(mk(peak_cor = 0.92, presence_snr = 20),
              mk(peak_cor = 0.31, presence_snr = 20))
rows$feature_id <- c("F1", "F2")
base <- pq_classify_rows(rows)

cpc <- data.frame(cpc_status = c("ok", "ok"), cpc_tf = c(1.02, 4.8),
                  cpc_sn = c(40, 6), stringsAsFactors = FALSE)
with_cpc <- pq_classify_rows(rows, cpc)
pq_assert_equal(with_cpc$quality_class, base$quality_class,
                "adding CPC does not change any verdict")
pq_assert_contains(with_cpc$quality_corroboration[2], "tailing",
                   "CPC tailing is reported as corroboration")

pq_section("output contract")

r <- pq_classify_rows(rbind(mk(), mk(peak_cor = 0.9, presence_snr = 20)))
pq_assert_equal(nrow(r), 2L, "classifier does not add or drop rows")
pq_assert(all(c("quality_class", "quality_rule", "quality_reason",
                "quality_evidence", "quality_corroboration",
                "quality_methods_missing", "quality_class_version",
                "quality_class_verified") %in% names(r)),
          "all verdict columns are present")
pq_assert(all(!is.na(r$quality_reason)), "every row has a reason")
pq_assert(all(!is.na(r$quality_evidence)), "every row has an evidence string")
pq_assert(all(r$quality_class_verified == FALSE),
          "verdicts are stamped unverified")
pq_assert_equal(unique(r$quality_class_version), "provisional-1",
                "the rule-set version is recorded")
pq_assert(all(grepl("dnn:", r$quality_methods_missing)),
          "the missing DNN model is reported on every row")
pq_assert(all(r$quality_class %in% PQ_QUALITY_CLASSES),
          "only the four documented classes are emitted")

# one rule id per row, always in the documented set
r3 <- pq_classify_rows(rbind(
  mk(presence = "unknown", score = "not_run"),
  mk(presence = "absent", score = "absent"),
  mk(score = "skipped"),
  mk(boundary = "ambiguous", peak_cor = 0.9, presence_snr = 20),
  mk(peak_cor = 0.9, presence_snr = 1),
  mk(peak_cor = 0.2, presence_snr = 20),
  mk(peak_cor = 0.95, presence_snr = 20),
  mk(peak_cor = 0.6, presence_snr = 20)))
pq_assert(all(r3$quality_rule %in% c("R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8")),
          "every rule id is in the documented set")
pq_assert_equal(sort(unique(r3$quality_rule)), sort(c("R1", "R2", "R3", "R4",
                                                      "R5", "R6", "R7", "R8")),
                "all eight rules are reachable")

pq_section("summaries report their denominator")

rows <- r3
rows$software <- c("XCMS", "XCMS", "MS-DIAL", "MS-DIAL", "MS-DIAL",
                   "MZmine", "MZmine", NA)
s <- pq_class_summary(rows)
pq_assert_equal(nrow(s), 4L, "summary lists the four classes")
pq_assert_equal(sum(s$n), nrow(rows), "class counts add up to the row count")
pq_assert(all(s$denominator == nrow(rows)), "summary states the denominator")
pq_assert_equal(sum(s$pct), 100, "percentages add up to 100", tol = 0.11)

by <- pq_class_by_software(rows)
pq_assert("(not stated)" %in% by$software,
          "a missing software value is kept as (not stated), not dropped")
pq_assert(all(by$ci_low >= 0 & by$ci_high <= 100),
          "the confidence interval stays inside 0..100")
pq_assert(all(by$ci_low <= by$pct & by$pct <= by$ci_high),
          "the point estimate lies inside its own interval")
pq_assert(all(by$denominator > 0), "every software row states its denominator")

note <- pq_software_compare_note(rows)
pq_assert(any(grepl("NOT independent biological replicates", note)),
          "the cross-software note warns about pseudo-replication")
pq_assert(any(grepl("does not prove a better tool", note)),
          "the note refuses to read a proportion as a ranking")

# raw metric distributions per software: reported, never ranked
md <- pq_metrics_by_software(rows)
pq_assert(all(c("software", "metric", "n", "median", "q05", "q95") %in% names(md)),
          "the metric distribution table has its documented columns")
pq_assert("(not stated)" %in% md$software,
          "an unstated software keeps its own distribution row")
pq_assert(all(md$n >= 0), "every distribution row states its own n")
fin <- md[is.finite(md$q05) & is.finite(md$q95) & is.finite(md$median), ]
if (nrow(fin) > 0) {
  pq_assert(all(fin$q05 <= fin$median + 1e-9 & fin$median <= fin$q95 + 1e-9),
            "each distribution is ordered 5% <= median <= 95%")
} else {
  pq_skip("no finite metric distribution to order-check")
}

pq_section("the classifier runs on a real pipeline result")

syn <- pq_make_synthetic_run(n_samples = 3L, features = c("F1", "F2"), seed = 7L)
r <- pq_classify_rows(syn$rows, NULL)
pq_assert_equal(nrow(r), nrow(syn$rows), "synthetic run keeps its row count")
pq_assert(all(!is.na(r$quality_class)), "synthetic run gets a verdict on every row")
abs_row <- r[r$presence %in% "absent", , drop = FALSE]
if (nrow(abs_row) > 0) {
  pq_assert(all(abs_row$quality_class == "unknown"),
            "the synthetic absent sample is unknown, not noise")
} else {
  pq_skip("synthetic run produced no absent row")
}
ok_row <- r[r$score_status %in% "ok", , drop = FALSE]
if (nrow(ok_row) > 0) {
  pq_assert(all(ok_row$quality_class != "unknown" |
                  ok_row$quality_rule == "R8"),
            "scored rows are classified or explicitly left in the middle band")
} else {
  pq_skip("synthetic run produced no scored row")
}

pq_section("stage G input: RT provenance survives the expansion")

feat <- data.frame(
  feature_id = c("F1", "F2"), mz = c(300, 400),
  rt_input = c(5, 6), rt_min = c(5, 6), rt_unit = "min",
  sample_id = NA_character_, software = "XCMS",
  original_id = c("x1", "x2"), stringsAsFactors = FALSE)
files <- c("S1.raw", "S2.raw")

e0 <- pq_expand_features(feat, files)
pq_assert_equal(nrow(e0), 4L, "an aligned feature is expanded once per file")
pq_assert(all(e0$rt_source == "cohort_average"),
          "without per-sample RT every row says cohort_average")
pq_assert(all(e0$software == "XCMS"), "the software label survives expansion")
pq_assert(all(e0$original_id %in% c("x1", "x2")),
          "the original feature id survives expansion")

ov <- data.frame(feature_id = c("F1", "F1"), sample_id = c("S1", "S2"),
                 rt = c(5.05, 5.12), stringsAsFactors = FALSE)
e1 <- pq_expand_features(feat, files, per_sample_rt = ov)
pq_assert_equal(e1$rt_min[e1$feature_id == "F1" & e1$sample_id == "S1"], 5.05,
                "a per-sample RT overrides the cohort average")
pq_assert_equal(e1$rt_source[e1$feature_id == "F1" & e1$sample_id == "S2"],
                "per_sample_override", "an override is marked as such")
pq_assert_equal(e1$rt_source[e1$feature_id == "F2"],
                rep("cohort_average", 2),
                "a feature without an override keeps the cohort average")

pq_section("dictionary and rules are self-documenting")

d <- pq_quality_dictionary()
pq_assert(all(c("quality_class", "quality_rule", "quality_class_verified") %in% d$column),
          "the dictionary documents the verdict columns")
pq_assert(any(grepl("PROVISIONAL", d$meaning)),
          "the dictionary marks the verdict as provisional")

rules <- pq_quality_rules()
pq_assert(isFALSE(rules$verified), "the rule set is unverified by default")
pq_assert(all(c("peak_cor_good", "peak_cor_poor", "snr_noise", "snr_good",
                "min_points_for_shape") %in% names(rules)),
          "every threshold is exposed as a named rule")
pq_assert(all(c("peak_cor_good", "peak_cor_poor", "snr_noise", "snr_good") %in%
                names(rules$source)),
          "every invented threshold states its provenance")
pq_assert_contains(rules$source$peak_cor_good, "NOT validated",
                   "the shape threshold admits it is not validated")

# ---- the return type contract -------------------------------------------
# The classifier must hand back a TABLE or NULL - never a bare list. A list
# answer made the UI die with "missing value where TRUE/FALSE needed" (nrow()
# of it is not 0) and "incorrect number of dimensions" (x[i, j] on it), which
# is exactly what happened when a DNN run replaced results() with a data.frame
# and det$rows came back NULL.
pq_assert(is.null(pq_classify_rows(NULL, NULL)),
          "classifying NULL returns NULL, not a list of empty columns")

empty <- pq_classify_rows(syn$rows[0, , drop = FALSE], NULL)
pq_assert(is.data.frame(empty), "classifying a 0-row table returns a data.frame")
pq_assert_equal(nrow(empty), 0L, "the 0-row answer keeps zero rows")
pq_assert(all(c("quality_class", "quality_rule") %in% names(empty)),
          "the 0-row answer still carries the verdict columns")

full <- pq_classify_rows(syn$rows, NULL)
pq_assert(is.data.frame(full), "the normal answer is a data.frame")
pq_assert_equal(nrow(full), nrow(syn$rows),
                "the normal answer keeps every input row (never drops peaks)")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

# ============================================================
# test_12 - XIC smoothing applied before the analysis
# ============================================================
# What this file pins down:
#   1. the Savitzky-Golay weights are the real ones (they reproduce a
#      quadratic exactly and match the published SG(5,2) kernel);
#   2. edge points are fitted, not invented, and never NA;
#   3. the guards refuse instead of padding, extrapolating or crashing;
#   4. the default ("none") leaves every existing number untouched;
#   5. peak presence is INVARIANT to the switch (noise and height are
#      measured on the raw trace);
#   6. a smoothed run is recorded as smoothed in the rows, the parameter
#      string and the unified table, so it can never be read as the author's
#      raw-data output.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))
pq_source_project()

pq_section("Savitzky-Golay weights are the real ones")

C5 <- pq_sg_coef_matrix(5, 2)
pq_assert_equal(C5[3, ], c(-3, 12, 17, 12, -3) / 35,
                "SG(5,2) centred kernel matches the published coefficients")

for (w in c(5L, 7L, 9L, 11L, 21L)) {
  Cw <- pq_sg_coef_matrix(w, 2)
  pq_assert(max(abs(rowSums(Cw) - 1)) < 1e-10,
            sprintf("window %d: every offset row sums to 1 (constant preserved)", w))
}

y_quad <- (seq_len(31))^2
pq_assert_equal(pq_savgol(y_quad, 7, 2), y_quad,
                "a quadratic is reproduced exactly, including the edges")

y_flat <- rep(1234.5, 12)
pq_assert_equal(pq_savgol(y_flat, 7, 2), y_flat,
                "a flat trace is returned unchanged")

# A ramp is also reproduced exactly by a quadratic fit, which proves the edge
# rows of the coefficient matrix are consistent with the interior.
y_ramp <- seq(0, 100, length.out = 25)
pq_assert_equal(pq_savgol(y_ramp, 7, 2), y_ramp,
                "a linear ramp is reproduced at the edges as well")

pq_section("edge handling")

set.seed(99)
y_noise <- 1000 + stats::rnorm(31, 0, 40)
sm <- pq_savgol(y_noise, 7, 2)
pq_assert(!anyNA(sm), "no NA at the edges (nothing is padded with NA)")
pq_assert_equal(length(sm), length(y_noise), "the output keeps the input length")
pq_assert(all(sm >= 0), "smoothed intensities are non-negative here")
pq_assert(abs(sm[1] - y_noise[1]) > 0,
          "the first point is fitted, not copied from the raw value")
pq_assert(abs(sm[16] - y_noise[16]) > 0,
          "an interior point is smoothed, not copied")
pq_assert(max(abs(sm - y_noise)) < max(abs(y_noise - mean(y_noise))),
          "the smoothed trace stays inside the spread of the raw trace")

pq_section("moving average: interior identical to the centred mean")

mv <- pq_movavg_centered(y_noise, 5)
old <- pq_movavg(y_noise, 5)
pq_assert_equal(mv[5:27], old[5:27],
                "interior values equal pq_movavg() (same centred window)")
pq_assert(abs(mv[1] - y_noise[1]) > 0,
          "pq_movavg_centered() smooths the edge instead of leaving it raw")

pq_section("guards: refuse, never invent")

r <- pq_smooth_trace(rep(100, 4), "savgol", 7, 2)
pq_assert(!r$applied, "4 points: not smoothed")
pq_assert_contains(r$reason, "nothing to smooth", "4 points: reason recorded")

r <- pq_smooth_trace(rep(100, 6), "savgol", 9, 2)
pq_assert(!r$applied, "6 points with a 9-point window: not smoothed")
pq_assert_contains(r$reason, "fewer than the 9-point window",
                   "a short trace is reported, not zero-padded")

r <- pq_smooth_trace(c(rep(100, 10), NA_real_, rep(100, 10)), "savgol", 7, 2)
pq_assert(!r$applied, "a trace with a non-finite value is left unsmoothed")
pq_assert_contains(r$reason, "non-finite", "the non-finite reason is explicit")

r <- pq_smooth_trace(rep(100, 20), "savgol", 5, 4)
pq_assert(r$order <= 3L, "a polynomial order above 3 is capped")
pq_assert(r$applied, "the capped order still smooths")

r <- pq_smooth_trace(rep(100, 20), "none", 7, 2)
pq_assert(!r$applied && identical(r$label, "none"),
          "'none' is a no-op and is labelled as such")

r <- pq_smooth_trace(rep(100, 20), "savgol", 8, 2)
pq_assert_equal(r$window, 9L, "an even window is promoted to the next odd number")

r <- pq_smooth_trace(c(rep(0, 20), rep(1000, 20)), "savgol", 7, 2)
pq_assert(r$n_clamped >= 1L, "a polynomial undershoot below zero is counted")
pq_assert(all(r$y >= 0), "the clamped trace contains no negative intensity")

pq_section("labels and tags are stable (they end up in the exports)")

pq_assert_equal(pq_eic_smooth_label("none"), "none", "none label")
pq_assert_equal(pq_eic_smooth_label("savgol", 7, 2),
                "Savitzky-Golay (window 7, order 2)", "savgol label")
pq_assert_equal(pq_eic_smooth_label("movavg", 5, 2),
                "Moving average (window 5)", "movavg label")
pq_assert_equal(pq_eic_smooth_tag("savgol", 7, 2), "savgol_w7_o2", "savgol tag")
pq_assert_equal(pq_eic_smooth_tag("movavg", 5, 2), "movavg_w5", "movavg tag")
pq_assert_equal(pq_eic_smooth_tag("none"), "none", "none tag")

pq_section("physics: what each method does to a real peak")

rt <- seq(5, 6.2, length.out = 200)          # ~166 scans/min
sigma <- 0.10
g <- 5000 * exp(-((rt - 5.6)^2) / (2 * sigma^2))
set.seed(7)
noisy <- g + stats::rnorm(length(g), 0, 120)
pn <- function(v) stats::mad(diff(v)) / sqrt(2)

sg7 <- pq_savgol(noisy, 7, 2)
mv7 <- pq_movavg_centered(noisy, 7)

pq_assert(max(sg7) / max(noisy) > 0.97,
          "savgol keeps >97% of the apex (quadratic fit, no flattening)")
pq_assert(max(sg7) / max(noisy) > max(mv7) / max(noisy),
          "savgol keeps the apex better than a moving average of the same width")
pq_assert(pn(sg7) / pn(noisy) < 0.60,
          "savgol removes more than 40% of the point-to-point noise")
pq_assert(pn(mv7) < pn(sg7),
          "a moving average suppresses more noise but flattens the peak more")

pq_section("integration: the default changes nothing")

run_raw <- pq_make_synthetic_run()
pq_assert(all(run_raw$rows$eic_smoothing == "none"),
          "default run labels every row 'none'")
pq_assert(all(!run_raw$rows$eic_smoothing_applied),
          "default run applies nothing")
pq_assert(all(vapply(run_raw$detail, function(d)
  identical(d$xic, d$xic_analysis), logical(1))),
  "default run: the analysis trace IS the raw trace (same object)")
pq_assert(all(vapply(run_raw$detail, function(d)
  !is.null(d$xic_analysis) && nrow(d$xic_analysis) == nrow(d$xic), logical(1))),
  "default run: both traces are stored for the plots")

run_sg <- pq_make_synthetic_run(smooth_method = "savgol", smooth_window = 7L)

pq_assert(all(run_sg$rows$eic_smoothing == "Savitzky-Golay (window 7, order 2)"),
          "smoothed run records the setting on every row")
pq_assert(all(run_sg$rows$eic_smoothing_applied),
          "smoothed run records that it was applied")
pq_assert(all(vapply(run_sg$detail, function(d)
  !identical(d$xic$intensity, d$xic_analysis$intensity), logical(1))),
  "smoothed run: the analysis trace differs from the raw trace")
pq_assert(all(vapply(run_sg$detail, function(d)
  pq_analysis_xic(d)$intensity[1] == d$xic_analysis$intensity[1], logical(1))),
  "pq_analysis_xic() returns the smoothed trace")

pq_section("the hard guarantee: presence does not move")

pq_assert_equal(run_sg$rows$presence, run_raw$rows$presence,
                "presence verdicts identical with and without smoothing")
pq_assert_equal(run_sg$rows$xic_noise, run_raw$rows$xic_noise,
                "point-to-point noise is still measured on the raw trace")

# Presence is computed from the RAW detection (stored as `peak_presence`), so
# every presence-derived number must be bit-identical between a raw run and a
# smoothed run - that is the property that makes the switch safe.
pq_assert_equal(run_sg$rows$peak_height, run_raw$rows$peak_height,
                "peak height identical: presence uses the raw detection")
pq_assert_equal(run_sg$rows$presence_snr, run_raw$rows$presence_snr,
                "height/noise identical, so the verdict cannot flip")

exp_height <- function(d) {
  pk <- d$peak_presence
  if (is.null(pk) || is.na(pk$apex_intensity) || is.na(pk$baseline)) {
    return(NA_real_)
  }
  pk$apex_intensity - pk$baseline
}
heights_g <- vapply(run_sg$detail, exp_height, numeric(1))
pq_assert_equal(run_sg$rows$peak_height, as.numeric(heights_g),
                "height comes from the raw trace's own apex and baseline",
                tol = 1e-9)
pq_assert(all(run_sg$rows$peak_height[!run_sg$rows$presence %in% "absent"] > 0),
          "no present row reports a zero peak height after smoothing")

pq_section("but the scores do change, and are recorded as smoothed")

scored <- run_raw$rows$score_status == "ok" & run_sg$rows$score_status == "ok"
pq_assert(sum(scored) >= 2, "at least two rows are scored in both runs")
pq_assert(any(abs(run_sg$rows$SNR[scored] - run_raw$rows$SNR[scored]) > 1e-6),
          "SNR changes when the trace is smoothed (the metric is shape based)")
pq_assert(all(is.finite(run_sg$rows$peak_cor[scored])),
          "peak_cor stays finite after smoothing")

pq_assert("eic_smoothing" %in% names(run_raw$rows),
          "the result table carries the smoothing column")
pq_assert("eic_smoothing_applied" %in% names(run_raw$rows),
          "the result table says whether it was applied")

pq_section("unified table and parameter string carry it too")

u_raw <- pq_unified_from_run(run_raw$rows, params = run_raw$params)
u_sg <- pq_unified_from_run(run_sg$rows, params = run_sg$params)

pq_assert("xic_smoothing" %in% names(u_sg), "unified table has xic_smoothing")
pq_assert(all(u_raw$xic_smoothing == "none"), "raw unified rows say 'none'")
pq_assert(all(u_sg$xic_smoothing == "Savitzky-Golay (window 7, order 2)"),
          "smoothed unified rows carry the full label")

pq_assert_contains(pq_kumler_param_string(run_sg$params), "xic_smoothing=savgol_w7_o2",
                   "the Kumler parameter string records the smoothing")
pq_assert_contains(pq_kumler_param_string(run_raw$params), "xic_smoothing=none",
                   "an unsmoothed run is explicit about it too")

dict <- pq_unified_dictionary()
pq_assert_equal(nrow(dict), length(PQ_UNIFIED_COLUMNS),
                "the column dictionary covers every unified column")
pq_assert(all(nzchar(dict$meaning)), "no column is left undocumented")
pq_assert_contains(dict$meaning[dict$column == "xic_smoothing"],
                   "NOT comparable to a raw run",
                   "the dictionary warns that a smoothed score is not comparable to raw")

pq_section("the peak-group image uses the analysis trace")

rows_g <- run_sg$rows
det_g <- run_sg$detail
feat <- rows_g$feature_id[1]
members <- pq_group_members(det_g, rows_g, feat)
first_key <- names(det_g)[which(rows_g$feature_id == feat)[1]]
pq_assert_equal(members[[1]]$intensity, det_g[[first_key]]$xic_analysis$intensity,
                "group members come from the smoothed trace")
pq_assert(!identical(members[[1]]$intensity, det_g[[first_key]]$xic$intensity),
          "group members are NOT the raw trace when smoothing is on")

pq_section("provenance text states the consequence")

off <- pq_eic_smooth_provenance_lines(pq_default_params())
pq_assert_contains(paste(off, collapse = " "), "raw XIC",
                   "with smoothing off, provenance says the scores are raw")

on <- pq_eic_smooth_provenance_lines(run_sg$params)
pq_assert_contains(paste(on, collapse = " "), "NOT the author",
                   "with smoothing on, provenance says they are not the author's raw output")
pq_assert_contains(paste(on, collapse = " "), "point-to-point noise",
                   "provenance says what the switch does not affect")

pq_section("short label and plot traces")

pq_assert_equal(pq_eic_smooth_short_label("savgol", 7, 2), "Savitzky-Golay w=7",
                "the short label does not nest parentheses")
pq_assert_equal(pq_eic_smooth_short_label("movavg", 5, 2), "Moving average w=5",
                "the moving-average short label is distinct")
pq_assert_equal(pq_eic_smooth_short_label("none"), "none", "the none short label")
pq_assert_equal(run_sg$detail[[1]]$smoothing$short, "Savitzky-Golay w=7",
                "the stored smoothing info carries the short label")

if (requireNamespace("plotly", quietly = TRUE)) {
  trace_names <- function(entry, row) {
    b <- plotly::plotly_build(pq_plot_peak_quality(entry, row))
    vapply(b$x$data, function(tr) if (is.null(tr$name)) "" else tr$name, character(1))
  }
  nm_on <- trace_names(run_sg$detail[[1]], run_sg$rows[1, ])
  nm_off <- trace_names(run_raw$detail[[1]], run_raw$rows[1, ])
  pq_assert(any(grepl("XIC \\(raw\\)", nm_off)) && !any(grepl("analysis trace", nm_off)),
            "smoothing off: only the raw trace is drawn")
  pq_assert(any(grepl("XIC \\(raw\\)", nm_on)), "smoothing on: the raw trace is still drawn")
  pq_assert(any(grepl("analysis trace", nm_on)),
            "smoothing on: the scored analysis trace is drawn on top")
} else {
  pq_skip("plotly not installed: plot traces not checked")
}

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

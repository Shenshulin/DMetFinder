# ============================================================
# test_14 - applicability of the point-to-point noise estimate
# ============================================================
# The presence rules rest on
#     noise = 1.4826 * MAD(diff(x)) / sqrt(2)
# and a peak-height / noise ratio. This file checks the four situations the
# task list calls out, so the limits are documented behaviour rather than
# assumptions:
#
#   1. missing scans      - the XIC is unevenly sampled by construction
#                           (scans without a peak in the window are absent);
#   2. uneven RT spacing  - the estimator uses diff(intensity) only, so it is
#                           invariant to the RT axis. This is a property to
#                           state, not to fix: a long gap and a short gap
#                           contribute equally;
#   3. strong peak shape  - the peak itself must not dominate the estimate on
#                           a trace long enough to contain both peak and
#                           baseline;
#   4. near-zero noise    - a perfectly flat trace must not produce a ratio.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))
pq_source_project()

pq_section("estimator basics")

pq_assert(is.na(pq_point_noise(c(1, 2))), "two points cannot give a noise estimate")
pq_assert(is.na(pq_point_noise(numeric(0))), "an empty trace gives no noise estimate")
pq_assert_equal(pq_point_noise(rep(5, 20)), 0, "a perfectly flat trace has zero noise")

set.seed(101)
base <- 1000 + stats::rnorm(200, 0, 50)
n_est <- pq_point_noise(base)
pq_assert(abs(n_est - 50) / 50 < 0.35,
          sprintf("noise of a 50-SD baseline is estimated within 35%% (got %.1f)", n_est))

pq_section("missing scans")

# Every third point removed: this is what a window with absent scans looks
# like. The estimator must stay in the same ballpark, because it is scale
# based, not density based.
sparse <- base[seq(1, length(base), by = 3)]
n_sparse <- pq_point_noise(sparse)
pq_assert(abs(n_sparse - n_est) / n_est < 0.45,
          sprintf("removing 2 of 3 scans keeps the estimate within 45%% (dense %.1f, sparse %.1f)",
                  n_est, n_sparse))
pq_assert(!is.na(n_sparse), "a sparse but valid trace still yields an estimate")

# The documented consequence: with fewer points the estimate gets noisier, so
# the presence test refuses to use it below 6 points. Pin that boundary.
p5 <- pq_assess_presence(
  list(n_scans_in_window = 5L, n_mz_matched = 5L, noise = pq_point_noise(base[1:5])),
  data.frame(rt = 1:5, intensity = base[1:5]),
  list(peak = list(apex_intensity = base[1], baseline = min(base[1:5]))),
  modifyList(pq_default_params(), list(absent_snr = 5)))
pq_assert_equal(p5$presence, "present",
                "with 5 points the intensity test is skipped, not applied")

pq_section("uneven RT spacing")

# The estimator signature is the proof: it never receives an RT axis, so an
# uneven or pathological RT grid cannot enter the calculation. No
# interpolation happens anywhere in the presence path.
pq_assert_equal(names(formals(pq_point_noise)), "y",
                "the estimator takes intensities only, so RT spacing cannot enter it")
pq_assert_equal(pq_point_noise(rev(base)), pq_point_noise(base),
                "reversing the trace does not change the estimate")

pq_section("strong peak shape")

# A tall narrow peak on a long baseline: the estimate must describe the noise,
# not the peak. The peak occupies < 20% of the trace, so MAD keeps it out.
rt <- seq(0, 6, length.out = 300)
peak <- 5e5 * exp(-0.5 * ((rt - 3) / 0.06)^2)
trace <- 800 + peak + stats::rnorm(length(rt), 0, 40)
n_trace <- pq_point_noise(trace)
pq_assert(n_trace < 0.1 * 5e5,
          sprintf("a 5e5 peak does not inflate the noise estimate (got %.1f)", n_trace))
pq_assert(n_trace > 0, "the estimate is still positive on a peak-bearing trace")

# The same peak occupying most of the trace: this is the documented failure
# mode. The estimate rises because the peak's own flanks dominate diff().
peak_wide <- 5e5 * exp(-0.5 * ((rt - 3) / 1.2)^2)
wide <- 800 + peak_wide + stats::rnorm(length(rt), 0, 40)
n_wide <- pq_point_noise(wide)
pq_assert(n_wide > n_trace,
          sprintf("a peak covering most of the window inflates the estimate (%.1f vs %.1f) - documented, not fixed",
                  n_wide, n_trace))

pq_section("near-zero noise")

flat <- rep(100, 30) + rep(c(0, 0.001), 15)
n_flat <- pq_point_noise(flat)
pq_assert(!is.na(n_flat) && n_flat >= 0, "a near-constant trace still returns a value")

# height > 0 but noise == 0 must not be called absent merely because the ratio
# is undefined; the code treats a flat trace as absent only when height <= 0.
p_flat <- pq_assess_presence(
  list(n_scans_in_window = 30L, n_mz_matched = 30L, noise = 0),
  data.frame(rt = rt[1:30], intensity = flat),
  list(peak = list(apex_intensity = 100.001, baseline = 100)),
  modifyList(pq_default_params(), list(absent_snr = 5)))
pq_assert_equal(p_flat$presence, "present",
                "zero noise with a positive height is not called absent")

p_flat0 <- pq_assess_presence(
  list(n_scans_in_window = 30L, n_mz_matched = 30L, noise = 0),
  data.frame(rt = rt[1:30], intensity = rep(100, 30)),
  list(peak = list(apex_intensity = 100, baseline = 100)),
  modifyList(pq_default_params(), list(absent_snr = 5)))
pq_assert_equal(p_flat0$presence, "absent",
                "a truly flat trace with zero height is absent")

pq_section("noise never reaches the author scoring function")

# pq_score_xic() takes rt + intensity only; there is no noise argument in the
# vendored signature, and the adapter must not add one.
pq_assert_equal(names(formals(pq_vendor_qscoreCalculator)),
                c("rt", "int", "na.rm"),
                "the vendored scorer has no noise channel")
pq_assert_equal(names(formals(pq_score_xic)), c("rt", "intensity"),
                "the adapter passes only the trace to the author function")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

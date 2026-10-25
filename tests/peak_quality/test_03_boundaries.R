# ============================================================
# Test 03: automatic candidate peak boundaries
# ============================================================
# The boundary rules are project code, not the paper's. These tests pin the
# documented behaviour: apex closest to the input RT wins (never "the
# highest"), ambiguous cases are flagged instead of silently resolved,
# clipped peaks are reported, and the same input always gives the same output.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))

ROOT <- normalizePath(file.path(here, "../.."), winslash = "/")
pq_source_project(ROOT)

p <- pq_default_params()

mk_xic <- function(rt, int) {
  n <- length(rt)
  data.frame(rt = as.numeric(rt), intensity = as.numeric(int),
             scan = seq_len(n), n_mz = rep(1L, n), ppm_dev = rep(0, n),
             stringsAsFactors = FALSE)
}

rt <- seq(5.7, 6.3, by = 0.005)
gauss <- function(apex, sigma, h) h * exp(-((rt - apex)^2) / (2 * sigma^2))

pq_section("single clean peak")
d <- pq_detect_peaks(mk_xic(rt, gauss(6.0, 0.05, 1e5) + 5), 6.0, p)
pq_assert(d$status == "ok", "clean peak -> ok")
pq_assert(abs(d$peak$apex_rt - 6.0) < 1e-9, "apex at 6.000")
pq_assert(d$peak$start_rt < 6.0 && d$peak$end_rt > 6.0, "boundaries on both sides")
pq_assert(d$peak$start_kind == "threshold" && d$peak$end_kind == "threshold",
          "both boundaries found by threshold crossing")
pq_assert(d$n_candidates == 1, "exactly one candidate")
pq_assert(!is.na(d$peak$baseline), "baseline recorded")

pq_section("determinism")
d2 <- pq_detect_peaks(mk_xic(rt, gauss(6.0, 0.05, 1e5) + 5), 6.0, p)
pq_assert(identical(d$peak, d2$peak) && identical(d$candidates, d2$candidates),
          "identical input -> identical boundaries and candidates")

pq_section("degenerate XIC")
d_flat <- pq_detect_peaks(mk_xic(rt, rep(100, length(rt))), 6.0, p)
pq_assert(d_flat$status == "no_clear_apex", "flat XIC -> no_clear_apex")
d_zero <- pq_detect_peaks(mk_xic(rt, rep(0, length(rt))), 6.0, p)
pq_assert(d_zero$status == "no_clear_apex", "all-zero XIC -> no_clear_apex")
d_short <- pq_detect_peaks(mk_xic(c(6, 6.01), c(100, 200)), 6.0, p)
pq_assert(d_short$status == "too_few_points", "2 scans -> too_few_points")
d_empty <- pq_detect_peaks(mk_xic(numeric(0), numeric(0)), 6.0, p)
pq_assert(d_empty$status == "no_signal", "empty XIC -> no_signal")

pq_section("the highest peak is NOT preferred")
int_two <- gauss(6.02, 0.02, 4e4) + gauss(6.20, 0.02, 1e5) + 5
d_two <- pq_detect_peaks(mk_xic(rt, int_two), 6.02, p)
pq_assert(abs(d_two$peak$apex_rt - 6.02) < 1e-9,
          "selected apex is the one closest to the input RT, not the tallest")
pq_assert(d_two$n_candidates == 2, "both local maxima kept as candidates")
pq_assert(d_two$status %in% c("ambiguous", "boundary_unclear"),
          "two nearby candidates are flagged, not silently merged")
pq_assert(any(d_two$candidates$selected) && sum(d_two$candidates$selected) == 1,
          "exactly one candidate is marked selected")
pq_assert(all(c("apex_rt", "start_rt", "end_rt", "n_points", "prominence")
              %in% names(d_two$candidates)),
          "candidate table reports boundaries, width and prominence")

pq_section("apex outside the tolerance")
d_far <- pq_detect_peaks(mk_xic(rt, gauss(6.25, 0.03, 1e5) + 5), 6.00, p)
pq_assert(d_far$status == "apex_outside", "apex 0.25 min away -> apex_outside")
pq_assert_contains(d_far$reason, "0.250", "reason reports the measured offset")

pq_section("clipped peak at the window edge")
int_edge <- gauss(5.75, 0.06, 7e4) + 5
d_edge <- pq_detect_peaks(mk_xic(rt, int_edge), 5.78, p)
pq_assert(d_edge$status == "boundary_unclear", "peak cut by the window -> boundary_unclear")
pq_assert(identical(d_edge$peak$edge_touched, "left"),
          "the clipped side is reported as 'left'")
pq_assert(!d_edge$peak$boundary_ok, "boundary_ok is FALSE")

pq_section("too few scans inside the peak")
int_narrow <- gauss(6.0025, 0.002, 5e4) + 1
d_narrow <- pq_detect_peaks(mk_xic(rt, int_narrow), 6.00, p)
pq_assert(d_narrow$status == "too_few_points",
          "4 scans inside the peak -> too_few_points")
pq_assert(d_narrow$peak$n_points < p$min_points, "n_points reported below the minimum")

pq_section("noisy single peak stays a single candidate")
set.seed(11)
int_noisy <- gauss(6.0, 0.05, 8e4) * (1 + stats::runif(length(rt), -0.03, 0.03)) + 5
d_noisy <- pq_detect_peaks(mk_xic(rt, int_noisy), 6.0, p)
pq_assert(d_noisy$n_candidates == 1,
          "3% random noise does not create extra candidates")
pq_assert(d_noisy$status %in% c("ok", "boundary_unclear"),
          "noisy peak still yields a usable boundary status")

pq_section("shoulder produces two candidates and is flagged")
int_sh <- gauss(6.10, 0.04, 1e5) + gauss(6.24, 0.02, 5e4) + 5
d_sh <- pq_detect_peaks(mk_xic(rt, int_sh), 6.10, p)
pq_assert(d_sh$n_candidates >= 1, "shoulder analysed without error")
pq_assert(d_sh$status %in% c("ambiguous", "boundary_unclear"),
          "shoulder is flagged for review rather than reported as clean")

pq_section("peak slice matches the reported boundaries")
xic <- mk_xic(rt, gauss(6.0, 0.05, 1e5) + 5)
d3 <- pq_detect_peaks(xic, 6.0, p)
sl <- pq_peak_slice(xic, d3$peak)
pq_assert(nrow(sl) == d3$peak$n_points, "slice length equals n_points")
pq_assert_equal(range(sl$rt), c(d3$peak$start_rt, d3$peak$end_rt),
                "slice spans start_rt .. end_rt")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

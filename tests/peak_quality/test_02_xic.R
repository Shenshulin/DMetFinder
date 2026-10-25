# ============================================================
# Test 02: XIC extraction on .mzML / .mzXML synthetic files
# ============================================================
# Covers: both formats, RT seconds->minutes, MS1-only selection,
# ppm vs Da tolerance, aggregation strategies, missing scans,
# no-signal handling, m/z window with several ions.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))

ROOT <- normalizePath(file.path(here, "../.."), winslash = "/")
pq_source_project(ROOT)
source(file.path(here, "fixtures/make_fixtures.R"))

fx <- pq_fixture_make(file.path(tempdir(), "pq_fix_xic"))

pq_section("mzML / mzXML reading through the shared reader")
for (nm in c("mzml", "mzxml")) {
  ms <- pq_load_ms_file(fx[[nm]])
  pq_assert(nrow(ms$scan_table) == 601,
            sprintf("%s: 601 MS1 scans kept after MS1 filtering", nm))
  pq_assert(all(ms$scan_table$msLevel == 1L),
            sprintf("%s: no MS2 scan leaks into the MS1 view", nm))
  pq_assert_equal(range(ms$scan_table$StartTime), c(5, 8),
                  sprintf("%s: RT converted to minutes (300-480 s -> 5-8 min)", nm))
  pq_assert(identical(ms$ion_mode, "Negative"),
            sprintf("%s: polarity inferred as Negative", nm))
  pq_assert(ms$read_seconds >= 0, sprintf("%s: read time recorded", nm))
}

pq_section("raw reader keeps MS2 separate (never used as XIC intensity)")
ms <- pq_load_ms_file(fx$mzml, ms_level = NULL)
n_ms2 <- sum(ms$scan_table$msLevel == 2)
pq_assert(n_ms2 > 0, sprintf("unfiltered read still contains %d MS2 scans", n_ms2))
pq_assert_contains(ms$scan_table$scanType[ms$scan_table$msLevel == 2][1], "ms2",
                   "MS2 scans are labelled with their precursor")

ms <- pq_load_ms_file(fx$mzml)
ms1 <- pq_ms1_index(ms)
pq_section("clean peak XIC")
x <- pq_extract_xic(ms1 = ms1, ms = ms,
                    target_mz = 301.1234, input_rt = 6.0, rt_half_window = 0.3,
                    mz_tol_value = 10, mz_tol_unit = "ppm", aggregate = "max")
pq_assert(x$status == "ok", "clean peak: status ok")
pq_assert(x$diag$n_scans_in_window == 121,
          "RT window 6.00 +- 0.30 at 0.005 min spacing -> 121 scans")
pq_assert_equal(nrow(x$xic), 121, "one XIC point per scan (MS2 excluded)")
pq_assert_equal(max(x$xic$intensity), 1e5, "apex intensity equals the synthetic value")
pq_assert(abs(x$xic$rt[which.max(x$xic$intensity)] - 6.0) < 1e-9,
          "apex RT is 6.000 min")
pq_assert(x$diag$n_scans_missing == 0, "no missing scan inside the peak")
pq_assert(all(x$xic$n_mz == 1), "exactly one m/z matches per scan")

pq_section("m/z tolerance: ppm and Da")
x5 <- pq_extract_xic(ms1 = ms1, ms = ms,
                     target_mz = 551.5000, input_rt = 6.3, rt_half_window = 0.3,
                     mz_tol_value = 5, mz_tol_unit = "ppm", aggregate = "max")
pq_assert(x5$diag$n_scans_multi == 0,
          "5 ppm excludes the neighbour 2.8 mDa away (5.1 ppm)")
x10 <- pq_extract_xic(ms1 = ms1, ms = ms,
                      target_mz = 551.5000, input_rt = 6.3, rt_half_window = 0.3,
                      mz_tol_value = 10, mz_tol_unit = "ppm", aggregate = "max")
pq_assert(x10$diag$n_scans_multi > 0,
          "10 ppm includes both ions -> several m/z per scan are recorded")
pq_assert(x10$diag$n_mz_matched > x10$diag$n_scans_with_signal,
          "matched m/z count reported (more peaks than scans)")

x_da_small <- pq_extract_xic(ms1 = ms1, ms = ms,
                             target_mz = 551.5000, input_rt = 6.3,
                             rt_half_window = 0.3, mz_tol_value = 0.001,
                             mz_tol_unit = "Da", aggregate = "max")
pq_assert(x_da_small$diag$n_scans_multi == 0, "0.001 Da excludes the neighbour")
x_da_big <- pq_extract_xic(ms1 = ms1, ms = ms,
                           target_mz = 551.5000, input_rt = 6.3,
                           rt_half_window = 0.3, mz_tol_value = 0.004,
                           mz_tol_unit = "Da", aggregate = "max")
pq_assert(x_da_big$diag$n_scans_multi > 0, "0.004 Da includes the neighbour")

pq_assert_equal(pq_mz_window(500, 10, "ppm"), c(500 - 0.005, 500 + 0.005),
                "ppm window maths")
pq_assert_equal(pq_mz_window(500, 0.002, "Da"), c(499.998, 500.002),
                "Da window maths")

pq_section("aggregation strategies inside the window")
ap <- list()
for (agg in c("max", "nearest", "sum", "mean")) {
  xx <- pq_extract_xic(ms1 = ms1, ms = ms,
                       target_mz = 551.5000, input_rt = 6.3, rt_half_window = 0.3,
                       mz_tol_value = 10, mz_tol_unit = "ppm", aggregate = agg)
  ap[[agg]] <- max(xx$xic$intensity)
}
pq_assert(ap$max < ap$sum, "sum > max when two ions share the window")
pq_assert(abs(ap$sum - 110000) < 1, "sum equals 6e4 + 5e4 at the apex")
pq_assert(abs(ap$max - 60000) < 1, "max keeps the tallest ion only")
pq_assert(abs(ap$nearest - 60000) < 1,
          "nearest keeps the ion closest to the target m/z (551.5000)")
pq_assert(abs(ap$mean - 55000) < 1, "mean averages the two ions")

pq_section("no signal and no scans")
x_none <- pq_extract_xic(ms1 = ms1, ms = ms,
                         target_mz = 999.9, input_rt = 6.0, rt_half_window = 0.3,
                         mz_tol_value = 10, mz_tol_unit = "ppm", aggregate = "max")
pq_assert(x_none$status == "no_signal", "absent m/z -> status no_signal")
pq_assert(nrow(x_none$xic) == 0, "absent m/z -> empty XIC, no fabricated zeros")
pq_assert_contains(x_none$reason, "tolerance window", "reason explains no_signal")

x_out <- pq_extract_xic(ms1 = ms1, ms = ms,
                        target_mz = 301.1234, input_rt = 20, rt_half_window = 0.3,
                        mz_tol_value = 10, mz_tol_unit = "ppm", aggregate = "max")
pq_assert(x_out$status == "no_ms1_scans", "RT outside the run -> no_ms1_scans")

pq_section("missing scans are reported, never interpolated")
# empty the peak list of every 4th scan: the scan exists but contains no peak
# inside the window - this is what "missing scan" means for an XIC
ms_gap <- ms
drop_idx <- seq(1, length(ms_gap$spectra), by = 4)
for (j in drop_idx) ms_gap$spectra[[j]] <- list(mz = numeric(0), intensity = numeric(0))
ms1_gap <- pq_ms1_index(ms_gap)
xg <- pq_extract_xic(ms1 = ms1_gap, ms = ms_gap, target_mz = 301.1234,
                     input_rt = 6.0, rt_half_window = 0.3, mz_tol_value = 10,
                     mz_tol_unit = "ppm", aggregate = "max")
pq_assert(xg$diag$n_scans_missing > 0, "gappy data reports missing scans")
pq_assert(nrow(xg$xic) == xg$diag$n_scans_with_signal,
          "XIC has exactly one point per scan with signal (no zero filling)")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

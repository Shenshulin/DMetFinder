# ============================================================
# test_15_dnn_data — peak-group image construction
# ============================================================
# Locks the geometry the DNN sees. Every expectation here is traceable to
# peakGroupImageMatrixAndPlot.R @94237bf:
#   :402 numRtSlices <- floor(RtDur / minRtSep)
#   :414 vect.RtSlicePoints <- round(seq(start, end, length.out = n), 4)
#   :344 approx(..., method="linear", rule=2, ties=mean)
#   :350 x <= 0 -> 0
#   :355 <= 2 rows -> zero vector
#   :428 >  maxLines -> top maxLinesHigh + random maxLinesOther
#   :462 pad with zero rows to maxSignalFiles
#   :478 divide by global max
#   :486 marker row
# If any of these move, the model is being fed a different picture than the
# author trained on, so the test must fail loudly.
# ============================================================

local({
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", args[grep("^--file=", args)])
  here <- if (length(f) == 1) dirname(normalizePath(f, winslash = "/")) else getwd()
  source(file.path(here, "helpers.R"), encoding = "UTF-8")
})

pq_source_project()

P <- pq_dnn_params()

# ------------------------------------------------------------
pq_section("author defaults are transcribed, not invented")

pq_assert_equal(P$rt_duration, 1, "rt_duration = 1 min")
pq_assert_equal(P$min_rt_sep, 0.005, "min_rt_sep = 0.005 min")
pq_assert_equal(P$max_signal_files, 30L, "max_signal_files = 30 rows")
pq_assert_equal(P$prop_high_peaks, 0.7, "prop_high_peaks = 0.7")

# ------------------------------------------------------------
pq_section("RT grid geometry")

g <- pq_dnn_rt_grid(1.5, 1.6, P)
pq_assert_equal(length(g), 200L, "floor(1 / 0.005) = 200 columns")
pq_assert_equal(min(g), 1.05, "grid starts at midpoint - 0.5", tol = 1e-9)
pq_assert_equal(max(g), 2.05, "grid ends at midpoint + 0.5", tol = 1e-9)
pq_assert_equal(g[1], 1.05, "first point rounded to 4 decimals", tol = 1e-12)

# the grid is centred on the window midpoint, NOT on its width
g_wide <- pq_dnn_rt_grid(1.0, 3.0, P)
pq_assert_equal(mean(range(g_wide)), 2.0,
                "grid centre follows the window midpoint", tol = 1e-9)
pq_assert_equal(diff(range(g_wide)), 1.0,
                "grid width is rt_duration, not the window width", tol = 1e-9)

# a one-minute window spans exactly the grid
pq_assert_true(all(g >= 1.05 & g <= 2.05), "grid covers its own span")

# ------------------------------------------------------------
pq_section("interpolation holds endpoints (rule = 2), never returns NA")

grid <- pq_dnn_rt_grid(1.0, 1.1, P)
# a narrow XIC in the middle: outside its range, rule=2 must repeat the edge
rt <- c(1.45, 1.50, 1.55)
it <- c(100, 500, 200)
row <- pq_dnn_row_from_xic(rt, it, grid)
pq_assert_equal(length(row), 200L, "row length equals the grid length")
pq_assert_true(!anyNA(row), "no NA anywhere in the row")
pq_assert_equal(row[1], 100, "left of the trace holds the first value", tol = 1e-9)
pq_assert_equal(row[200], 200, "right of the trace holds the last value", tol = 1e-9)
# The apex is only sampled if a grid point lands on it. With 200 points across
# one minute the spacing is 0.005 min, so a narrow apex can be missed by a few
# tenths of a percent. That is inherent to the author's grid and is why the
# check is a band, not an equality.
pq_assert_true(max(row) <= 500 + 1e-9 && max(row) > 490,
               sprintf("apex survives within one grid step (got %.1f of 500)", max(row)))

# ------------------------------------------------------------
pq_section("too few points cannot describe a peak")

r2 <- pq_dnn_row_from_xic(c(1.0, 1.1), c(10, 20), grid)
pq_assert_true(all(r2 == 0), "two points -> all-zero row")
r1 <- pq_dnn_row_from_xic(1.0, 10, grid)
pq_assert_true(all(r1 == 0), "one point -> all-zero row")
r0 <- pq_dnn_row_from_xic(numeric(0), numeric(0), grid)
pq_assert_true(all(r0 == 0), "no points -> all-zero row")

# ------------------------------------------------------------
pq_section("non-positive RT is forced to zero")

rt_neg <- c(-0.10, 0.00, 0.20, 1.40, 1.50)
it_neg <- c(900, 800, 700, 600, 500)
rn <- pq_dnn_row_from_xic(rt_neg, it_neg, grid)
pq_assert_true(all(rn[grid <= 0] == 0),
               "every grid point at RT <= 0 is zero, even though rule=2 would hold 900")

# ------------------------------------------------------------
pq_section("member selection follows the author's 21 + 9 split")

# 40 samples with strictly increasing intensity
mi <- seq(1, 40)
sel <- pq_dnn_select_members(mi, P, seed = 42L)
pq_assert_equal(length(sel), 30L, "capped at max_signal_files")
top21 <- order(-mi)[1:21]
pq_assert_true(all(top21 %in% sel),
               "the 21 tallest samples are always kept (prop_high_peaks = 0.7)")
pq_assert_equal(length(sel), 30L, "21 tall + 9 random = 30")

sel_seed1 <- pq_dnn_select_members(mi, P, seed = 7L)
sel_seed2 <- pq_dnn_select_members(mi, P, seed = 7L)
pq_assert_equal(sel_seed1, sel_seed2, "the same seed reproduces the same draw")

# no cap needed
sel_small <- pq_dnn_select_members(c(5, 0, 3), P)
pq_assert_equal(sort(sel_small), c(1L, 3L),
                "samples with zero intensity in the window are dropped")

# all zero
pq_assert_equal(length(pq_dnn_select_members(c(0, 0), P)), 0L,
                "a window with no signal selects nothing")

# ------------------------------------------------------------
pq_section("matrix assembly")

mk_trace <- function(apex, start = apex - 0.10, end = apex + 0.10, top = 1000) {
  rt <- seq(start, end, length.out = 40)
  shape <- exp(-((rt - apex)^2) / (2 * 0.02^2))
  data.frame(rt = rt, intensity = top * shape, scan = seq_along(rt))
}

traces <- list(mk_trace(1.50, top = 1000), mk_trace(1.52, top = 500))
built <- pq_dnn_build_matrix(traces, c("s1", "s2"),
                             rt_min = 1.45, rt_max = 1.55,
                             mz_min = 100, mz_max = 100.01, params = P)

pq_assert_true(isTRUE(built$ok), "matrix built")
pq_assert_equal(nrow(built$matrix), 31L, "30 sample rows + 1 marker row")
pq_assert_equal(ncol(built$matrix), 200L, "200 RT slices")
pq_assert_equal(max(built$matrix), 1,
                "global maximum scaling makes the largest cell exactly 1",
                tol = 1e-12)
pq_assert_equal(sum(built$matrix[31, ]), sum(built$grid >= 1.45 & built$grid <= 1.55),
                "marker row marks exactly the window columns")
pq_assert_true(all(built$matrix[31, ] %in% c(0, 1)), "marker row is binary")
pq_assert_true(all(built$matrix[3:30, ] == 0),
               "empty sample slots are zero rows, not NA")
pq_assert_equal(built$n_signal, 2L, "two samples had signal")
pq_assert_equal(built$rows, c("s1", "s2"), "row map records which sample is which")

# the taller sample keeps the brighter row
pq_assert_true(sum(built$matrix[1, ]) > sum(built$matrix[2, ]),
               "row order follows decreasing window intensity")

# ------------------------------------------------------------
pq_section("degenerate inputs are reported, not faked")

none <- pq_dnn_build_matrix(list(mk_trace(1.50, top = 0)), "s1",
                            rt_min = 1.45, rt_max = 1.55,
                            mz_min = 100, mz_max = 101, params = P)
pq_assert_true(!isTRUE(none$ok), "an all-zero window does not produce an image")
pq_assert_equal(none$reason, "no_signal_in_window", "and says why")

empty <- pq_dnn_build_matrix(list(), character(0),
                             rt_min = 1.45, rt_max = 1.55,
                             mz_min = 100, mz_max = 101, params = P)
pq_assert_true(!isTRUE(empty$ok), "no traces -> no image")
pq_assert_equal(empty$reason, "no_traces", "and says why")

# ------------------------------------------------------------
pq_section("resampling is explicit and flagged as approximate")

small <- pq_dnn_build_matrix(traces, c("s1", "s2"),
                             rt_min = 1.45, rt_max = 1.55,
                             mz_min = 100, mz_max = 101, params = P)$matrix
rs <- pq_dnn_resample_to(small, 64, 64)
pq_assert_equal(dim(rs), c(64L, 64L), "resample lands on 64x64")
pq_assert_true(max(rs) <= max(small) + 1e-12,
               "resampling never invents values above the source maximum")
rs_same <- pq_dnn_resample_to(small, nrow(small), ncol(small))
pq_assert_equal(rs_same, small, "same shape is a no-op")

# ------------------------------------------------------------
pq_section("batch driver joins on rows and survives missing traces")

rows <- data.frame(
  feature_id = c("f1", "f1", "f1", "f2", "f2"),
  sample_id  = c("s1", "s2", "s3", "s1", "s2"),
  input_rt   = c(1.5, 1.5, 1.5, 4.2, 4.2),
  stringsAsFactors = FALSE
)
detail <- list(
  list(xic = mk_trace(1.50, top = 900), peak = list(start_rt = 1.44, end_rt = 1.56)),
  list(xic = mk_trace(1.51, top = 400), peak = list(start_rt = 1.45, end_rt = 1.55)),
  NULL,
  list(xic = mk_trace(4.20, top = 700), peak = list(start_rt = NA_real_, end_rt = NA_real_)),
  list(xic = mk_trace(4.22, top = 300), peak = list(start_rt = NA_real_, end_rt = NA_real_))
)

bt <- pq_dnn_batch(rows, detail, P, seed = 3L)
pq_assert_equal(bt$n_window, 2L, "one image per feature")
pq_assert_equal(nrow(bt$meta), 2L, "meta has one row per feature")

f1 <- bt$meta[bt$meta$feature_id == "f1", ]
pq_assert_equal(f1$n_samples, 3L, "all three samples are counted")
pq_assert_equal(f1$n_signal, 2L, "but only the two with a trace can be drawn")
pq_assert_equal(f1$rt_bounds_from, "detected_peak_edges",
                "window comes from detected edges when available")
pq_assert_equal(f1$rt_min, 1.44, "window min = earliest edge", tol = 1e-9)

f2 <- bt$meta[bt$meta$feature_id == "f2", ]
pq_assert_equal(f2$rt_bounds_from, "input_rt_fallback",
                "falls back to the input RT when no edge was detected")
pq_assert_equal(f2$rt_min, 4.2 - 0.5, "fallback window is centred on input RT",
                tol = 1e-9)
pq_assert_true(isTRUE(f2$image_ok), "the fallback still produces a usable image")

pq_assert_equal(bt$images[[1]][31, 1], 0, "marker row exists in the batch output")
pq_assert_true(all(dim(bt$images[[1]]) == c(31L, 200L)),
               "batch images keep the author geometry")

# empty input
bt0 <- pq_dnn_batch(rows[0, ], list(), P)
pq_assert_equal(bt0$n_window, 0L, "empty input yields zero windows, not an error")

# ------------------------------------------------------------
pq_section("geometry note is complete enough to ship as provenance")

note <- pq_dnn_geometry_note(P)
pq_assert_equal(nrow(note), 11L, "eleven documented geometry facts")
pq_assert_true(all(c("n_rt_slices", "marker_row", "scaling",
                     "interpolation", "zero_handling") %in% note$item),
               "the note names the decisions a reader would question")
pq_assert_equal(note$value[note$item == "n_rt_slices"], "200",
                "note agrees with the code")

# ------------------------------------------------------------
pq_section("conversion to the model layout is a transpose, not a resize")

# The native matrix has samples on rows and the marker as the last row. The
# published model expects retention time on rows and the marker as the last
# COLUMN (1304/1304 training images have a binary last column, none a binary
# last row). A plain resize keeps samples on the wrong axis, which scored clean
# synthetic peaks at 0.41-0.46 instead of 0.93-0.97.
nat <- matrix(0, nrow = 31, ncol = 200)
for (i in 1:30) nat[i, ] <- i / 100            # sample i has a flat level
nat[31, 51:150] <- 1                           # marker: inside the window

gm <- pq_dnn_to_model_geometry(nat, 64, 64)

pq_assert_equal(dim(gm), c(64L, 64L), "model geometry is 64x64")
pq_assert_true(all(gm[, 64] %in% c(0, 1)), "marker sits in the last column")
pq_assert_true(sum(gm[, 64]) > 0, "and is not empty there")
# The native marker row had 100 ones. If it had survived as a row, some row
# would carry ~100 ones. Only the marker column can contribute a 1 here, so no
# row may hold more than one.
pq_assert_true(all(apply(gm, 1, function(r) sum(r == 1)) <= 1L),
               "the native marker row did not survive as a row")

# sample i keeps its identity: column i of the model image is sample i
pq_assert_equal(gm[1, 1], 1 / 100, "sample 1 lands in column 1, not row 1")
pq_assert_equal(gm[1, 30], 30 / 100, "sample 30 lands in column 30")
pq_assert_true(all(gm[, 31:63] == 0), "unused sample columns are zero, not interpolated")

# the retention-time axis is compressed by index, so the marker's 100/200
# coverage becomes roughly a third of the 64 rows
pq_assert_true(abs(sum(gm[, 64]) - 32) <= 2, "marker coverage survives compression")

# round trip: a real-shaped image must come back unchanged on kept cells
set.seed(7)
real <- matrix(stats::runif(64 * 64), 64, 64)
real[, 64] <- as.numeric(seq_len(64) %% 2)     # binary marker column
mk <- real[, 64]
s30 <- real[, 1:30, drop = FALSE]
native_from_real <- rbind(t(s30), mk)
back <- pq_dnn_to_model_geometry(native_from_real, 64, 64)
pq_assert_equal(back[, 1:30], s30, "round trip preserves every sample column")
pq_assert_equal(back[, 64], mk, "round trip preserves the marker column")

# ------------------------------------------------------------
pq_section("model geometry is read from the right positions of the shape")

p0 <- pq_dnn_params()
pq_assert_true(is.null(p0$model_height), "native params ask for no conversion")

mi <- list(input_shape = c(1304, 64, 64, 1))
p1 <- pq_dnn_params_for_model(mi, p0)
pq_assert_equal(p1$model_height, 64L, "height comes from position 2")
pq_assert_equal(p1$model_width, 64L, "width comes from position 3")
pq_assert_true(is.null(p0$model_height),
               "the caller's params object is not mutated in place")

bad <- pq_dnn_params_for_model(list(input_shape = c(1304, 64)), p0)
pq_assert_true(is.null(bad$model_height),
               "a truncated shape does not invent a geometry")
none <- pq_dnn_params_for_model(list(input_shape = NULL), p0)
pq_assert_true(is.null(none$model_height),
               "a missing shape does not invent a geometry")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

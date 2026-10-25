# ============================================================
# Stage-3 tests: cross-sample peak groups (DNN input)
# ============================================================
# Scope of this stage: image construction + visualisation + diagnosis of
# missing members. No model, no probability. The checks follow the author's
# peakGroupImageMatrixAndPlot.R contract one step at a time.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))
pq_source_project()

run <- pq_make_synthetic_run(n_samples = 4L, features = c("F1", "F2"))
rows <- run$rows
detail <- run$detail
p <- pq_default_group_params()

# ------------------------------------------------------------
pq_section("group members")
# ------------------------------------------------------------
feat <- "F1"
win <- pq_group_window(rows, feat)
pq_assert(length(win) == 2 && all(is.finite(win)),
          "the group window is finite for a normal feature")
pq_assert(win[1] < win[2], "the window has a positive width")

mem <- pq_group_members(detail, rows, feat)
pq_assert_equal(length(mem), sum(rows$feature_id == feat),
                "every sample of the feature becomes a member")
pq_assert(all(vapply(mem, function(m) m$status %in% c("signal", "absent", "no_xic"),
                     logical(1))),
          "member status is one of signal / absent / no_xic")

# ------------------------------------------------------------
pq_section("image construction (author contract)")
# ------------------------------------------------------------
img <- pq_peak_group_image(mem, win, p)
pq_assert(isTRUE(img$ok), "an image is built when members have signal")
pq_assert_equal(ncol(img$matrix), p$n_slices,
                "the image has the requested number of RT bins")
pq_assert_equal(nrow(img$matrix), sum(vapply(mem, function(m)
  identical(m$status, "signal"), logical(1))),
  "one image row per member with signal")
pq_assert(abs(max(img$matrix) - 1) < 1e-12,
           "the matrix is normalised by its global maximum")
pq_assert(all(img$matrix >= 0), "the image contains no negative values")
pq_assert_equal(length(img$mask), p$n_slices,
                "the mask row has one entry per column")
pq_assert(all(img$mask == 1L),
          "with a grid built over the window the mask marks every column")

# rule = 2: outside the measured range the edge value is carried as a plateau
edge_member <- list(list(sample_id = "TRUNC",
                         status = "signal",
                         rt = seq(win[1] + 0.10, win[2] - 0.05, length.out = 20),
                         intensity = rep(1000, 20)))
img2 <- pq_peak_group_image(edge_member, win, p)
pq_assert_equal(unname(img2$matrix[1, 1:2]), c(1, 1),
                "rule = 2 pads the left edge with a constant (no invented slope)")
pq_assert_equal(unname(img2$matrix[1, (p$n_slices - 1):p$n_slices]), c(1, 1),
                "rule = 2 pads the right edge with a constant")
pq_assert(max(img2$matrix) == min(img2$matrix),
          "the padded plateaus are the only level, i.e. no slope was invented")
pq_assert_equal(img2$extrapolated, "TRUNC",
                "members that do not cover the window are reported")

# zero-signal members are dropped, not zero-filled
zero_member <- list(
  list(sample_id = "OK", status = "signal",
       rt = seq(win[1], win[2], length.out = 30),
       intensity = rep(5000, 30)),
  list(sample_id = "ZERO", status = "signal", rt = numeric(0), intensity = numeric(0)))
img3 <- pq_peak_group_image(zero_member, win, p)
pq_assert_equal(nrow(img3$matrix), 1L, "a member without signal is removed from the image")
pq_assert_equal(img3$dropped, "ZERO", "the dropped member is named")

# padding to a fixed row count
p_pad <- utils::modifyList(p, list(pad_rows = 63L))
img4 <- pq_peak_group_image(zero_member, win, p_pad)
pq_assert_equal(nrow(img4$matrix), 63L, "the image can be padded to the paper's 63 rows")
pq_assert_equal(img4$n_padded, 62L, "the number of padded rows is recorded")
pq_assert(all(is.na(utils::tail(img4$samples, 62))),
          "padded rows carry no sample id (they can never be mistaken for data)")

# no signal at all
none <- list(list(sample_id = "X", status = "absent", rt = numeric(0), intensity = numeric(0)))
img5 <- pq_peak_group_image(none, win, p)
pq_assert(!isTRUE(img5$ok), "no image is built when no member has signal")
pq_assert_contains(img5$reason, "no member", "the reason is stated")

# mask can be narrowed to the peak window
p_mask <- utils::modifyList(p, list(mask_rt = c(stats::median(win), win[2])))
img6 <- pq_peak_group_image(mem, win, p_mask)
pq_assert(sum(img6$mask) < length(img6$mask),
          "a narrower mask marks only the columns inside it")

# ------------------------------------------------------------
pq_section("diagnostics")
# ------------------------------------------------------------
g <- pq_peak_group(rows, detail, feat, p)
pq_assert(isTRUE(g$ok), "the group is usable")
pq_assert_equal(g$diagnostics$feature_id, feat, "diagnostics name the feature")
pq_assert_equal(g$diagnostics$n_rows_in_table, sum(rows$feature_id == feat),
                "the diagnostics count every row of the table")
pq_assert(g$diagnostics$n_signal >= 2, "the count of members with signal is reported")
pq_assert(is.finite(g$diagnostics$apex_rt_median),
          "the median apex RT across members is reported")
pq_assert(g$diagnostics$apex_drift_median_abs >= 0,
          "the RT drift between members is quantified")
pq_assert(g$diagnostics$n_multi_peak_members >= 0,
          "the number of members with more than one local maximum is reported")

# a single member cannot form a cross-sample group
one <- pq_make_synthetic_run(n_samples = 1L, features = "Solo")
g1 <- pq_peak_group(one$rows, one$detail, "Solo", p)
pq_assert_equal(g1$diagnostics$admissibility, "single_member",
                "a one-sample group is flagged as single_member")
pq_assert_contains(g1$diagnostics$reason, "cross-sample",
                   "the reason explains why the published method does not apply")

# the absent sample of F2 is counted, not silently missing
g2 <- pq_peak_group(rows, detail, "F2", p)
pq_assert_equal(g2$diagnostics$n_absent, 1L,
                "samples without the peak are counted as absent")

# several local maxima are detected (both humps are interior, so both have a
# real prominence; an endpoint maximum has none by construction)
multi <- list(list(sample_id = "M", status = "signal",
                   rt = seq(1, 2, length.out = 60),
                   intensity = c(seq(100, 5000, length.out = 15),
                                 seq(5000, 200, length.out = 15),
                                 seq(200, 4000, length.out = 15),
                                 seq(4000, 100, length.out = 15))))
pq_assert(pq_count_local_maxima(multi[[1]]$intensity) >= 2,
          "a two-peak trace is recognised as having several local maxima")

# ... but noise ripples are not mistaken for co-eluting peaks
set.seed(3)
noisy <- 2e5 * exp(-0.5 * ((seq(1, 2, length.out = 61) - 1.5) / 0.05)^2) +
  stats::rnorm(61, 0, 1500)
pq_assert_equal(pq_count_local_maxima(noisy), 1L,
                "a single noisy peak is not reported as multi-peak")

# ------------------------------------------------------------
pq_section("all-feature diagnostics table")
# ------------------------------------------------------------
tbl <- pq_peak_group_table(rows, detail, p)
pq_assert_equal(nrow(tbl), length(unique(rows$feature_id)),
                "the table has one row per feature")
pq_assert(all(c("feature_id", "admissibility", "n_signal", "n_absent") %in%
                names(tbl)),
          "the table carries the decision and the counts")
pq_assert(all(tbl$admissibility %in% c("ok", "single_member", "no_signal",
                                       "image_failed", "no_window")),
          "admissibility uses the documented vocabulary")

# ------------------------------------------------------------
pq_section("no fabricated probability anywhere")
# ------------------------------------------------------------
pq_assert(!any(grepl("prob", names(g$diagnostics), ignore.case = TRUE)),
          "the group diagnostics contain no probability column")
pq_assert(!any(grepl("pred|quality", names(tbl), ignore.case = TRUE)),
          "the all-feature table contains no predicted class or probability")
info <- pq_method_info("dnn")
# The author never calibrated the network, so its output is declared a score.
# `probability = TRUE` here would let the unified table present it as one.
pq_assert(isFALSE(info$probability),
          "the registry records that the DNN output is a score, not a probability")
pq_assert_equal(pq_method_scope("dnn"), "peak_group",
                "the DNN's declared scope is the peak group")
# The group diagnostics must stay method-free whether or not weights exist:
# building an image is not a prediction.
pq_assert(!any(grepl("dnn|pred", names(g$diagnostics), ignore.case = TRUE)),
          "the group diagnostics stay free of model output")
# Availability must follow the verified weights, and when they are missing it
# must say model_not_available rather than leaving the columns blank.
dnn_av <- pq_method_available("dnn")
if (isTRUE(dnn_av$ok)) {
  pq_assert_contains(dnn_av$version, substr(dnn_av$model$sha256, 1, 12),
                     "an available model is identified by its weight hash")
} else {
  pq_assert_contains(dnn_av$reason, "model_not_available",
                     "without weights the reason is model_not_available")
}

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

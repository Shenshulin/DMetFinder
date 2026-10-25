# ============================================================
# DNN input guard: a wrong matrix must fail loudly, and a missing model must
# never produce a score
# ============================================================
# Why this file exists
#   A transposed peak-group image does not make a Keras model complain. It
#   returns a confident-looking *low* score, which is indistinguishable from a
#   real verdict. During the first integration attempt three clean synthetic
#   peaks scored 0.41-0.46 for exactly this reason. The guard in
#   pq_dnn_validate_input() is the fix, and these checks pin it down:
#
#     * the model's own layout passes,
#     * the transposed layout is rejected as orientation_error,
#     * a wrong size is rejected as shape_mismatch,
#     * out-of-range values and empty images are rejected,
#     * pq_dnn_apply() stops before writing or predicting when the guard fails,
#     * without weights there is no score at all - not a zero, not an NA read
#       as "bad peak".
# ============================================================

source(file.path(dirname(sub("^--file=", "",
  commandArgs(trailingOnly = FALSE)[grep("^--file=", commandArgs(trailingOnly = FALSE))])),
  "helpers.R"), encoding = "UTF-8")
pq_source_project(pq_proj_root())

# ------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------
# A native 31 x 200 matrix exactly as pq_dnn_build_matrix() produces it:
# 30 sample rows (peak i has a slightly shifted apex) + one marker row.
mk_native <- function(n_sample = 30, n_slice = 200) {
  grid <- seq(2.5, 3.5, length.out = n_slice)
  rows <- t(vapply(seq_len(n_sample), function(i) {
    apex <- 3.0 + (i - n_sample / 2) * 0.0005
    y <- 90000 * exp(-((grid - apex)^2) / (2 * 0.02^2))
    y
  }, numeric(n_slice)))
  rows <- rows / max(rows)                  # global maximum scaling
  marker <- as.numeric(grid >= 2.9 & grid <= 3.1)
  rbind(rows, marker)
}

model_64 <- list(available = TRUE, status = "available",
                 sha256 = "0123456789abcdef0123456789abcdef",
                 input_shape = c(1304L, 64L, 64L),
                 # a real file so the predictor's own existence check is not
                 # what stops the run
                 path = file.path(pq_proj_root(), "DNN_reference", "models",
                                  "edml15.h5"))

native <- mk_native()
good <- pq_dnn_to_model_geometry(native, 64L, 64L)

# ============================================================
# A. The model's own layout passes
# ============================================================
cat("\n== correct layout ==\n")
v <- pq_dnn_validate_input(good, model_64)
pq_assert_true(isTRUE(v$ok), "a 64x64 image in the model layout is accepted")
pq_assert_equal(v$status, "ok", "the accepted image reports status ok")
pq_assert_true(all(v$checks$pass), "every contract check passes")
pq_assert_equal(dim(good), c(64L, 64L), "the fixture really is 64x64")
pq_assert_true(all(good[, 64] %in% c(0, 1)), "the marker sits in the last column")
pq_assert_true(sum(good[, 64]) > 0, "the marker is not empty")
pq_assert_true(all(good >= 0 & good <= 1), "values stay inside [0, 1]")

# ============================================================
# B. Transposed input is rejected as an orientation error
# ============================================================
cat("\n== transposed input ==\n")
bad_t <- t(good)
v_t <- pq_dnn_validate_input(bad_t, model_64)
pq_assert_true(!isTRUE(v_t$ok), "a transposed image is not accepted")
pq_assert_equal(v_t$status, "orientation_error",
                "the transposed image is diagnosed as an orientation error")
pq_assert_contains(v_t$reason, "transposed", "the reason says the image is transposed")
pq_assert_true(any(!v_t$checks$pass), "at least one check failed")

# A square transpose has the right shape, so the size check cannot catch it:
# the marker axis check is what does. Prove that by asserting the shape check
# itself passed.
pq_assert_true(v_t$checks$pass[v_t$checks$check == "shape"],
               "the size check alone cannot detect a square transpose")
pq_assert_true(!v_t$checks$pass[v_t$checks$check == "marker_axis"],
               "the marker-axis check is what detects it")

# ============================================================
# C. Wrong size
# ============================================================
cat("\n== wrong size ==\n")
v_s <- pq_dnn_validate_input(native, model_64)
pq_assert_equal(v_s$status, "shape_mismatch",
                "a native 31x200 matrix is rejected before prediction")
pq_assert_contains(v_s$reason, "31 x 200", "the reason quotes the actual size")
pq_assert_contains(v_s$reason, "64 x 64", "the reason quotes the expected size")

# ============================================================
# D. Value range and empty images
# ============================================================
cat("\n== invalid content ==\n")
scaled <- good * 2
v_r <- pq_dnn_validate_input(scaled, model_64)
pq_assert_equal(v_r$status, "value_range",
                "cells above 1 mean the scaling step was skipped, and are rejected")

blank <- matrix(0, 64, 64)
blank[, 64] <- good[, 64]
v_e <- pq_dnn_validate_input(blank, model_64)
pq_assert_equal(v_e$status, "empty_image",
                "an image with no signal is a failed extraction, not a peak")

no_marker <- good
no_marker[, 64] <- 0
v_m <- pq_dnn_validate_input(no_marker, model_64)
pq_assert_true(!isTRUE(v_m$ok), "an all-zero marker is refused")
pq_assert_true(!v_m$checks$pass[v_m$checks$check == "marker_content"],
               "the marker-content check is the one that failed")

v_null <- pq_dnn_validate_input(NULL, model_64)
pq_assert_true(!isTRUE(v_null$ok), "no matrix is not a valid input")

# ============================================================
# E. Batch-level guard
# ============================================================
cat("\n== batch guard ==\n")
mk_batch <- function(mats, ids = paste0("f", seq_along(mats))) {
  list(images = mats,
       meta = data.frame(feature_id = ids, n_samples = 30L, n_signal = 30L,
                         rt_min = 2.9, rt_max = 3.1,
                         rt_bounds_from = "detected_peak_edges",
                         image_ok = TRUE, image_status = "ok",
                         image_rows = 64L, image_cols = 64L,
                         image_native_rows = 31L, image_native_cols = 200L,
                         image_resampled = TRUE,
                         stringsAsFactors = FALSE),
       n_window = length(mats))
}

gb <- pq_dnn_validate_batch(mk_batch(list(good, good)), model_64)
pq_assert_true(isTRUE(gb$ok), "a batch of valid images passes")
pq_assert_equal(nrow(gb$table), 2L, "the batch report has one row per group")
pq_assert_true(all(gb$table$ok), "every group in the report is ok")

gb2 <- pq_dnn_validate_batch(mk_batch(list(good, t(good))), model_64)
pq_assert_true(!isTRUE(gb2$ok), "one bad group fails the whole batch")
pq_assert_equal(gb2$status, "orientation_error", "the batch reports the root cause")
pq_assert_contains(gb2$reason, "f2", "the batch names which group failed")

# ============================================================
# F. pq_dnn_apply stops before predicting
# ============================================================
cat("\n== apply stops ==\n")
rows <- pq_empty_row()[rep(1, 3), , drop = FALSE]
rows$feature_id <- "f1"
rows$sample_id <- c("S1", "S2", "S3")
rows$mz <- 300.1
rows$input_rt <- 3.0
rows$presence <- "present"
rows$score_status <- "ok"
rows$file <- "a.mzML"
detail <- lapply(seq_len(3), function(i) {
  list(xic = data.frame(rt = seq(2.5, 3.5, length.out = 60),
                        intensity = 1e4 * exp(-((seq(2.5, 3.5, length.out = 60) - 3)^2) / (2 * 0.02^2))),
       peak = list(start_rt = 2.95, end_rt = 3.05, apex_rt = 3.0))
})

paths <- list(root = pq_proj_root(),
              base = file.path(pq_proj_root(), "DNN_reference"),
              model_dir = file.path(pq_proj_root(), "DNN_reference", "models"),
              matrices = file.path(tempdir(), "guard_matrices"),
              pred_dir = file.path(tempdir(), "guard_preds"),
              python = file.path(tempdir(), "definitely_no_python.exe"),
              pred_py = file.path(tempdir(), "no_predict.py"))

# Shadow the batch builder for the duration of this block: this is the only way
# to inject a transposed matrix through the real apply() path, and it exercises
# exactly the wiring that matters - guard first, export/predict never.
orig_batch <- pq_dnn_batch
pq_batch_bad <- function(...) mk_batch(list(t(good)), ids = "f1")
assign("pq_dnn_batch", pq_batch_bad, envir = globalenv())
res_bad <- pq_dnn_apply(rows, detail, paths, model_info = model_64,
                        run_tag = "guard_test")
assign("pq_dnn_batch", orig_batch, envir = globalenv())

pq_assert_true(isFALSE(res_bad$ok), "a rejected input does not produce a result")
pq_assert_equal(res_bad$status, "input_geometry_invalid",
                "the run is refused with input_geometry_invalid")
pq_assert_contains(res_bad$detail, "nothing was predicted",
                   "the message states that nothing was predicted")
pq_assert_true(is.null(res_bad$predictions), "no predictions object is returned")
pq_assert_true(!dir.exists(paths$matrices),
               "nothing is exported to disk when the guard fails")
pq_assert_true(all(is.na(res_bad$rows$dnn_score)),
               "no score - not a zero, not a low value - reaches the table")
pq_assert_equal(unique(res_bad$rows$dnn_scope), "peak_group",
                "the rejected rows still declare their scope")

# A valid batch must get past the guard; it then fails on the missing
# interpreter, which proves the guard was not what stopped it.
pq_batch_ok <- function(...) mk_batch(list(good), ids = "f1")
assign("pq_dnn_batch", pq_batch_ok, envir = globalenv())
res_ok <- pq_dnn_apply(rows, detail, paths, model_info = model_64,
                       run_tag = "guard_pass")
assign("pq_dnn_batch", orig_batch, envir = globalenv())

pq_assert_equal(res_ok$status, "python_missing",
                "a valid input gets past the guard and fails later, on the runtime")
pq_assert_true(!identical(res_ok$status, "input_geometry_invalid"),
               "the guard did not reject a valid input")

# ============================================================
# G. No model means no score
# ============================================================
cat("\n== no fabrication ==\n")
no_model <- list(available = FALSE, status = "model_not_trained",
                 detail = "no .h5 weights in models/")
res_none <- pq_dnn_apply(rows, detail, paths, model_info = no_model)
pq_assert_true(isFALSE(res_none$ok), "without weights there is no result")
pq_assert_equal(res_none$status, "model_not_available",
                "the status is model_not_available")
pq_assert_equal(res_none$cause, "model_not_trained",
                "the specific cause is kept next to it")
pq_assert_true(all(is.na(res_none$rows$dnn_score)),
               "no score is fabricated when the model is missing")
pq_assert_true(all(res_none$rows$dnn_prediction == "unavailable" |
                     is.na(res_none$rows$dnn_prediction)),
               "no class is fabricated either")
pq_assert_true(all(res_none$rows$dnn_status == "model_not_available"),
               "every row records why there is no score")
pq_assert_equal(unique(res_none$rows$dnn_scope), "peak_group",
                "the scope is declared even when the model is missing")
pq_assert_contains(unique(res_none$rows$dnn_error)[1], "unavailable",
                   "the error text says the prediction is unavailable")

att_none <- pq_dnn_attach(rows, NULL, no_model)
pq_assert_true(all(att_none$dnn_status == "model_not_available"),
               "attach() with no prediction keeps the model status")
pq_assert_true(all(is.na(att_none$dnn_score)),
               "attach() with no prediction invents no score")

# ============================================================
# H. A scored row is labelled with what the score may be used for
# ============================================================
cat("\n== applicability ==\n")
pred <- data.frame(feature_id = "f1", dnn_prediction = 1, dnn_score = 0.93,
                   dnn_threshold = 0.5, dnn_input_status = "ok",
                   dnn_error = "", stringsAsFactors = FALSE)
att_approx <- pq_dnn_attach(rows, pred,
                            modifyList(model_64, list(input_approx = TRUE)))
pq_assert_equal(unique(att_approx$dnn_applicability),
                "approximate_resampled_input",
                "a resampled input is labelled as approximate")
pq_assert_equal(unique(att_approx$dnn_status), "ok", "a scored row says ok")

att_native <- pq_dnn_attach(rows, pred,
                            modifyList(model_64, list(input_approx = FALSE)))
pq_assert_equal(unique(att_native$dnn_applicability), "native_geometry",
                "a native input is labelled as native geometry")

# The verdict still must not touch the quality class.
pq_assert_true("quality_class" %in% names(pq_classify_rows(att_approx, NULL)),
               "the quality class column exists after attaching a DNN verdict")
pq_assert_equal(pq_classify_rows(rows, NULL)$quality_class,
                pq_classify_rows(att_approx, NULL)$quality_class,
                "a DNN prediction never rewrites a quality class")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

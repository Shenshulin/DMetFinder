# ============================================================
# test_16_dnn_integration — the DNN may not contaminate Peak Quality
# ============================================================
# The integration layer is where a tempting shortcut would live: take the
# model's "true peak" verdict and call it high_quality. These tests exist to
# make that shortcut fail.
#
# Also covered: a missing model must read as missing, not as a score of zero,
# and a feature the model never saw must read as unscored rather than as bad.
# ============================================================

local({
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", args[grep("^--file=", args)])
  here <- if (length(f) == 1) dirname(normalizePath(f, winslash = "/")) else getwd()
  source(file.path(here, "helpers.R"), encoding = "UTF-8")
})

pq_source_project()

# ------------------------------------------------------------
pq_section("model discovery is honest about absence")

# an empty models directory must produce model_not_trained, not an error
sandbox <- file.path(tempdir(), paste0("pqdnn_", as.integer(runif(1, 1, 1e6))))
dir.create(file.path(sandbox, "DNN_reference", "models"), recursive = TRUE,
           showWarnings = FALSE)

paths <- list(
  root = sandbox,
  base = file.path(sandbox, "DNN_reference"),
  model_dir = file.path(sandbox, "DNN_reference", "models"),
  matrices = file.path(sandbox, "DNN_reference", "processed_data", "matrices"),
  pred_dir = file.path(sandbox, "DNN_reference", "processed_data", "predictions"),
  python = file.path(sandbox, "DNN_reference", ".venv", "Scripts", "python.exe"),
  train_py = file.path(sandbox, "DNN_reference", "source_code", "pq_dnn_train.py"),
  pred_py = file.path(sandbox, "DNN_reference", "source_code", "pq_dnn_predict.py")
)

m0 <- pq_dnn_find_model(paths)
pq_assert_true(!isTRUE(m0$available), "no weights -> not available")
pq_assert_equal(m0$status, "model_not_trained", "and the status says exactly that")

msg <- pq_dnn_unavailable_message(paths)
pq_assert_true(!is.null(msg), "an unavailable message is produced")
pq_assert_equal(msg, "DNN prediction unavailable: model weights not available",
                "the message is the fixed string the UI and exports rely on")

# a weights file with no training log must not be trusted
writeLines("not really a model", file.path(paths$model_dir, "ghost.h5"))
m1 <- pq_dnn_find_model(paths)
pq_assert_true(!isTRUE(m1$available),
               "weights without a training log are not trusted")
pq_assert_equal(m1$status, "model_load_failed", "and the status says load failed")
pq_assert_contains(m1$detail, "training log",
                   "the reason names the missing sidecar")

# status table always has the two rows a UI needs
st <- pq_dnn_status_table(paths)
pq_assert_true("dnn_method_state" %in% st$item, "status table lists the method state")
pq_assert_equal(st$value[st$item == "dnn_method_state"], "unavailable",
                "method state is unavailable without weights")
pq_assert_contains(st$value[st$item == "quality_class_effect"], "never changes",
                   "status table states the DNN does not touch quality_class")

# ------------------------------------------------------------
pq_section("prediction run refuses to invent numbers")

no_model <- pq_dnn_run_predict(paths, model_path = NULL,
                               matrices_dir = paths$matrices,
                               out_dir = paths$pred_dir)
pq_assert_true(!isTRUE(no_model$ok), "no model -> no run")
pq_assert_equal(no_model$status, "model_not_trained", "and the reason is the model")
pq_assert_contains(no_model$detail, "model weights not available",
                   "detail repeats the fixed message")

# ------------------------------------------------------------
pq_section("attaching an empty result leaves every existing column alone")

rows <- data.frame(
  feature_id = c("f1", "f1", "f2"),
  sample_id = c("s1", "s2", "s1"),
  mz = c(100.1, 100.1, 200.2),
  peak_cor = c(0.91, 0.12, 0.55),
  SNR = c(40, 3, 12),
  presence = c("present", "present", "absent"),
  quality_class = c("high_quality", "likely_noise", "unknown"),
  quality_rule = c("R7", "R5", "R2"),
  quality_reason = c("a", "b", "c"),
  stringsAsFactors = FALSE
)
before <- rows

att0 <- pq_dnn_attach(rows, NULL, list(sha256 = NULL))
pq_assert_equal(att0$peak_cor, before$peak_cor, "peak_cor untouched")
pq_assert_equal(att0$SNR, before$SNR, "SNR untouched")
pq_assert_equal(att0$quality_class, before$quality_class,
                "quality_class untouched by an unavailable DNN")
pq_assert_equal(att0$quality_rule, before$quality_rule, "quality_rule untouched")
pq_assert_true(all(att0$dnn_input_status == "unavailable"),
               "every row is marked unavailable, not silently blank")
pq_assert_true(all(is.na(att0$dnn_score)), "no score is fabricated")
pq_assert_contains(att0$dnn_error[1], "model_not_available",
                   "the row-level error explains itself")
pq_assert_contains(att0$dnn_error[1], "unavailable",
                   "and stays readable for a human")

# ------------------------------------------------------------
pq_section("attaching real predictions still never writes quality_class")

# only f1 was scored; f2 is deliberately absent so the unscored path is covered
pred <- data.frame(
  feature_id = "f1",
  dnn_prediction = 1L,
  dnn_score = 0.93,
  dnn_threshold = 0.5,
  dnn_input_status = "ok",
  dnn_error = "",
  stringsAsFactors = FALSE
)
minfo <- list(sha256 = "abcdef0123456789", input_approx = FALSE)

att1 <- pq_dnn_attach(rows, pred, minfo)
pq_assert_equal(att1$quality_class, before$quality_class,
                "a 'true peak' prediction does NOT become high_quality")
pq_assert_equal(att1$quality_rule, before$quality_rule,
                "the rule that produced the class is unchanged")
pq_assert_equal(att1$dnn_score[1], 0.93, "the score is carried through")
pq_assert_equal(att1$dnn_score[2], 0.93, "both samples of a feature share it")
pq_assert_equal(att1$dnn_prediction[1], 1, "the model verdict is carried through")
pq_assert_equal(att1$dnn_model_version[1], "abcdef012345",
                "model version is stamped on every row")
pq_assert_equal(att1$dnn_source[1], "peak_group_dnn", "the source is named")
pq_assert_equal(att1$dnn_applicability[1], "native_geometry",
                "native geometry is declared when no resampling happened")

# a feature the model never saw must say so, and must not look like a bad peak
pq_assert_equal(att1$dnn_input_status[3], "not_in_model_run",
                "an unscored feature is marked, not defaulted")
pq_assert_true(is.na(att1$dnn_score[3]), "and has no score")

# ------------------------------------------------------------
pq_section("approximate input is declared, not hidden")

minfo_approx <- list(sha256 = "abcdef0123456789", input_approx = TRUE)
att2 <- pq_dnn_attach(rows, pred, minfo_approx)
pq_assert_equal(att2$dnn_applicability[1], "approximate_resampled_input",
                "a resampled 31x200 -> 64x64 input is flagged as approximate")
pq_assert_equal(att2$quality_class, before$quality_class,
                "approximate input still does not touch the class")

# ------------------------------------------------------------
pq_section("the two interpretation notes say what a score is and is not")

note <- pq_dnn_score_note()
pq_assert_contains(note, "not a calibrated probability",
                   "the note refuses to call the score a probability")
pq_assert_contains(note, "0.4", "the note names the author's filter threshold")
pq_assert_contains(note, "0.5", "the note names the author's apply threshold")

sep <- pq_dnn_class_separation_note()
pq_assert_contains(sep, "NOT mapped to high_quality",
                   "the separation note forbids the shortcut by name")
pq_assert_contains(sep, "stacked image across samples",
                   "and explains why: the model sees a group, the class sees one peak")

# ------------------------------------------------------------
pq_section("matrix export round-trips through the author's NA convention")

traces <- list(
  data.frame(rt = seq(1.40, 1.60, length.out = 40),
             intensity = 1000 * exp(-((seq(1.40, 1.60, length.out = 40) - 1.50)^2) / 8e-4),
             scan = 1:40)
)
built <- pq_dnn_build_matrix(traces, "s1", rt_min = 1.45, rt_max = 1.55,
                             mz_min = 100, mz_max = 101, params = pq_dnn_params())
pq_assert_true(isTRUE(built$ok), "matrix built for export")
batch <- list(images = list(built$matrix),
              meta = data.frame(feature_id = "feat A/1", stringsAsFactors = FALSE))

mdir <- file.path(sandbox, "matrices")
written <- pq_dnn_export_matrices(batch, mdir)
pq_assert_equal(length(written), 1L, "one matrix written")
pq_assert_true(all(grepl("^[A-Za-z0-9._-]+$", written)),
               "unsafe characters in a feature id are sanitised")

back <- as.matrix(utils::read.csv(file.path(mdir, paste0(written[1], ".csv")),
                                  header = FALSE))
pq_assert_equal(dim(back)[1], 31L, "31 rows survive the round trip")
pq_assert_equal(dim(back)[2], 200L, "200 columns survive the round trip")
back0 <- back; back0[is.na(back0)] <- 0
pq_assert_equal(back0, built$matrix, "zeros written as NA read back as zeros",
                tol = 1e-9)

# ------------------------------------------------------------
pq_section("the one-call path refuses to invent a prediction")

rows_min <- data.frame(
  feature_id = c("f1", "f1"),
  sample_id = c("S1", "S2"),
  mz = c(300.1, 300.1),
  input_rt = c(3.2, 3.2),
  quality_class = c("high_quality", "low_quality"),
  stringsAsFactors = FALSE)

no_model <- list(available = FALSE, status = "model_not_trained",
                 detail = "no .h5 weights in models/")

res1 <- pq_dnn_apply(rows_min, list(NULL, NULL), model_info = no_model)
pq_assert_true(isFALSE(res1$ok), "no model means ok = FALSE")
pq_assert_equal(res1$status, "model_not_available",
                "and reports the published token for missing weights")
pq_assert_equal(res1$cause, "model_not_trained",
                "while keeping the specific cause, so the fix is actionable")
pq_assert_true("dnn_score" %in% names(res1$rows), "the DNN columns still exist")
pq_assert_true(all(is.na(res1$rows$dnn_score)), "no score is fabricated")
pq_assert_true(all(res1$rows$dnn_source == "not_run"), "source says it did not run")
pq_assert_true(all(grepl("unavailable", res1$rows$dnn_error)),
               "every row carries the reason")
pq_assert_equal(res1$rows$quality_class, rows_min$quality_class,
                "the quality class is untouched even on failure")

res2 <- pq_dnn_apply(rows_min[0, ], list(), model_info = no_model)
pq_assert_true(isFALSE(res2$ok), "an empty table does not error out")
pq_assert_equal(res2$status, "no_rows", "and says so")

# a model that exists but produced nothing is a different status from "no model"
res3 <- pq_dnn_apply(rows_min, list(NULL, NULL),
                     model_info = list(available = TRUE, status = "available",
                                       sha256 = "deadbeef", path = "nope.h5"))
pq_assert_true(isFALSE(res3$ok), "a usable model with no traces is still not a score")
pq_assert_equal(res3$status, "no_usable_images",
                "the reason is the unusable image, not the model and not the export")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

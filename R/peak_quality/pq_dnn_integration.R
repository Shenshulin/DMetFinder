# Bridge between the Shiny/Peak Quality world and the Python DNN.
#
# Boundaries this file keeps:
#   * It never trains. Training is a separate, explicit action (pq_dnn_train.py).
#   * It never overwrites `peak_cor`, `SNR`, CPC metrics or `quality_class`.
#     The DNN writes its own columns and nothing else.
#   * It never turns a model verdict into one of the four quality classes.
#     A peak the model likes can still be tailing, fronting or badly bounded.
#   * When there is no model, it says so and stops. It does not fabricate a
#     score, and it does not treat a rendered peak-group image as a prediction.

# ------------------------------------------------------------
# Where things live
# ------------------------------------------------------------
# The Python environment deliberately lives OUTSIDE this project. TensorFlow
# ships headers whose paths run past the 260-character Windows limit as soon as
# they sit under a deep project directory, and this project's path is already
# long. `DNN_reference/.venv_path` holds the real location so the code stays
# portable: move the venv, edit one line.
pq_dnn_paths <- function(root = NULL) {
  if (is.null(root)) {
    root <- tryCatch(pq_proj_root(), error = function(e) getwd())
  }
  base <- file.path(root, "DNN_reference")

  python <- file.path(base, ".venv", "Scripts", "python.exe")
  ptr <- file.path(base, ".venv_path")
  if (file.exists(ptr)) {
    p <- trimws(readLines(ptr, warn = FALSE, encoding = "UTF-8")[1])
    if (!is.na(p) && nzchar(p)) {
      cand <- file.path(p, "Scripts", "python.exe")
      if (file.exists(cand)) python <- cand
    }
  }

  list(
    root      = root,
    base      = base,
    model_dir = file.path(base, "models"),
    matrices  = file.path(base, "processed_data", "matrices"),
    pred_dir  = file.path(base, "processed_data", "predictions"),
    python    = python,
    train_py  = file.path(base, "source_code", "pq_dnn_train.py"),
    pred_py   = file.path(base, "source_code", "pq_dnn_predict.py")
  )
}

# ------------------------------------------------------------
# Model discovery
# ------------------------------------------------------------
# A model is only "available" if the weights file exists AND the sidecar JSON
# written by the training script exists AND the two agree on the SHA-256. That
# is what stops a half-written or swapped file from being used silently.
pq_dnn_find_model <- function(paths = pq_dnn_paths(), tag = NULL) {
  if (!dir.exists(paths$model_dir)) {
    return(list(available = FALSE, status = "model_not_trained",
                detail = "no models directory"))
  }
  h5 <- list.files(paths$model_dir, pattern = "\\.h5$", full.names = TRUE)
  if (!is.null(tag)) h5 <- h5[basename(h5) == paste0(tag, ".h5")]
  if (length(h5) == 0L) {
    return(list(available = FALSE, status = "model_not_trained",
                detail = "no .h5 weights in models/"))
  }
  # newest first
  info <- file.info(h5)
  h5 <- h5[order(info$mtime, decreasing = TRUE)]
  pick <- h5[1]
  side <- sub("\\.h5$", "_train_log.json", pick)

  out <- list(available = FALSE, path = pick, sidecar = side,
              status = "model_load_failed", detail = "")

  if (!file.exists(side)) {
    out$detail <- "weights exist but the training log is missing, so the model version cannot be verified"
    return(out)
  }

  log <- tryCatch(
    jsonlite::fromJSON(side, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(log)) {
    out$detail <- "training log is unreadable"
    return(out)
  }

  recorded <- log$model_sha256
  actual <- pq_dnn_sha256(pick)
  if (!is.null(recorded) && !identical(tolower(recorded), tolower(actual))) {
    out$detail <- sprintf("weights do not match the training log (%s vs %s)",
                          substr(actual, 1, 12), substr(recorded, 1, 12))
    return(out)
  }

  ev <- log$evaluation
  out$available <- TRUE
  out$status <- "available"
  out$detail <- "weights verified against the training log"
  out$sha256 <- actual
  # jsonlite is asked for simplifyVector = FALSE so the log keeps its structure;
  # the consequence is that every scalar arrives as a length-1 list. Unwrap them
  # here, once, or every downstream `is.finite()` / `sprintf()` will choke.
  unl <- function(x) {
    if (is.null(x)) return(NULL)
    v <- suppressWarnings(unlist(x, use.names = FALSE))
    if (length(v) == 0L) NULL else v
  }
  out$trained_at <- unl(log$finished)
  out$seed <- unl(log$seed)
  out$input_shape <- unl(log$shapes$trainX)
  out$test_auc <- {
    a <- unl(ev$test$auc)
    if (is.null(a)) NA_real_ else as.numeric(a[1])
  }
  out$test_auc_cal <- {
    a <- unl(ev$cal$auc)
    if (is.null(a)) NA_real_ else as.numeric(a[1])
  }
  out$threshold_default <- 0.5
  out$tensorflow <- unl(log$tensorflow)
  out$keras <- unl(log$keras)
  out
}

pq_dnn_sha256 <- function(path) {
  if (!requireNamespace("digest", quietly = TRUE)) {
    # no digest: fall back to a size+mtime fingerprint and say so
    st <- file.info(path)
    return(sprintf("size-%s-mtime-%s", st$size, as.numeric(st$mtime)))
  }
  digest::digest(file = path, algo = "sha256")
}

# ------------------------------------------------------------
# Human-readable status block
# ------------------------------------------------------------
# This is what the UI shows instead of a score when there is nothing to show.
pq_dnn_status_table <- function(paths = pq_dnn_paths()) {
  m <- pq_dnn_find_model(paths)

  py_ok <- file.exists(paths$python)
  py_ver <- if (py_ok) {
    v <- tryCatch(system2(paths$python, "--version", stdout = TRUE,
                          stderr = TRUE), error = function(e) NA_character_)
    paste(v, collapse = " ")
  } else NA_character_

  data.frame(
    item = c("model_state", "model_path", "model_sha256", "trained_at",
             "training_seed", "test_auc", "python_runtime",
             "dnn_method_state", "quality_class_effect"),
    value = c(
      m$status,
      if (is.null(m$path)) "" else m$path,
      if (is.null(m$sha256)) "" else m$sha256,
      if (is.null(m$trained_at)) "" else as.character(m$trained_at),
      if (is.null(m$seed)) "" else as.character(m$seed),
      if (is.null(m$test_auc) || !is.finite(m$test_auc)) "" else sprintf("%.4f", m$test_auc),
      if (is.na(py_ver)) "not found" else py_ver,
      if (isTRUE(m$available)) "ready" else "unavailable",
      "none - the DNN never changes quality_class, peak_cor, SNR or CPC metrics"
    ),
    stringsAsFactors = FALSE
  )
}

pq_dnn_unavailable_message <- function(paths = pq_dnn_paths()) {
  m <- pq_dnn_find_model(paths)
  if (isTRUE(m$available)) return(NULL)
  if (identical(m$status, "model_not_trained")) {
    return("DNN prediction unavailable: model weights not available")
  }
  sprintf("DNN prediction unavailable: %s (%s)", m$status, m$detail)
}

# ------------------------------------------------------------
# Write peak-group matrices to disk
# ------------------------------------------------------------
# The Python side reads one CSV per window. We write them headerless with NA for
# zero, matching peakGroupImageMatrixAndPlot.R:497 so the files are byte-shape
# compatible with the author's.
pq_dnn_export_matrices <- function(batch, dir, params = pq_dnn_params()) {
  if (is.null(batch) || is.null(batch$images) || length(batch$images) == 0L) {
    return(character(0))
  }
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  written <- character(0)
  for (i in seq_along(batch$images)) {
    m <- batch$images[[i]]
    if (is.null(m)) next
    fid <- batch$meta$feature_id[i]
    # guard against path traversal from a feature id
    safe <- gsub("[^A-Za-z0-9._-]", "_", fid)
    if (!nzchar(safe)) safe <- sprintf("feature_%04d", i)

    if (isTRUE(params$zero_as_na)) {
      m[m == 0] <- NA_real_
    }
    utils::write.table(m, file = file.path(dir, paste0(safe, ".csv")),
                       sep = ",", row.names = FALSE, col.names = FALSE,
                       na = "NA", quote = FALSE)
    written <- c(written, safe)
  }
  written
}

# ------------------------------------------------------------
# Run the Python predictor
# ------------------------------------------------------------
pq_dnn_run_predict <- function(paths = pq_dnn_paths(), model_path,
                               matrices_dir, out_dir,
                               threshold = 0.5, timeout = 1800) {
  # Order matters. A missing model is the root cause, so it is reported before
  # anything about the interpreter: otherwise a user without weights would be
  # told to install Python, which would not help.
  if (missing(model_path) || is.null(model_path) || !file.exists(model_path)) {
    return(list(ok = FALSE, status = "model_not_trained",
                detail = "DNN prediction unavailable: model weights not available"))
  }
  if (!file.exists(paths$python)) {
    return(list(ok = FALSE, status = "python_missing",
                detail = paste("no python at", paths$python)))
  }
  if (!file.exists(paths$pred_py)) {
    return(list(ok = FALSE, status = "script_missing",
                detail = paste("no predictor at", paths$pred_py)))
  }

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  args <- c(shQuote(paths$pred_py),
            "--model", shQuote(model_path),
            "--matrices", shQuote(matrices_dir),
            "--out", shQuote(out_dir),
            "--threshold", format(threshold))
  cmd <- paste(c(shQuote(paths$python), args), collapse = " ")

  res <- tryCatch(
    system(cmd, intern = TRUE, ignore.stdout = FALSE, ignore.stderr = FALSE,
           timeout = timeout),
    error = function(e) structure(conditionMessage(e), class = "cmd_error")
  )

  csv <- file.path(out_dir, "dnn_predictions.csv")
  if (inherits(res, "cmd_error") || !file.exists(csv)) {
    return(list(ok = FALSE, status = "prediction_failed",
                detail = paste(c(utils::head(res, 20)), collapse = "\n"),
                log = res))
  }

  pred <- tryCatch(
    utils::read.csv(csv, stringsAsFactors = FALSE,
                    colClasses = c(feature_id = "character")),
    error = function(e) NULL
  )
  if (is.null(pred)) {
    return(list(ok = FALSE, status = "prediction_unreadable",
                detail = "predictions CSV could not be parsed", log = res))
  }

  meta <- tryCatch(
    jsonlite::fromJSON(file.path(out_dir, "dnn_predict_meta.json"),
                       simplifyVector = TRUE),
    error = function(e) NULL
  )

  list(ok = TRUE, status = "ok", predictions = pred, meta = meta, log = res)
}

# ------------------------------------------------------------
# Attach results to the Peak Quality table
# ------------------------------------------------------------
# One row per feature, so the join is on feature_id only. Every existing column
# is preserved; the DNN adds new ones and touches nothing else.
#
# `dnn_scope` is written on EVERY row, including the unavailable ones, and it is
# always "peak_group". The DNN produces one verdict per aligned peak group, so
# attaching it to a feature x sample row does not turn it into a per-sample
# probability: the same score is repeated for every sample of that feature by
# construction, and the scope column is what says so.
PQ_DNN_COLUMNS <- c(
  "dnn_status", "dnn_scope", "dnn_model_version", "dnn_input_status",
  "dnn_prediction", "dnn_score", "dnn_threshold", "dnn_source",
  "dnn_applicability", "dnn_error"
)

pq_dnn_attach <- function(rows, pred, model_info = NULL) {
  if (is.null(rows) || nrow(rows) == 0L) return(rows)

  new_cols <- PQ_DNN_COLUMNS
  n <- nrow(rows)

  if (is.null(pred) || nrow(pred) == 0L) {
    for (cc in new_cols) rows[[cc]] <- NA
    # The published token, plus the specific cause so the user knows which
    # action fixes it (train / re-download / fix the path).
    cause <- if (is.null(model_info$status)) "model_not_trained" else
      as.character(model_info$status)
    rows$dnn_status <- rep("model_not_available", n)
    rows$dnn_scope <- rep("peak_group", n)
    rows$dnn_model_version <- rep(
      if (is.null(model_info$sha256)) "" else substr(model_info$sha256, 1, 12),
      n)
    rows$dnn_input_status <- rep("unavailable", n)
    rows$dnn_source <- rep("not_run", n)
    rows$dnn_applicability <- rep("none", n)
    rows$dnn_error <- rep(
      sprintf("DNN prediction unavailable: model_not_available (%s)", cause), n)
    return(rows)
  }

  idx <- match(as.character(rows$feature_id), as.character(pred$feature_id))

  rows$dnn_status <- ifelse(is.na(idx), "not_in_model_run", "ok")
  rows$dnn_scope <- rep("peak_group", n)
  rows$dnn_model_version <- rep(
    if (is.null(model_info$sha256)) "" else substr(model_info$sha256, 1, 12),
    n)
  rows$dnn_input_status <- ifelse(is.na(idx), "not_in_model_run",
                                  pred$dnn_input_status[idx])
  rows$dnn_prediction <- ifelse(is.na(idx), NA, pred$dnn_prediction[idx])
  rows$dnn_score <- ifelse(is.na(idx), NA_real_, suppressWarnings(
    as.numeric(pred$dnn_score[idx])))
  rows$dnn_threshold <- ifelse(is.na(idx), NA_real_, suppressWarnings(
    as.numeric(pred$dnn_threshold[idx])))
  rows$dnn_source <- "peak_group_dnn"
  rows$dnn_error <- ifelse(is.na(idx), "feature not scored by the model run",
                           pred$dnn_error[idx])

  # A group whose input failed the geometry guard, or whose matrix the predictor
  # rejected, is not a prediction. Say so in the status column instead of
  # leaving a score that a reader would trust.
  bad_input <- !is.na(idx) & !is.na(rows$dnn_input_status) &
    rows$dnn_input_status != "ok"
  if (any(bad_input)) {
    rows$dnn_status[bad_input] <- "input_invalid"
  }
  no_score <- !is.na(idx) & is.na(rows$dnn_score)
  rows$dnn_status[no_score & !bad_input] <- "no_score"

  # Applicability is about what the score may be used for, and it is decided by
  # the input geometry, not by the score. A native 31x200 matrix fed to a 64x64
  # model is a resampled approximation and must say so.
  #
  # Note: the status comparison has to be elementwise. `identical()` on a vector
  # is always FALSE, which would have marked every scored row invalid.
  hit <- !is.na(idx)
  app <- rep("not_applicable", n)
  if (any(hit)) {
    st <- as.character(pred$dnn_input_status[idx[hit]])
    app[hit] <- ifelse(
      !identical(st, character(0)) & st != "ok", "input_invalid",
      if (isTRUE(model_info$input_approx)) "approximate_resampled_input"
      else "native_geometry")
  }
  rows$dnn_applicability <- app
  rows
}

# ------------------------------------------------------------
# One call: build -> export -> predict -> attach
# ------------------------------------------------------------
# Everything the UI needs, in the order that keeps the approximation visible.
#
# The batch has to be built with the *model's* geometry (64x64 for the published
# weights) while the author's R code natively produces 31x200. That conversion
# is an approximation with no authoritative definition, so it happens here and
# every affected row carries `dnn_applicability = approximate_resampled_input`
# plus the native size in the batch metadata.
#
# Failure is never a thrown error and never a zero score. If there is no model,
# no Python, or the predictor dies, the rows come back with the DNN columns
# present and explicitly marked unavailable, and `result$ok` is FALSE with a
# reason. That is what stops a silent column of NAs from being read as "bad
# peaks".
pq_dnn_apply <- function(rows, detail, paths = pq_dnn_paths(),
                         model_info = NULL, threshold = NULL,
                         seed = 1L, progress = NULL,
                         run_tag = NULL) {
  if (is.null(model_info)) model_info <- pq_dnn_find_model(paths)
  thr <- if (is.null(threshold)) 0.5 else as.numeric(threshold)

  fail <- function(status, detail_msg) {
    list(ok = FALSE, status = status, detail = detail_msg,
         rows = pq_dnn_attach(rows, NULL, model_info),
         batch = NULL, predictions = NULL, model = model_info)
  }

  if (is.null(rows) || nrow(rows) == 0L) {
    return(fail("no_rows", "no peaks to score"))
  }
  if (!isTRUE(model_info$available)) {
    # The published token for "no usable weights" is model_not_available. The
    # specific cause (model_not_trained / model_load_failed / hash mismatch) is
    # kept in `cause` and in the message, because "train one" and "your weights
    # are corrupt" are different actions.
    out <- fail("model_not_available", pq_dnn_unavailable_message(paths))
    out$cause <- model_info$status
    out$detail <- sprintf("%s [cause: %s]", out$detail,
                          model_info$status %||% "unknown")
    return(out)
  }

  params <- pq_dnn_params_for_model(model_info)
  batch <- pq_dnn_batch(rows, detail, params = params, seed = seed,
                        progress = progress)
  if (batch$n_window == 0L) {
    return(fail("no_windows", "no peak group was formed from these rows"))
  }
  # A group can exist and still yield no image (too few scans, no signal, a
  # trace that could not be joined). That is a different failure from "no groups
  # at all" and must not be reported as an export problem.
  usable <- sum(!vapply(batch$images, is.null, logical(1)))
  if (usable == 0L) {
    reasons <- unique(batch$meta$image_status[!batch$meta$image_ok])
    return(fail("no_usable_images",
                paste0("no peak group produced a usable image (",
                       paste(reasons, collapse = ", "), ")")))
  }

  # Geometry / orientation guard. A transposed or wrongly sized image does not
  # make a Keras model complain - it returns a confident-looking low score.
  # Refusing here is the only way to keep that failure from being published as
  # a result. Nothing is exported or predicted when the contract is violated.
  guard <- pq_dnn_validate_batch(batch, model_info)
  if (!isTRUE(guard$ok)) {
    out <- fail("input_geometry_invalid",
                paste0("DNN input rejected: ", guard$reason,
                       " (nothing was predicted)"))
    out$batch <- batch
    out$guard <- guard
    return(out)
  }

  tag <- run_tag %||% format(Sys.time(), "%Y%m%d_%H%M%S")
  mdir <- file.path(paths$matrices, tag)
  odir <- file.path(paths$pred_dir, tag)
  written <- pq_dnn_export_matrices(batch, mdir, params = params)
  if (length(written) == 0L) {
    return(fail("export_failed", "no matrix could be written"))
  }

  res <- pq_dnn_run_predict(paths, model_path = model_info$path,
                            matrices_dir = mdir, out_dir = odir,
                            threshold = thr)
  if (!isTRUE(res$ok)) {
    out <- fail(res$status, res$detail)
    out$batch <- batch
    return(out)
  }

  approx <- any(batch$meta$image_resampled %in% TRUE)
  mi <- model_info
  mi$input_approx <- approx

  list(ok = TRUE, status = "ok", detail = "",
       rows = pq_dnn_attach(rows, res$predictions, mi),
       batch = batch, predictions = res$predictions, meta = res$meta,
       model = mi, matrices_dir = mdir, prediction_dir = odir,
       threshold = thr, input_approx = approx, guard = guard)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a

# ------------------------------------------------------------
# Interpretation text, not a verdict
# ------------------------------------------------------------
pq_dnn_score_note <- function() {
  paste(
    "dnn_score is the model's output for the 'acceptable peak' class.",
    "It is a model score, not a calibrated probability: the author never",
    "calibrated the network, so a score of 0.9 does not mean 90% of such",
    "peaks are acceptable. It is meaningful for ranking within a run, and",
    "the author's own threshold choices differ (0.5 when applying,",
    "0.4 when filtering, closest-to-top-left when tuning)."
  )
}

pq_dnn_class_separation_note <- function() {
  paste(
    "The DNN answers a different question than the four quality classes.",
    "Its label is 'the peak group as a whole is acceptable', judged on a",
    "stacked image across samples. quality_class answers 'this single",
    "(feature, sample) peak is usable', from shape metrics on one trace.",
    "A true-peak prediction is therefore NOT mapped to high_quality: a real",
    "peak can still tail, front or be badly bounded."
  )
}

# ------------------------------------------------------------
# Provenance block for exports
# ------------------------------------------------------------
# Appended to the Peak Quality provenance so a reader of the XLSX can tell which
# DNN, trained on what, produced the dnn_* columns — or why they are empty.
pq_dnn_provenance_lines <- function(paths = pq_dnn_paths()) {
  m <- pq_dnn_find_model(paths)

  head <- c(
    "DNN method                 : Kantz et al. 2019, Deep Neural Networks for",
    "                             Classification of LC-MS Spectral Peaks",
    "  paper doi                : 10.1021/acs.analchem.9b02983",
    "  code                     : github.com/JainLab/Manuscript-DNNs-for-Classification-of-LCMS-Peaks",
    "  code commit              : 94237bf45e790a8332e45a2f2842116f46a18aa9",
    "  code license             : Univ. of California, research/non-profit only",
    "  data                     : MassIVE MSV000084186 (CC0 1.0)",
    paste0("  dnn state                : ", m$status)
  )

  if (!isTRUE(m$available)) {
    return(c(head,
      paste0("  detail                   : ", m$detail),
      "  weights                  : none - no .h5 in DNN_reference/models",
      "  note                     : a rendered peak-group image is not a prediction",
      "  effect on results        : dnn_* columns are empty; nothing else changes"
    ))
  }

  c(head,
    paste0("  weights file             : ", m$path),
    paste0("  weights sha256           : ", m$sha256),
    paste0("  trained at               : ", m$trained_at),
    paste0("  training seed            : ", m$seed),
    paste0("  tensorflow / keras       : ", m$tensorflow),
    paste0("  test AUC (own split)     : ",
           if (is.finite(m$test_auc)) sprintf("%.4f", m$test_auc) else "NA"),
    "  score meaning            : model output for the acceptable-peak class;",
    "                             NOT a calibrated probability",
    "  threshold default        : 0.5 (ApplyPeakPredictionModel.R); the author's",
    "                             filterOutBadPeaks.R uses 0.4 and tuning uses",
    "                             the closest-to-top-left ROC point",
    paste0("  input geometry           : ",
           if (is.null(m$input_shape)) "unknown" else
             paste(m$input_shape, collapse = " x ")),
    "  geometry source          : peakGroupImageMatrixAndPlot.R (31 rows x 200",
    "                             slices); resampling to the model grid is an",
    "                             approximation, flagged per row as",
    "                             dnn_applicability = approximate_resampled_input",
    "  unit of analysis         : one aligned peak group (all samples of a",
    "                             feature), not a single (feature, sample) peak",
    "  effect on results        : none - dnn_* never alters quality_class,",
    "                             peak_cor, SNR or any CPC metric"
  )
}

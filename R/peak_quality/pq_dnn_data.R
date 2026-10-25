# Peak-group image construction for the DNN, ported from the author's R code.
#
# Source of truth:  Manuscript-DNNs-for-Classification-of-LCMS-Peaks,
#                   commit 94237bf, peakGroupImageMatrixAndPlot.R
#                   functions GenWindowTable / InterpToSlices / PeakGroupMatrix
#
# Why this file exists
# --------------------
# The author's DNN does not look at one peak. It looks at a *peak group*: the
# XIC of the same feature across many samples, stacked as rows of an image, plus
# one extra row that marks where the peak window sits. This file builds exactly
# that image. It is deliberately a line-by-line port so that the geometry the
# model sees is the geometry the author trained on, not a lookalike.
#
# Everything the author hard-codes is a named parameter here, and
# pq_dnn_params() returns the author's values as defaults. If you change one,
# the provenance record will show it.

# Author defaults, transcribed from the User Input block of
# peakGroupImageMatrixAndPlot.R (lines 30-64).
pq_dnn_params <- function() {
  list(
    # window width in retention-time units around the window midpoint
    rt_duration = 1,
    # minimum scan separation; numRtSlices = floor(rt_duration / min_rt_sep)
    min_rt_sep = 0.005,
    # maximum number of sample rows in the image
    max_signal_files = 30,
    # share of those rows taken from the highest-intensity samples
    prop_high_peaks = 0.7,
    # the matrix is divided by its global maximum
    global_scale = TRUE,
    # export replaces 0 with NA to save space; the reader puts 0 back
    zero_as_na = TRUE,
    # figure height of the 64x64 model the paper reports; the native R matrices
    # are 31 x 200, so this stays NULL unless a caller explicitly asks to
    # resample (see pq_dnn_resample_to())
    model_height = NULL,
    model_width = NULL
  )
}

# Params adjusted to whatever geometry a trained model expects.
#
# `model_info$input_shape` is the shape read from the training log, e.g.
# c(1304, 64, 64, 1). Position 2 and 3 are the image height and width; position
# 1 is the number of training images and must not be mistaken for geometry.
# When the shape is missing or malformed the params are returned untouched,
# which means the native 31x200 matrix will reach the predictor and be rejected
# on a shape mismatch — loudly, rather than being silently stretched.
pq_dnn_params_for_model <- function(model_info, params = pq_dnn_params()) {
  shp <- model_info$input_shape
  if (is.null(shp) || length(shp) < 3L) return(params)
  h <- suppressWarnings(as.integer(shp[2]))
  w <- suppressWarnings(as.integer(shp[3]))
  if (is.na(h) || is.na(w) || h < 1L || w < 1L) return(params)
  params$model_height <- h
  params$model_width <- w
  params
}

# ---------------------------------------------------------------
# Retention-time grid
# ---------------------------------------------------------------
# The author centres a fixed-width window on the window midpoint, not on the
# peak apex, and does not use the window width itself:
#   windRtMid  <- (windRtMax + windRtMin) / 2
#   rtSliceStart <- windRtMid - RtDur/2 ; rtSliceEnd <- windRtMid + RtDur/2
#   vect.RtSlicePoints <- round(seq(start, end, length.out = numRtSlices), 4)
pq_dnn_rt_grid <- function(rt_min, rt_max, params = pq_dnn_params()) {
  mid <- (rt_max + rt_min) / 2
  n <- floor(params$rt_duration / params$min_rt_sep)
  if (!is.finite(n) || n < 1) {
    stop("pq_dnn_rt_grid: rt_duration / min_rt_sep must be >= 1", call. = FALSE)
  }
  round(seq(from = mid - params$rt_duration / 2,
            to   = mid + params$rt_duration / 2,
            length.out = n), 4)
}

# ---------------------------------------------------------------
# One sample row
# ---------------------------------------------------------------
# InterpToSlices(): interpolate the sample's XIC onto the grid with rule = 2
# (outside the observed range, hold the nearest endpoint instead of returning
# NA), then force non-positive retention times to zero. Fewer than three points
# cannot describe a peak, so the whole row becomes zero rather than a spike.
pq_dnn_row_from_xic <- function(rt, intensity, grid) {
  ok <- is.finite(rt) & is.finite(intensity)
  rt <- rt[ok]; intensity <- intensity[ok]
  if (length(rt) <= 2L) return(rep(0, length(grid)))

  o <- order(rt)
  rt <- rt[o]; intensity <- intensity[o]

  y <- stats::approx(x = rt, y = intensity, xout = grid,
                     method = "linear", n = NULL, rule = 2,
                     ties = mean)$y
  # the author zeroes anything at a non-positive retention time
  y[grid <= 0] <- 0
  y[!is.finite(y)] <- 0
  as.numeric(y)
}

# ---------------------------------------------------------------
# Member selection
# ---------------------------------------------------------------
# PeakGroupMatrix() keeps only samples whose max intensity in the window is > 0,
# then, if there are more samples than the image has rows, takes the tallest
# `maxLinesHigh` and a *random* sample of `maxLinesOther` from the rest.
#
# The randomness is the author's. We make it seedable and record the seed, so a
# result can be reproduced; the author used no seed at all.
pq_dnn_select_members <- function(max_intensity, params = pq_dnn_params(),
                                  seed = 1L) {
  keep <- which(is.finite(max_intensity) & max_intensity > 0)
  if (length(keep) == 0L) return(integer(0))

  cap <- params$max_signal_files
  if (length(keep) <= cap) return(keep)

  n_high <- ceiling(cap * params$prop_high_peaks)
  n_other <- cap - n_high

  ord <- keep[order(-max_intensity[keep])]
  high <- ord[seq_len(n_high)]
  rest <- ord[-seq_len(n_high)]

  old <- if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
    get(".Random.seed", envir = globalenv())
  } else NULL
  on.exit({
    if (is.null(old)) {
      if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
        rm(".Random.seed", envir = globalenv())
      }
    } else {
      assign(".Random.seed", old, envir = globalenv())
    }
  }, add = TRUE)
  set.seed(seed)

  pick <- if (n_other > 0 && length(rest) > 0) {
    rest[sample.int(length(rest), size = min(n_other, length(rest)))]
  } else integer(0)

  as.integer(c(high, pick))
}

# ---------------------------------------------------------------
# One window -> one image
# ---------------------------------------------------------------
# `traces` is a list of per-sample XIC data frames, each with rt/intensity and a
# `sample_id`. Returns the author's matrix plus a row map so nothing about which
# sample became which row is lost.
pq_dnn_build_matrix <- function(traces, sample_ids, rt_min, rt_max,
                                mz_min, mz_max,
                                params = pq_dnn_params(), seed = 1L) {
  grid <- pq_dnn_rt_grid(rt_min, rt_max, params)
  n_col <- length(grid)

  if (length(traces) == 0L) {
    return(list(ok = FALSE, reason = "no_traces", matrix = NULL,
                grid = grid, rows = character(0), n_signal = 0L))
  }

  # max intensity per sample inside the window, as the author's max-intensity
  # table would have supplied it
  max_int <- vapply(seq_along(traces), function(i) {
    tr <- traces[[i]]
    if (is.null(tr) || nrow(tr) == 0L) return(NA_real_)
    inw <- tr$rt >= rt_min & tr$rt <= rt_max
    if (!any(inw)) return(NA_real_)
    suppressWarnings(max(tr$intensity[inw], na.rm = TRUE))
  }, numeric(1))
  max_int[!is.finite(max_int)] <- NA_real_

  sel <- pq_dnn_select_members(max_int, params, seed = seed)
  if (length(sel) == 0L) {
    return(list(ok = FALSE, reason = "no_signal_in_window", matrix = NULL,
                grid = grid, rows = character(0), n_signal = 0L))
  }

  # No m/z refiltering: xic_extract already collapsed to the m/z window, so the
  # author's `mz %between% c(mzMin, mzMax)` step is a no-op here. Recorded in
  # the provenance rather than silently skipped.
  rows <- vapply(sel, function(i) {
    pq_dnn_row_from_xic(traces[[i]]$rt, traces[[i]]$intensity, grid)
  }, numeric(n_col))
  if (is.null(dim(rows))) rows <- matrix(rows, nrow = 1L)
  rows <- t(rows)                       # samples in rows, RT slices in columns

  # pad to the full height with zero rows
  n_fill <- params$max_signal_files - nrow(rows)
  if (n_fill > 0) {
    rows <- rbind(rows, matrix(0, nrow = n_fill, ncol = n_col))
  }

  # global maximum scaling
  scale_by <- if (isTRUE(params$global_scale)) max(rows) else 1
  if (!is.finite(scale_by) || scale_by <= 0) scale_by <- 1
  rows <- rows / scale_by

  # the window marker row: 1 inside [rt_min, rt_max], else 0
  marker <- as.numeric(grid >= rt_min & grid <= rt_max)
  mat <- rbind(rows, marker)

  list(
    ok = TRUE, reason = NA_character_, matrix = mat, grid = grid,
    rows = as.character(sample_ids[sel]),
    n_signal = length(sel), scale_by = scale_by
  )
}

# ---------------------------------------------------------------
# Optional resampling onto a fixed square grid
# ---------------------------------------------------------------
# The paper's model takes 64x64. The author's R pipeline produces 31x200, and
# *no code in the repository converts one into the other*. This function is
# therefore a deliberate, documented approximation, NOT a reconstruction of the
# author's preprocessing. Anything that uses it must be marked as an
# approximate input, and its predictions must not be presented as the paper's
# result.
pq_dnn_resample_to <- function(mat, out_h, out_w) {
  if (is.null(dim(mat)) || nrow(mat) < 1L || ncol(mat) < 1L) return(mat)
  ih <- nrow(mat); iw <- ncol(mat)
  if (ih == out_h && iw == out_w) return(mat)

  # nearest-neighbour on a uniform index mapping; keeps values in [0, 1] and
  # keeps the marker row usable as a marker
  ri <- pmin(ih, pmax(1L, round(seq(1, ih, length.out = out_h))))
  ci <- pmin(iw, pmax(1L, round(seq(1, iw, length.out = out_w))))
  mat[ri, ci, drop = FALSE]
}

# Convert the author's native layout into the layout the trained model expects.
#
# The two layouts are *transposed* relative to each other, which is easy to miss
# and was in fact missed on the first attempt:
#
#   native (peakGroupImageMatrixAndPlot.R) : rows = samples (+ marker last row),
#                                            cols = 200 retention-time slices
#   model  (.mat, verified by inspecting all 2770 images):
#                                            rows = 64 retention-time slices,
#                                            cols = 63 samples + marker in the
#                                            LAST column (1304/1304 images)
#
# The marker position is the evidence, and it is checked rather than assumed:
# in every one of the 1304 training images the last *column* is purely binary
# while no last *row* is. Resampling the native matrix straight to 64x64 keeps
# samples on the wrong axis; transposing the real test images drops the model's
# AUC from 0.9867 to 0.8755, which confirms the model is orientation-sensitive.
#
# The retention-time axis is compressed by index (200 -> 64). The sample axis is
# NOT compressed or interpolated: samples keep their identity, the first
# (out_w - 1) columns are used, and any remaining columns are left at zero,
# which reads as "this sample had no signal here". Padding is honest; inventing
# interpolated samples would not be.
pq_dnn_to_model_geometry <- function(mat, out_h, out_w) {
  if (is.null(dim(mat)) || nrow(mat) < 2L || ncol(mat) < 1L) return(mat)

  nr <- nrow(mat); nc <- ncol(mat)
  marker <- as.numeric(mat[nr, ])                 # native marker row
  samples <- mat[seq_len(nr - 1L), , drop = FALSE] # 30 sample rows

  # retention time: 200 -> out_h by index, applied to samples and marker alike
  ci <- pmin(nc, pmax(1L, round(seq(1, nc, length.out = out_h))))
  samples <- samples[, ci, drop = FALSE]
  marker <- marker[ci]

  out <- matrix(0, nrow = out_h, ncol = out_w)
  # sample count lives on the rows of `samples`, not the columns
  n_s <- min(nrow(samples), out_w - 1L)
  if (n_s > 0L) {
    # transpose: sample rows become sample columns
    out[, seq_len(n_s)] <- t(samples[seq_len(n_s), , drop = FALSE])
  }
  out[, out_w] <- marker
  out
}

# ---------------------------------------------------------------
# Batch driver
# ---------------------------------------------------------------
# `rows`   : the pipeline's result table, one row per (feature, sample)
# `detail` : the pipeline's parallel list of extracted traces; element i belongs
#            to row i. Elements can be NULL (the pipeline skips a few branches),
#            and those rows cannot contribute a trace.
#
# Nothing is re-read from disk: the XIC the pipeline already extracted is the
# only input, so a peak group costs a few hundred floats, not a file parse.
pq_dnn_batch <- function(rows, detail, params = pq_dnn_params(), seed = 1L,
                         progress = NULL) {
  empty <- list(images = list(), meta = data.frame(
    feature_id = character(0), n_samples = integer(0), n_signal = integer(0),
    rt_min = numeric(0), rt_max = numeric(0), rt_bounds_from = character(0),
    image_ok = logical(0), image_status = character(0),
    image_rows = integer(0), image_cols = integer(0),
    image_native_rows = integer(0), image_native_cols = integer(0),
    image_resampled = logical(0),
    stringsAsFactors = FALSE
  ), n_window = 0L)

  if (is.null(rows) || nrow(rows) == 0L || is.null(detail) ||
      length(detail) == 0L) {
    return(empty)
  }

  n <- min(nrow(rows), length(detail))
  if (n == 0L) return(empty)

  feat_key <- as.character(rows$feature_id[seq_len(n)])
  samp_key <- as.character(rows$sample_id[seq_len(n)])
  # rows with no trace cannot join a peak group, but they are still counted so
  # the group knows how many samples were expected
  has_trace <- vapply(detail[seq_len(n)], function(d) {
    !is.null(d) && !is.null(d$xic) && is.data.frame(d$xic) && nrow(d$xic) > 0L
  }, logical(1))

  groups <- split(seq_len(n), feat_key)
  keys <- names(groups)

  images <- vector("list", length(keys))
  meta <- vector("list", length(keys))

  for (k in seq_along(keys)) {
    idx <- groups[[k]]
    tidx <- idx[has_trace[idx]]
    first_row <- idx[1]

    # Window bounds. The author reads them from the MZmine peak table
    # (windRtMin/windRtMax). We do not have that table, so we take the union of
    # the detected peak edges for this feature, and fall back to the input RT
    # when no edge was detected. Which one was used is recorded per group, so a
    # reader can tell an edge-based window from a fallback.
    starts <- vapply(tidx, function(i) {
      p <- detail[[i]]$peak
      if (is.null(p) || is.null(p$start_rt) || !is.finite(p$start_rt)) NA_real_
      else as.numeric(p$start_rt)
    }, numeric(1))
    ends <- vapply(tidx, function(i) {
      p <- detail[[i]]$peak
      if (is.null(p) || is.null(p$end_rt) || !is.finite(p$end_rt)) NA_real_
      else as.numeric(p$end_rt)
    }, numeric(1))

    rt_in <- as.numeric(rows$input_rt[first_row])
    if (length(starts) > 0L && any(is.finite(starts)) && any(is.finite(ends))) {
      rt_min <- min(starts, na.rm = TRUE)
      rt_max <- max(ends, na.rm = TRUE)
      bounds_from <- "detected_peak_edges"
    } else {
      rt_min <- rt_in - params$rt_duration / 2
      rt_max <- rt_in + params$rt_duration / 2
      bounds_from <- "input_rt_fallback"
    }
    if (!is.finite(rt_min) || !is.finite(rt_max) || rt_max <= rt_min) {
      rt_min <- rt_in
      rt_max <- rt_in + params$rt_duration
      bounds_from <- "input_rt_fallback"
    }

    traces <- lapply(tidx, function(i) detail[[i]]$xic)
    built <- pq_dnn_build_matrix(
      traces = traces, sample_ids = samp_key[tidx],
      rt_min = rt_min, rt_max = rt_max,
      params = params, seed = seed
    )

    # NB: `images[[k]] <- NULL` would *delete* the element and shorten the list,
    # so a later k would index out of bounds. `images[k] <- list(x)` stores NULL
    # in place instead.
    images[k] <- list(if (isTRUE(built$ok)) built$matrix else NULL)
    meta[[k]] <- data.frame(
      feature_id = keys[k],
      n_samples = length(idx),
      n_signal = built$n_signal,
      rt_min = rt_min, rt_max = rt_max,
      rt_bounds_from = bounds_from,
      image_ok = isTRUE(built$ok),
      image_status = if (isTRUE(built$ok)) "ok" else built$reason,
      image_rows = if (isTRUE(built$ok)) nrow(built$matrix) else NA_integer_,
      image_cols = if (isTRUE(built$ok)) ncol(built$matrix) else NA_integer_,
      image_native_rows = if (isTRUE(built$ok)) nrow(built$matrix) else NA_integer_,
      image_native_cols = if (isTRUE(built$ok)) ncol(built$matrix) else NA_integer_,
      image_resampled = FALSE,
      stringsAsFactors = FALSE
    )

    # Resampling to the model grid, only when a caller explicitly asked for it
    # by naming the model's geometry. The native matrix is what the author's R
    # code produces (31x200); the model was trained on 64x64, and nothing in the
    # public material says how the author got from one to the other. Doing it
    # here keeps the approximation visible: the row is flagged, the native size
    # is kept alongside, and `image_rows` becomes the size actually scored.
    if (!is.null(images[[k]]) &&
        !is.null(params$model_height) && !is.null(params$model_width)) {
      want_h <- as.integer(params$model_height)
      want_w <- as.integer(params$model_width)
      if (length(want_h) == 1L && length(want_w) == 1L &&
          is.finite(want_h) && is.finite(want_w) && want_h > 0L && want_w > 0L &&
          (nrow(images[[k]]) != want_h || ncol(images[[k]]) != want_w)) {
        # transpose into the model's layout, not a plain 2-D resize
        images[[k]] <- pq_dnn_to_model_geometry(images[[k]], want_h, want_w)
        meta[[k]]$image_resampled <- TRUE
        meta[[k]]$image_rows <- nrow(images[[k]])
        meta[[k]]$image_cols <- ncol(images[[k]])
      }
    }

    if (is.function(progress)) progress(k, length(keys))
  }

  list(images = images, meta = do.call(rbind, meta), n_window = length(keys))
}

# ---------------------------------------------------------------
# Geometry / orientation guard
# ---------------------------------------------------------------
# A peak-group image that is transposed or the wrong size does not make the
# model complain: it returns a *low score* with full confidence. That failure
# mode is silent and it is exactly what happened on the first integration
# attempt (three clean synthetic peaks scored 0.41-0.46 because samples were on
# the wrong axis). A wrong answer that looks like an answer is worse than an
# error, so the contract is checked explicitly before anything is predicted and
# a violation aborts the run.
#
# The checks, and what each one catches:
#   1. shape          - the image is not the size the model was built for.
#   2. marker column  - in the .mat every one of the 2770 images has a purely
#                       binary LAST COLUMN. If the last column is not binary but
#                       the last row is, the matrix is transposed.
#   3. marker content - the marker must contain at least one 1; an all-zero
#                       marker means the window fell outside the RT grid.
#   4. value range    - the author divides by the global maximum, so every cell
#                       lies in [0, 1]. A cell outside that range means the
#                       scaling step was skipped or applied twice.
#   5. signal         - an all-zero image is not a peak group; it is a failed
#                       extraction that should be reported as such.
pq_dnn_validate_input <- function(mat, model_info = NULL,
                                  tol = 1e-6) {
  chk <- function(name, expected, observed, pass) {
    data.frame(check = name, expected = expected, observed = observed,
               pass = isTRUE(pass), stringsAsFactors = FALSE)
  }
  bad <- function(status, reason, checks) {
    list(ok = FALSE, status = status, reason = reason, checks = checks)
  }

  if (is.null(mat) || is.null(dim(mat)) || length(dim(mat)) != 2L) {
    return(bad("empty_image", "the peak-group image is not a matrix",
               chk("shape", "2-D matrix", "not a matrix", FALSE)))
  }
  nr <- nrow(mat); nc <- ncol(mat)
  checks <- list()

  # ---- 1. shape ----
  want <- pq_dnn_model_geometry(model_info)
  if (is.null(want)) {
    checks[[length(checks) + 1L]] <- chk(
      "shape", "known from the training log",
      sprintf("%d x %d (model geometry unknown)", nr, nc), FALSE)
  } else {
    checks[[length(checks) + 1L]] <- chk(
      "shape", sprintf("%d x %d", want[1], want[2]),
      sprintf("%d x %d", nr, nc), nr == want[1] && nc == want[2])
  }

  vals <- suppressWarnings(as.numeric(mat))
  finite <- is.finite(vals)

  # ---- 2./3. marker column ----
  last_col <- mat[, nc]
  last_row <- mat[nr, ]
  is_binary <- function(x) {
    x <- x[is.finite(x)]
    length(x) > 0L && all(x %in% c(0, 1))
  }
  col_binary <- is_binary(last_col)
  row_binary <- is_binary(last_row)
  checks[[length(checks) + 1L]] <- chk(
    "marker_axis", "last COLUMN is 0/1 (per the .mat)",
    sprintf("last col binary=%s, last row binary=%s", col_binary, row_binary),
    col_binary)

  checks[[length(checks) + 1L]] <- chk(
    "marker_content", "marker has at least one 1",
    sprintf("sum(last col) = %s", format(sum(last_col, na.rm = TRUE))),
    col_binary && sum(last_col, na.rm = TRUE) > 0)

  # ---- 4. value range ----
  rng_ok <- all(vals[finite] >= -tol & vals[finite] <= 1 + tol)
  checks[[length(checks) + 1L]] <- chk(
    "value_range", "every cell in [0, 1] (divided by the global maximum)",
    if (all(!finite)) "no finite cell" else
      sprintf("[%.4g, %.4g]", min(vals[finite]), max(vals[finite])),
    rng_ok && any(finite))

  # ---- 5. signal ----
  # Measured over the sample cells only: the marker column is 1 by
  # construction, so including it would make an empty image look non-empty.
  body <- suppressWarnings(as.numeric(mat[, seq_len(max(1L, nc - 1L)), drop = FALSE]))
  signal <- sum(body[is.finite(body)] > 0)
  checks[[length(checks) + 1L]] <- chk(
    "signal", "at least one non-zero sample cell",
    sprintf("%d non-zero sample cell(s)", signal),
    signal > 0L)

  checks <- do.call(rbind, checks)

  if (all(checks$pass)) {
    return(list(ok = TRUE, status = "ok", reason = NA_character_,
                checks = checks))
  }

  # Order matters: an image of the wrong size cannot be scored at all, so that
  # is reported first. Only once the size is right does the marker axis tell us
  # whether the image is transposed.
  if (!checks$pass[checks$check == "shape"]) {
    return(bad("shape_mismatch",
               sprintf("the image is %d x %d but the model takes %s",
                       nr, nc,
                       if (is.null(want)) "(unknown geometry)" else
                         sprintf("%d x %d", want[1], want[2])), checks))
  }
  if (!checks$pass[checks$check == "marker_axis"] && row_binary && !col_binary) {
    return(bad("orientation_error",
               paste("the image is transposed: the 0/1 window marker is on the",
                     "last ROW instead of the last COLUMN, which is the layout",
                     "the model was trained on. Refusing to score it - the",
                     "model would return a plausible-looking low score."),
               checks))
  }
  if (signal == 0L) {
    return(bad("empty_image",
               "the peak group contains no signal; this is a failed extraction, not a peak",
               checks))
  }
  if (!rng_ok) {
    return(bad("value_range",
               paste("cells fall outside [0, 1]; the global-maximum scaling step",
                     "was skipped or applied twice"), checks))
  }
  bad("input_invalid", paste(checks$check[!checks$pass], collapse = ", "), checks)
}

# Geometry recorded in the training log, as c(height, width) - or NULL.
pq_dnn_model_geometry <- function(model_info) {
  if (is.null(model_info)) return(NULL)
  shp <- model_info$input_shape
  if (is.null(shp) || length(shp) < 3L) return(NULL)
  h <- suppressWarnings(as.integer(shp[2]))
  w <- suppressWarnings(as.integer(shp[3]))
  if (is.na(h) || is.na(w) || h < 1L || w < 1L) return(NULL)
  c(h, w)
}

# Validate a whole batch. Returns one row per group so the UI can show which
# group failed and why; `ok` is FALSE when any group violates the contract.
pq_dnn_validate_batch <- function(batch, model_info = NULL) {
  if (is.null(batch) || is.null(batch$images) || length(batch$images) == 0L) {
    return(list(ok = FALSE, status = "no_images",
                reason = "no peak group produced an image", table = NULL))
  }
  rows <- vector("list", length(batch$images))
  for (i in seq_along(batch$images)) {
    v <- pq_dnn_validate_input(batch$images[[i]], model_info)
    rows[[i]] <- data.frame(
      feature_id = batch$meta$feature_id[i],
      status = v$status,
      ok = isTRUE(v$ok),
      reason = if (is.na(v$reason)) "" else v$reason,
      failed_checks = if (is.null(v$checks)) "" else
        paste(v$checks$check[!v$checks$pass], collapse = ","),
      stringsAsFactors = FALSE)
  }
  tbl <- do.call(rbind, rows)
  first_bad <- which(!tbl$ok)[1]
  if (is.na(first_bad)) {
    return(list(ok = TRUE, status = "ok", reason = NA_character_, table = tbl))
  }
  list(ok = FALSE, status = tbl$status[first_bad],
       reason = sprintf("%s (%s)", tbl$reason[first_bad],
                        tbl$feature_id[first_bad]),
       table = tbl)
}

# Human-readable description of the geometry, for provenance sheets.
pq_dnn_geometry_note <- function(params = pq_dnn_params()) {
  data.frame(
    item = c("rt_duration_min", "min_rt_sep_min", "n_rt_slices",
             "max_signal_rows", "high_intensity_rows", "random_rows",
             "marker_row", "scaling", "interpolation", "zero_handling",
             "source"),
    value = c(
      format(params$rt_duration),
      format(params$min_rt_sep),
      format(floor(params$rt_duration / params$min_rt_sep)),
      format(params$max_signal_files),
      format(ceiling(params$max_signal_files * params$prop_high_peaks)),
      format(params$max_signal_files -
               ceiling(params$max_signal_files * params$prop_high_peaks)),
      "last row, 1 inside the window, 0 outside",
      "divide every cell by the global matrix maximum",
      "approx(method='linear', rule=2, ties=mean) onto the RT grid",
      "matrix cells equal to 0 are exported as NA and restored to 0 on read",
      "peakGroupImageMatrixAndPlot.R @94237bf"
    ),
    stringsAsFactors = FALSE
  )
}

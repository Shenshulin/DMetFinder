# ============================================================
# Peak Quality - cross-sample peak groups (input for the Kantz 2019 DNN)
# ============================================================
# SCOPE OF THIS FILE
#   Only the part of the published pipeline that can be reproduced without a
#   trained model: the peak-group image, its visualisation, and the diagnosis
#   of missing / unusable members of a group.
#
#   No prediction is produced. The author repository contains no weights
#   (`ApplyPeakPredictionModel.R` ships the placeholder
#   modelFile <- "modelFileName.h5"), so quality_probability stays NA and the
#   UI says so. Inventing a probability here would be a fabricated result.
#
# IMAGE CONTRACT, as implemented by the author's
# peakGroupImageMatrixAndPlot.R (verified line by line in the audit):
#   1. keep only group members that have signal (intensity > 0);
#      zero-signal members are REMOVED, not zero-filled;
#   2. interpolate every member onto a common equally spaced RT grid with
#      stats::approx(method = "linear", rule = 2, ties = "mean");
#      rule = 2 means the edge value is carried outward as a plateau, so the
#      image never contains an invented slope;
#   3. pad to the model's fixed row count with zeros (author: maxSignalFiles);
#   4. divide the whole matrix by its global maximum (not per row);
#   5. append one binary row marking the columns that lie inside the window.
#
#   Paper (Anal. Chem. 2019): 64 x 64.  Author R default: 31 x 200.
#   They are NOT the same model input; the spec is recorded with every image.
# ============================================================

PQ_DNN_IMAGE_SPEC <- list(
  paper_rows = 64L,    # 63 samples + 1 mask row
  paper_cols = 64L,
  script_rows = 31L,   # maxSignalFiles = 30 + 1 mask row
  script_cols = 200L,  # floor(RtDur / minRtSep), minRtSep = 0.005
  interpolation = "linear (rule = 2)",
  normalization = "global maximum of the matrix",
  zero_signal_members = "dropped, not zero-filled",
  note = paste("The two published configurations differ; an image built here",
               "is not automatically compatible with a model trained on the",
               "other one.")
)

pq_default_group_params <- function() {
  list(
    n_slices = PQ_DNN_IMAGE_SPEC$paper_cols,  # image width in RT bins
    pad_rows = 0L,                            # 0 = no padding (author pads to 30/63)
    window_pad = 0,                           # extra minutes on each side
    min_series = 2L,                          # a "group" needs at least 2 samples
    normalize = TRUE
  )
}

# ------------------------------------------------------------
# The RT window shared by all members of one feature
# ------------------------------------------------------------
pq_group_window <- function(rows, feat) {
  r <- rows[rows$feature_id == feat, , drop = FALSE]
  if (nrow(r) == 0) return(c(NA_real_, NA_real_))
  win <- if (!is.null(r$rt_window)) suppressWarnings(as.numeric(r$rt_window)) else NA_real_
  half <- if (all(is.na(win))) 0.3 else max(win, na.rm = TRUE)
  c(min(r$input_rt, na.rm = TRUE) - half,
    max(r$input_rt, na.rm = TRUE) + half)
}

# ------------------------------------------------------------
# One member = one sample's XIC inside the group window
# ------------------------------------------------------------
# Returns a list of data.frames (rt, intensity, sample_id) built from the
# stored detail, plus the bookkeeping needed to explain what is missing.
pq_group_members <- function(detail, rows, feat) {
  keys <- names(detail)
  idx <- which(rows$feature_id == feat)
  members <- list()
  for (i in idx) {
    d <- detail[[keys[i]]]
    sid <- rows$sample_id[i]
    # The image is the model input, so it must be built from the same trace
    # the analysis used: the smoothed one when XIC smoothing is enabled.
    xic_use <- pq_analysis_xic(d)
    if (is.null(d) || is.null(xic_use) || nrow(xic_use) == 0) {
      members[[length(members) + 1L]] <- list(
        sample_id = sid, status = ifelse(identical(rows$presence[i], "absent"),
                                         "absent", "no_xic"),
        rt = numeric(), intensity = numeric(), presence = rows$presence[i])
      next
    }
    members[[length(members) + 1L]] <- list(
      sample_id = sid,
      status = ifelse(identical(rows$presence[i], "absent"), "absent", "signal"),
      rt = as.numeric(xic_use$rt),
      intensity = as.numeric(xic_use$intensity),
      presence = rows$presence[i],
      apex_rt = d$peak$apex_rt,
      n_points = d$peak$n_points)
  }
  members
}

# ------------------------------------------------------------
# Image construction
# ------------------------------------------------------------
# members : list from pq_group_members()
# window  : c(rt_lo, rt_hi)
pq_peak_group_image <- function(members, window,
                                params = pq_default_group_params()) {
  n_slices <- as.integer(params$n_slices)
  if (is.na(n_slices) || n_slices < 4) n_slices <- PQ_DNN_IMAGE_SPEC$paper_cols
  rt_grid <- seq(window[1], window[2], length.out = n_slices)

  # step 1: keep only members with signal
  usable <- members[vapply(members, function(m)
    length(m$rt) >= 2 && any(is.finite(m$intensity) & m$intensity > 0), logical(1))]
  dropped <- vapply(members[!vapply(members, function(m)
    length(m$rt) >= 2 && any(is.finite(m$intensity) & m$intensity > 0), logical(1))],
    function(m) m$sample_id, character(1))

  if (length(usable) == 0) {
    return(list(ok = FALSE, reason = "no member of this group has signal",
                matrix = NULL, rt_slices = rt_grid, samples = character(0),
                mask = NULL, dropped = dropped, n_padded = 0L,
                extrapolated = character(0), spec = params))
  }

  # step 2: interpolate every member onto the common grid
  mat <- matrix(NA_real_, nrow = length(usable), ncol = n_slices)
  extrapolated <- character(0)
  for (i in seq_along(usable)) {
    m <- usable[[i]]
    ok <- is.finite(m$rt) & is.finite(m$intensity)
    x <- m$rt[ok]; y <- m$intensity[ok]
    o <- order(x); x <- x[o]; y <- y[o]
    if (max(x) < window[2] || min(x) > window[1]) {
      extrapolated <- c(extrapolated, m$sample_id)
    }
    ap <- stats::approx(x = x, y = y, xout = rt_grid, method = "linear",
                       rule = 2, ties = "mean")
    mat[i, ] <- ap$y
  }
  mat[!is.finite(mat)] <- 0
  samples <- vapply(usable, function(m) m$sample_id, character(1))

  # step 3: optional zero padding to a fixed row count (author's maxSignalFiles)
  pad_rows <- as.integer(params$pad_rows)
  n_padded <- 0L
  if (!is.na(pad_rows) && pad_rows > nrow(mat)) {
    n_padded <- pad_rows - nrow(mat)
    mat <- rbind(mat, matrix(0, nrow = n_padded, ncol = n_slices))
    samples <- c(samples, rep(NA_character_, n_padded))
  }

  # step 4: normalise by the global maximum
  gmax <- max(mat)
  if (isTRUE(params$normalize)) {
    mat <- if (is.finite(gmax) && gmax > 0) mat / gmax else mat * 0
  }

  # step 5: window mask row (informative only when the grid is wider than the
  # window; with a grid built exactly over the window it is all ones)
  mask_rt <- if (!is.null(params$mask_rt)) params$mask_rt else window
  mask <- as.integer(rt_grid >= mask_rt[1] & rt_grid <= mask_rt[2])

  list(ok = TRUE, reason = NA_character_, matrix = mat, rt_slices = rt_grid,
       samples = samples, mask = mask, dropped = dropped,
       n_padded = n_padded, extrapolated = extrapolated,
       global_max = gmax, spec = params)
}

# ------------------------------------------------------------
# Local maxima per member (a group can contain several peaks)
# ------------------------------------------------------------
# Raw local maxima would count every noise ripple, so a prominence filter is
# applied with the same relative threshold the peak detector uses. A trace
# with one clean peak therefore reports 1, and only a real second hump counts.
pq_count_local_maxima <- function(y, min_prom_frac = 0.05) {
  y <- as.numeric(y)
  y <- y[is.finite(y)]
  n <- length(y)
  if (n < 5) return(0L)
  lm <- pq_local_maxima(y)
  if (length(lm) == 0) return(0L)
  rng <- max(y) - min(y)
  if (!is.finite(rng) || rng <= 0) return(0L)
  prom <- vapply(lm, function(i) pq_prominence(y, i), numeric(1))
  as.integer(sum(is.finite(prom) & prom >= min_prom_frac * rng))
}

# ------------------------------------------------------------
# One feature: image + diagnostics
# ------------------------------------------------------------
pq_peak_group <- function(rows, detail, feat, params = pq_default_group_params()) {
  win <- pq_group_window(rows, feat)
  if (!all(is.finite(win))) {
    return(list(feature_id = feat, ok = FALSE,
                reason = "the feature has no usable RT window",
                diagnostics = NULL, image = NULL, members = NULL))
  }
  if (is.finite(params$window_pad) && params$window_pad > 0) {
    win <- win + c(-params$window_pad, params$window_pad)
  }

  members <- pq_group_members(detail, rows, feat)
  r <- rows[rows$feature_id == feat, , drop = FALSE]
  img <- pq_peak_group_image(members, win, params)

  sig <- vapply(members, function(m) identical(m$status, "signal"), logical(1))
  apex <- suppressWarnings(vapply(members, function(m)
    if (is.null(m$apex_rt)) NA_real_ else as.numeric(m$apex_rt), numeric(1)))
  n_lm <- vapply(members, function(m) {
    yy <- m$intensity[is.finite(m$intensity)]
    pq_count_local_maxima(yy)
  }, integer(1))

  apex_med <- if (any(is.finite(apex))) stats::median(apex, na.rm = TRUE) else NA_real_
  drift <- if (is.na(apex_med)) rep(NA_real_, length(apex)) else apex - apex_med

  n_signal <- sum(sig)
  n_absent <- sum(vapply(members, function(m) identical(m$status, "absent"), logical(1)))
  n_no_xic <- sum(vapply(members, function(m) identical(m$status, "no_xic"), logical(1)))

  admissibility <- "ok"
  reason <- NA_character_
  if (n_signal == 0) {
    admissibility <- "no_signal"
    reason <- "no member of the group has any signal in the window"
  } else if (n_signal < params$min_series) {
    admissibility <- "single_member"
    reason <- sprintf(paste(
      "only %d member(s) with signal - the published method classifies a",
      "cross-sample peak group, so no valid image can be built"), n_signal)
  } else if (!isTRUE(img$ok)) {
    admissibility <- "image_failed"
    reason <- img$reason
  }

  diag <- data.frame(
    feature_id = feat,
    mz = r$mz[1],
    input_rt = r$input_rt[1],
    window_lo = win[1], window_hi = win[2],
    n_rows_in_table = nrow(r),
    n_signal = n_signal,
    n_absent = n_absent,
    n_no_xic = n_no_xic,
    n_dropped_zero_signal = length(img$dropped),
    n_image_rows = if (isTRUE(img$ok)) nrow(img$matrix) else 0L,
    n_image_cols = if (isTRUE(img$ok)) ncol(img$matrix) else 0L,
    n_padded_rows = if (isTRUE(img$ok)) img$n_padded else 0L,
    n_extrapolated = length(img$extrapolated),
    n_multi_peak_members = sum(n_lm > 1, na.rm = TRUE),
    apex_rt_median = apex_med,
    apex_drift_median_abs = if (any(is.finite(drift)))
      stats::median(abs(drift), na.rm = TRUE) else NA_real_,
    apex_drift_max_abs = if (any(is.finite(drift)))
      max(abs(drift), na.rm = TRUE) else NA_real_,
    admissibility = admissibility,
    reason = reason,
    stringsAsFactors = FALSE
  )

  list(feature_id = feat, ok = isTRUE(img$ok), reason = reason,
       diagnostics = diag, image = img, members = members, window = win)
}

# ------------------------------------------------------------
# Many features: diagnostics only (cheap), images on demand
# ------------------------------------------------------------
pq_peak_group_table <- function(rows, detail, params = pq_default_group_params(),
                                features = NULL, max_features = 5000L,
                                progress_fun = function(v, d) invisible(NULL)) {
  if (is.null(rows) || nrow(rows) == 0) return(NULL)
  feats <- unique(rows$feature_id)
  if (!is.null(features)) feats <- intersect(feats, features)
  limited <- length(feats) > max_features
  if (limited) feats <- utils::head(feats, max_features)

  out <- vector("list", length(feats))
  for (i in seq_along(feats)) {
    if (i %% 100L == 0L || i == length(feats)) {
      progress_fun(i / length(feats), sprintf("peak groups %d/%d", i, length(feats)))
    }
    g <- pq_peak_group(rows, detail, feats[i], params)
    out[[i]] <- if (is.null(g$diagnostics)) {
      data.frame(feature_id = feats[i], admissibility = "no_window",
                 stringsAsFactors = FALSE)
    } else g$diagnostics
  }
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  attr(res, "limited") <- limited
  res
}

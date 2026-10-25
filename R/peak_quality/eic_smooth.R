# ============================================================
# XIC smoothing applied BEFORE the analysis (opt-in, off by default)
# ============================================================
# Why this file exists
# -------------------
# The original build smoothed the trace only to *locate* the apex: the
# intensities handed to the Kumler scoring function were always the raw
# ones (see peak_detect.R, `smooth_points`). CPC does its own internal
# Savitzky-Golay. There was therefore no way to analyse a deliberately
# smoothed chromatogram, which is what a user with a noisy EIC wants.
#
# This module adds that switch. It is OFF by default, because turning it on
# changes the numbers: the author's peak_cor / SNR are then computed on a
# smoothed trace, which is NOT the author's raw-data output. Every row
# records the setting (`eic_smoothing`, `eic_smoothing_applied`) and the
# parameter string carries it into the exports, so a smoothed run can never
# be mistaken for a raw one.
#
# What is smoothed, and what is not
# --------------------------------
#   smoothed  : the analysis trace - boundary detection, the scored peak
#               slice, the CPC input, the peak-group image
#   NOT       : peak presence (height and point-to-point noise)
#
# Presence is deliberately excluded. Its noise estimate is
# 1.4826*MAD(diff(y))/sqrt(2); smoothing removes exactly the high-frequency
# component that estimate is built from, so a smoothed noise floor would
# manufacture presence out of pure noise. The presence verdict is therefore
# invariant to this switch - a property asserted in test_12_eic_smooth.R.
#
# Edge handling (no invented points)
# ----------------------------------
#   Savitzky-Golay : the first/last (w-1)/2 points are evaluated from a
#                    polynomial fitted to the first/last FULL window and
#                    evaluated at the real position of the edge point. That
#                    is a genuine local fit on measured scans, not an
#                    extrapolation and not a copy of the neighbour.
#   Moving average : a centred mean over the points that actually exist in
#                    the window (a truncated window near the edges). Unlike
#                    pq_movavg(), which leaves the edges untouched, this
#                    avoids a visible step between smoothed and raw parts.
# If the trace is shorter than the window, nothing is smoothed and the
# reason is recorded - the trace is never zero-padded to fit the window.
# ============================================================

PQ_EIC_SMOOTH_METHODS <- c("none", "savgol", "movavg")

PQ_EIC_SMOOTH_CHOICES <- c(
  "No smoothing (raw XIC)"             = "none",
  "Savitzky-Golay (preserves height)"  = "savgol",
  "Moving average (simple, broader)"   = "movavg"
)

PQ_EIC_SMOOTH_DEFAULTS <- list(
  method = "none",
  window = 7L,      # scans; forced to an odd number >= 3
  order  = 2L       # Savitzky-Golay polynomial order (ignored by movavg)
)

# Guard: a trace with fewer points than this is never smoothed. Below five
# points the author's scoring function refuses the slice anyway.
PQ_EIC_SMOOTH_MIN_POINTS <- 5L

# ------------------------------------------------------------
# Labels (used in every export, so they must stay stable ASCII)
# ------------------------------------------------------------
pq_eic_smooth_effective_window <- function(window) {
  w <- suppressWarnings(as.integer(window))
  if (length(w) != 1L || is.na(w)) w <- PQ_EIC_SMOOTH_DEFAULTS$window
  if (w < 3L) w <- 3L
  if (w %% 2L == 0L) w <- w + 1L   # even windows are silently made odd
  w
}

pq_eic_smooth_effective_order <- function(order, window) {
  o <- suppressWarnings(as.integer(order))
  if (length(o) != 1L || is.na(o) || o < 0L) o <- PQ_EIC_SMOOTH_DEFAULTS$order
  # An order of 4 never smooths: on a 5-point window it interpolates the
  # points exactly. Cap at a cubic, which is still a smoother.
  if (o > 3L) o <- 3L
  if (o > window - 1L) o <- window - 1L
  as.integer(o)
}

pq_eic_smooth_label <- function(method = "none", window = 7L, order = 2L) {
  method <- as.character(method)[1]
  if (is.na(method) || !method %in% PQ_EIC_SMOOTH_METHODS) method <- "none"
  if (identical(method, "none")) return("none")
  w <- pq_eic_smooth_effective_window(window)
  if (identical(method, "movavg")) {
    return(sprintf("Moving average (window %d)", w))
  }
  o <- pq_eic_smooth_effective_order(order, w)
  sprintf("Savitzky-Golay (window %d, order %d)", w, o)
}

# Short label for on-screen legends, where the full label nests parentheses
# badly ("XIC analysis trace (Savitzky-Golay (window 7, order 2))").
pq_eic_smooth_short_label <- function(method = "none", window = 7L, order = 2L) {
  method <- as.character(method)[1]
  if (is.na(method) || !method %in% PQ_EIC_SMOOTH_METHODS) method <- "none"
  if (identical(method, "none")) return("none")
  w <- pq_eic_smooth_effective_window(window)
  if (identical(method, "movavg")) return(sprintf("Moving average w=%d", w))
  sprintf("Savitzky-Golay w=%d", w)
}

# Short machine-friendly tag for the parameter string.
pq_eic_smooth_tag <- function(method = "none", window = 7L, order = 2L) {
  method <- as.character(method)[1]
  if (is.na(method) || !method %in% PQ_EIC_SMOOTH_METHODS) method <- "none"
  if (identical(method, "none")) return("none")
  w <- pq_eic_smooth_effective_window(window)
  if (identical(method, "movavg")) return(sprintf("movavg_w%d", w))
  o <- pq_eic_smooth_effective_order(order, w)
  sprintf("savgol_w%d_o%d", w, o)
}

# ------------------------------------------------------------
# Savitzky-Golay coefficient matrix
# ------------------------------------------------------------
# A polynomial of `order` is fitted by least squares to every window of
# `window` consecutive points, and the fitted value is read at one offset.
# C[offset + h + 1, ] holds the weights for offset `offset` in [-h, h], so
# C[h + 1, ] is the usual centred smoother and the other rows give the edge
# corrections from the very same polynomial fit.
pq_sg_coef_matrix <- function(window, order = 2L) {
  w <- pq_eic_smooth_effective_window(window)
  o <- pq_eic_smooth_effective_order(order, w)
  h <- (w - 1L) / 2L
  t <- seq.int(-h, h)
  X <- outer(t, 0:o, function(a, b) a^b)
  XtX <- crossprod(X)
  A <- tryCatch(solve(XtX, t(X)),
                error = function(e) qr.solve(XtX, t(X)))
  offs <- seq.int(-h, h)
  C <- vapply(offs, function(d) {
    xd <- d^(0:o)
    as.numeric(crossprod(xd, A))
  }, numeric(w))
  t(C)   # rows = offset, columns = window position
}

# ------------------------------------------------------------
# Moving average with a truncated centred window at the edges
# ------------------------------------------------------------
pq_movavg_centered <- function(y, window) {
  y <- as.numeric(y)
  n <- length(y)
  w <- pq_eic_smooth_effective_window(window)
  if (w < 3L || n < w) return(y)
  h <- (w - 1L) / 2L
  sm <- as.numeric(stats::filter(y, rep(1 / w, w), sides = 2))
  for (i in seq_len(h)) {
    sm[i] <- mean(y[1:(i + h)])
  }
  for (i in seq.int(n - h + 1L, n)) {
    sm[i] <- mean(y[(i - h):n])
  }
  sm
}

# ------------------------------------------------------------
# Savitzky-Golay smoother
# ------------------------------------------------------------
pq_savgol <- function(y, window, order = 2L) {
  y <- as.numeric(y)
  n <- length(y)
  w <- pq_eic_smooth_effective_window(window)
  if (w < 3L || n < w) return(y)
  h <- (w - 1L) / 2L
  C <- pq_sg_coef_matrix(w, order)

  # interior: one convolution instead of a per-point loop
  sm <- as.numeric(stats::filter(y, C[h + 1L, ], sides = 2))
  if (h > 0) {
    for (i in seq_len(h)) {
      d <- i - (h + 1L)                      # offset of point i in window 1..w
      sm[i] <- sum(C[d + h + 1L, ] * y[1:w])
    }
    for (i in seq.int(n - h + 1L, n)) {
      d <- i - (n - h)                       # offset of point i in the last window
      sm[i] <- sum(C[d + h + 1L, ] * y[(n - w + 1L):n])
    }
  }
  sm
}

# ------------------------------------------------------------
# Dispatcher: smooth one intensity vector
# ------------------------------------------------------------
# Returns list(y, applied, label, tag, method, window, order, reason,
#              n_negative, n_clamped)
# `y` is always the same length as the input and is returned unchanged when
# nothing was applied.
pq_smooth_trace <- function(y, method = "none", window = 7L, order = 2L) {
  y <- as.numeric(y)
  method <- as.character(method)[1]
  if (is.na(method) || !method %in% PQ_EIC_SMOOTH_METHODS) method <- "none"

  w <- pq_eic_smooth_effective_window(window)
  o <- pq_eic_smooth_effective_order(order, w)

  out <- list(
    y = y, applied = FALSE,
    method = method, window = w, order = o,
    label = pq_eic_smooth_label(method, w, o),
    short = pq_eic_smooth_short_label(method, w, o),
    tag = pq_eic_smooth_tag(method, w, o),
    reason = NA_character_, n_negative = 0L, n_clamped = 0L
  )

  if (identical(method, "none")) {
    out$label <- "none"
    out$short <- "none"
    out$tag <- "none"
    return(out)
  }

  if (any(!is.finite(y))) {
    out$label <- pq_eic_smooth_label(method, w, o)
    out$reason <- "the trace contains non-finite intensities; left unsmoothed"
    return(out)
  }
  if (length(y) < PQ_EIC_SMOOTH_MIN_POINTS) {
    out$reason <- sprintf("only %d XIC point(s); nothing to smooth below %d",
                          length(y), PQ_EIC_SMOOTH_MIN_POINTS)
    return(out)
  }
  if (length(y) < w) {
    out$reason <- sprintf(
      "the trace has %d point(s), fewer than the %d-point window; left unsmoothed",
      length(y), w)
    return(out)
  }
  if (identical(method, "savgol") && o >= w - 1L) {
    out$reason <- sprintf(
      "polynomial order %d leaves no smoothing on a %d-point window", o, w)
    return(out)
  }

  sm <- if (identical(method, "movavg")) {
    pq_movavg_centered(y, w)
  } else {
    pq_savgol(y, w, o)
  }

  # A quadratic fit can undershoot below zero where the trace steps down
  # abruptly. Intensity cannot be negative, and a negative baseline would
  # corrupt the range/height fractions used by the boundary detector, so the
  # floor is applied - and counted, so it is never silent.
  out$n_negative <- as.integer(sum(is.finite(sm) & sm < 0))
  if (out$n_negative > 0) {
    sm[is.finite(sm) & sm < 0] <- 0
    out$n_clamped <- out$n_negative
  }

  out$y <- sm
  out$applied <- TRUE
  out
}

# ------------------------------------------------------------
# Apply to a whole XIC data.frame
# ------------------------------------------------------------
# Returns list(xic, info). The input object is never modified in place; when
# nothing is applied the returned frame is the very same object.
pq_smooth_xic <- function(xic, method = "none", window = 7L, order = 2L) {
  info <- pq_smooth_trace(if (is.null(xic)) numeric() else xic$intensity,
                          method = method, window = window, order = order)
  if (!isTRUE(info$applied) || is.null(xic) || nrow(xic) == 0) {
    return(list(xic = xic, info = info))
  }
  x <- xic
  x$intensity <- info$y
  list(xic = x, info = info)
}

# ------------------------------------------------------------
# The trace the analysis should use for one stored detail entry
# ------------------------------------------------------------
# Entries written before this module existed have no `xic_analysis`, so the
# helper degrades to the raw trace instead of failing.
pq_analysis_xic <- function(entry) {
  if (is.null(entry)) return(NULL)
  if (!is.null(entry$xic_analysis)) return(entry$xic_analysis)
  entry$xic
}

pq_smoothing_applied <- function(entry) {
  isTRUE(entry$smoothing$applied)
}

# ------------------------------------------------------------
# Human-readable provenance lines for the report
# ------------------------------------------------------------
pq_eic_smooth_provenance_lines <- function(params) {
  method <- if (is.null(params$eic_smooth_method)) "none" else params$eic_smooth_method
  if (identical(as.character(method), "none")) {
    return("XIC smoothing             : none (scores computed on the raw XIC)")
  }
  lab <- pq_eic_smooth_label(params$eic_smooth_method,
                             params$eic_smooth_window,
                             params$eic_smooth_order)
  c(paste0("XIC smoothing             : ", lab,
           " - applied BEFORE boundary detection and scoring"),
    paste0("  affects                 : boundaries, peak_cor/SNR, CPC input,",
           " peak-group image"),
    paste0("  does not affect         : peak presence, peak height and the",
           " point-to-point noise"),
    paste0("  consequence             : these scores are NOT the author's",
           " raw-data output"))
}

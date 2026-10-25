# ============================================================
# Automatic candidate peak boundaries (pre-processing step)
# ============================================================
# This algorithm is NOT part of the Kumler et al. paper. It only decides
# *which part of the XIC* is handed to the author scoring function. It is
# deliberately separated from R/peak_quality/vendor/ and never adjusts its
# output to make a score look better.
#
# Reproducible rules (every threshold is a parameter visible in the UI):
#   1. Baseline = minimum intensity inside the RT window.
#      range    = max intensity - baseline.  range <= 0 -> "no_clear_apex".
#   2. Optional detection smoothing (moving average, odd width). Smoothing is
#      used to locate apexes and boundaries ONLY; scoring always receives the
#      raw intensities.
#   3. Candidate apex = local maximum of the detection series.
#      A candidate is kept when all three hold:
#        prominence        >= min_prominence_frac  * range
#        height above base >= min_height_frac      * range
#        prominence        >= min_rel_prominence   * (largest prominence in window)
#      The third rule removes the micro-ripples that noise creates on the
#      flanks of an otherwise single peak. If nothing passes, the global
#      maximum is used and the row is flagged "no_clear_apex".
#   4. Boundaries of a candidate, on each side independently:
#        - walk outwards while the series stays above
#          thr = baseline + edge_frac * (apex - baseline);
#        - stop at the first point at or below thr   -> "threshold crossing";
#        - if the series turns upward first, that point is a valley: it is
#          accepted as the boundary only when the valley stays below
#          baseline + valley_frac * (apex - baseline), i.e. it really
#          separates two peaks. Otherwise the walk continues through the dip.
#      A boundary is reliable when it was reached by crossing the threshold or
#      by an accepted valley. Peaks clipped by the RT window are flagged
#      "boundary_unclear" and the clipped side is reported in edge_touched.
#   5. Candidate selection: the apex closest to the user-supplied RT wins.
#      If two or more candidates lie within +-apex_tolerance of the input RT
#      the row is marked "ambiguous" and every candidate is kept in the
#      candidate table. The highest peak is NOT preferred by design.
#   6. Status priority: no_clear_apex > apex_outside > ambiguous >
#      boundary_unclear > too_few_points > ok.
# ============================================================

pq_movavg <- function(x, k) {
  if (k < 3 || length(x) < k) return(x)
  sm <- as.numeric(stats::filter(x, rep(1 / k, k), sides = 2))
  edge <- is.na(sm)
  sm[edge] <- x[edge]
  sm
}

pq_local_maxima <- function(y) {
  n <- length(y)
  if (n < 3) return(integer(0))
  which((y >= c(-Inf, y[-n])) & (y > c(y[-1], -Inf)))
}

pq_prominence <- function(y, i) {
  n <- length(y)
  h <- y[i]
  j <- i
  min_left <- h
  while (j > 1 && y[j - 1] <= h) {
    j <- j - 1
    if (y[j] < min_left) min_left <- y[j]
  }
  j <- i
  min_right <- h
  while (j < n && y[j + 1] <= h) {
    j <- j + 1
    if (y[j] < min_right) min_right <- y[j]
  }
  h - max(min_left, min_right)
}

# One side of a peak. dir = -1 (left) or +1 (right).
pq_side_bound <- function(y, i, thr, baseline, valley_frac, dir) {
  n <- length(y)
  apex_h <- y[i] - baseline
  j <- i
  repeat {
    nxt <- j + dir
    if (nxt < 1L || nxt > n) {
      return(list(index = j, reliable = FALSE, kind = "window_edge"))
    }
    if (y[nxt] <= thr) {
      return(list(index = nxt, reliable = TRUE, kind = "threshold"))
    }
    if (y[nxt] > y[j]) {
      if ((y[j] - baseline) <= valley_frac * apex_h) {
        return(list(index = j, reliable = TRUE, kind = "valley"))
      }
      # shallow dip: keep walking towards the threshold
    }
    j <- nxt
  }
}

pq_empty_candidates <- function() {
  data.frame(
    candidate_id = integer(), apex_index = integer(), start_index = integer(),
    end_index = integer(), apex_rt = numeric(), start_rt = numeric(),
    end_rt = numeric(), apex_intensity = numeric(), n_points = integer(),
    prominence = numeric(), height_frac = numeric(), boundary_ok = logical(),
    delta_rt = numeric(), selected = logical(),
    stringsAsFactors = FALSE
  )
}

pq_empty_peak <- function() {
  data.frame(
    start_rt = NA_real_, apex_rt = NA_real_, end_rt = NA_real_,
    n_points = 0L, apex_index = NA_integer_, start_index = NA_integer_,
    end_index = NA_integer_, apex_intensity = NA_real_,
    start_intensity = NA_real_, end_intensity = NA_real_,
    baseline = NA_real_, prominence = NA_real_,
    boundary_ok = FALSE, edge_touched = NA_character_,
    start_kind = NA_character_, end_kind = NA_character_,
    stringsAsFactors = FALSE
  )
}

# ------------------------------------------------------------
# Main detector
# ------------------------------------------------------------
pq_detect_peaks <- function(xic, input_rt, params) {
  if (is.null(xic) || nrow(xic) == 0) {
    return(list(status = "no_signal", reason = "XIC is empty",
                peak = pq_empty_peak(), candidates = pq_empty_candidates(),
                n_candidates = 0L))
  }

  rt <- as.numeric(xic$rt)
  int <- as.numeric(xic$intensity)
  n <- length(int)

  if (n < 3) {
    return(list(status = "too_few_points",
                reason = paste0("only ", n, " scan(s) in the RT window"),
                peak = pq_empty_peak(), candidates = pq_empty_candidates(),
                n_candidates = 0L))
  }

  baseline <- min(int)
  rng <- max(int) - baseline
  if (!is.finite(rng) || rng <= 0) {
    return(list(status = "no_clear_apex",
                reason = "flat XIC (max == min): no peak to delimit",
                peak = pq_empty_peak(), candidates = pq_empty_candidates(),
                n_candidates = 0L))
  }

  y <- pq_movavg(int, as.integer(params$smooth_points))
  lm <- pq_local_maxima(y)

  cand_idx <- integer(0)
  cand_prom <- numeric(0)
  if (length(lm) > 0) {
    prom <- vapply(lm, function(i) pq_prominence(y, i), numeric(1))
    rel_cut <- params$min_rel_prominence * max(prom)
    keep <- prom >= params$min_prominence_frac * rng &
      prom >= rel_cut &
      (y[lm] - baseline) >= params$min_height_frac * rng
    cand_idx <- lm[keep]
    cand_prom <- prom[keep]
  }

  fallback <- FALSE
  if (length(cand_idx) == 0) {
    cand_idx <- which.max(y)
    cand_prom <- pq_prominence(y, cand_idx)
    fallback <- TRUE
  }

  ord <- order(cand_idx)
  cand_idx <- cand_idx[ord]
  cand_prom <- cand_prom[ord]

  starts <- integer(length(cand_idx))
  ends <- integer(length(cand_idx))
  boundary_ok <- logical(length(cand_idx))
  start_kind <- character(length(cand_idx))
  end_kind <- character(length(cand_idx))

  for (k in seq_along(cand_idx)) {
    i <- cand_idx[k]
    thr <- baseline + params$edge_frac * (y[i] - baseline)
    lb <- pq_side_bound(y, i, thr, baseline, params$valley_frac, -1L)
    rb <- pq_side_bound(y, i, thr, baseline, params$valley_frac, 1L)
    starts[k] <- lb$index
    ends[k] <- rb$index
    start_kind[k] <- lb$kind
    end_kind[k] <- rb$kind
    boundary_ok[k] <- lb$reliable && rb$reliable
  }

  cands <- data.frame(
    candidate_id = seq_along(cand_idx),
    apex_index = cand_idx,
    start_index = starts,
    end_index = ends,
    apex_rt = rt[cand_idx],
    start_rt = rt[starts],
    end_rt = rt[ends],
    apex_intensity = int[cand_idx],
    n_points = ends - starts + 1L,
    prominence = cand_prom,
    height_frac = (int[cand_idx] - baseline) / rng,
    boundary_ok = boundary_ok,
    delta_rt = abs(rt[cand_idx] - input_rt),
    selected = FALSE,
    stringsAsFactors = FALSE
  )

  # Deterministic selection: closest apex to the input RT; exact ties (to
  # 1e-6 min) are broken by the larger prominence so the choice does not
  # depend on floating point noise. The highest peak is never preferred
  # unless it is also the closest one.
  cands$delta_rt <- round(cands$delta_rt, 6)
  ord_sel <- order(cands$delta_rt, -cands$prominence)
  best <- ord_sel[1]
  cands$selected[best] <- TRUE

  status <- "ok"
  reason <- NA_character_

  if (fallback) {
    status <- "no_clear_apex"
    reason <- "no local maximum passed the prominence/height filter; global maximum used"
  } else if (cands$delta_rt[best] > params$apex_tolerance) {
    status <- "apex_outside"
    reason <- sprintf(
      "closest candidate apex is %.3f min from the input RT (tolerance %.3f min)",
      cands$delta_rt[best], params$apex_tolerance)
  } else {
    rivals <- which(cands$delta_rt <= params$apex_tolerance)
    if (length(rivals) >= 2) {
      status <- "ambiguous"
      reason <- sprintf(
        "%d candidate apexes lie within %.3f min of the input RT (%s min)",
        length(rivals), params$apex_tolerance,
        paste(sprintf("%.3f", cands$apex_rt[rivals]), collapse = ", "))
    } else if (!cands$boundary_ok[best]) {
      status <- "boundary_unclear"
      reason <- paste0("peak boundary not reached inside the RT window (",
                       start_kind[best], " / ", end_kind[best], ")")
    } else if (cands$n_points[best] < params$min_points) {
      status <- "too_few_points"
      reason <- sprintf("only %d scans inside the detected peak (minimum %d)",
                        cands$n_points[best], params$min_points)
    }
  }

  b <- best
  touched <- trimws(paste0(
    if (identical(start_kind[b], "window_edge")) "left" else "", " ",
    if (identical(end_kind[b], "window_edge")) "right" else ""))

  peak <- data.frame(
    start_rt = cands$start_rt[b],
    apex_rt = cands$apex_rt[b],
    end_rt = cands$end_rt[b],
    n_points = cands$n_points[b],
    apex_index = cands$apex_index[b],
    start_index = cands$start_index[b],
    end_index = cands$end_index[b],
    apex_intensity = cands$apex_intensity[b],
    start_intensity = int[cands$start_index[b]],
    end_intensity = int[cands$end_index[b]],
    baseline = baseline,
    prominence = cands$prominence[b],
    boundary_ok = cands$boundary_ok[b],
    edge_touched = if (nzchar(touched)) touched else NA_character_,
    start_kind = start_kind[b],
    end_kind = end_kind[b],
    stringsAsFactors = FALSE
  )

  list(status = status, reason = reason, peak = peak,
       candidates = cands, n_candidates = nrow(cands),
       baseline = baseline, range = rng)
}

# ------------------------------------------------------------
# Slice the XIC to the detected peak (raw intensities only)
# ------------------------------------------------------------
pq_peak_slice <- function(xic, peak) {
  if (nrow(xic) == 0 || is.na(peak$start_index) || is.na(peak$end_index)) {
    return(xic[0, , drop = FALSE])
  }
  idx <- seq.int(peak$start_index, peak$end_index)
  idx <- idx[idx >= 1 & idx <= nrow(xic)]
  xic[idx, , drop = FALSE]
}

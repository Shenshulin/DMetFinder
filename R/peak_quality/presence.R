# ============================================================
# Peak presence: is the compound in this sample at all?
# ============================================================
# An aligned peak table (MS-DIAL / MZmine) lists a feature once for the whole
# cohort and asks for it to be evaluated in every raw file. In reality a
# compound is absent from part of the samples: different group, below the
# limit of detection, or simply not ionised in that injection.
#
# Those rows must not be reported as "the scoring failed", and they must not
# be mixed into the per-feature summary - otherwise a feature that is present
# and clean in 5 of 20 samples would look terrible because 15 samples
# contained nothing but baseline noise.
#
# This step decides presence BEFORE scoring. It is a pre-processing decision
# like boundary detection: it is separated from R/peak_quality/vendor/ and
# never touches the author's arithmetic. A row classified as "absent" is
# still written to the result table (with the reason), never dropped.
#
# Documented rules, evaluated in this order:
#   1. No MS1 scan inside the RT window        -> presence "unknown"
#      (the file cannot be judged; not the compound's fault)
#   2. No ion inside the m/z tolerance window
#      in ANY scan of the window               -> "absent"
#   3. Fewer than absent_min_points XIC points -> "absent"
#      (a peak cannot be formed from 1-2 scans; isolated noise spikes)
#   4. Peak height above baseline < absent_snr x point-to-point noise
#                                              -> "absent"
#      peak height = apex intensity - window baseline, i.e. the very quantity
#      the author's SNR formula uses; the noise is 1.4826*MAD(diff)/sqrt(2),
#      estimated from the same XIC, so the test is scale free. The test is
#      only applied when the XIC holds at least 6 points: with fewer, the
#      differences are dominated by the peak itself and the estimate is not
#      meaningful (a narrow but real peak must not be called absent).
#   5. otherwise                               -> "present"
#
# absent_snr = 0 (or detect_absent = FALSE) disables rules 3 and 4, so every
# row with any ion in the window is scored. The chosen values are defaults,
# not validated optima, and are written into every export.
# ============================================================

# diag     : list returned in pq_extract_xic()$diag
# xic      : data.frame returned in pq_extract_xic()$xic
# det      : list returned by pq_detect_peaks()
# params   : pq_default_params() list (detect_absent, absent_snr,
#            absent_min_points)
#
# `det` must belong to the raw trace: the height is read from it and the
# noise comes from `diag`. The pipeline passes the RAW detection here even
# when the analysis trace was smoothed, so the presence verdict cannot be
# changed by the smoothing switch.

# Minimum number of XIC points needed before the intensity test is trusted.
PQ_NOISE_MIN_POINTS <- 6L

pq_assess_presence <- function(diag, xic, det, params) {
  absent_on <- isTRUE(params$detect_absent)
  snr_cut <- if (is.null(params$absent_snr)) 0 else as.numeric(params$absent_snr)
  min_pts <- if (is.null(params$absent_min_points)) 1L else
    as.integer(params$absent_min_points)

  out <- list(
    presence = "present",
    reason = NA_character_,
    height = NA_real_,
    noise = if (is.null(diag$noise)) NA_real_ else diag$noise,
    snr = NA_real_
  )

  # ---- 1. no scan at all -> cannot judge -------------------------------
  if (is.null(diag$n_scans_in_window) || diag$n_scans_in_window == 0) {
    out$presence <- "unknown"
    out$reason <- "no MS1 scan inside the RT search window (presence not determined)"
    return(out)
  }

  # the peak height that would be scored, measured the same way the author
  # function measures it (apex - baseline of the window).
  # `det` must be the detection of the SAME trace that `diag$noise` and
  # `xic` refer to - i.e. the raw trace. The pipeline passes the raw
  # detection here even when the analysis trace was smoothed, which is what
  # makes this verdict independent of the smoothing switch.
  height <- NA_real_
  if (!is.null(det$peak) && !is.na(det$peak$apex_intensity) &&
      !is.na(det$peak$baseline)) {
    height <- det$peak$apex_intensity - det$peak$baseline
  } else if (nrow(xic) > 0) {
    height <- max(xic$intensity) - min(xic$intensity)
  }
  out$height <- height
  if (!is.na(height) && !is.na(out$noise) && out$noise > 0) {
    out$snr <- height / out$noise
  }

  if (!absent_on) return(out)

  # ---- 2. nothing inside the m/z window in any scan ---------------------
  if (is.na(diag$n_mz_matched) || diag$n_mz_matched == 0) {
    out$presence <- "absent"
    out$reason <- paste0(
      "no ion inside the m/z tolerance window in any of the ",
      diag$n_scans_in_window, " MS1 scans of the RT window")
    return(out)
  }

  # ---- 3. too few points to form a peak --------------------------------
  if (nrow(xic) < min_pts) {
    out$presence <- "absent"
    out$reason <- sprintf(
      "signal found in only %d of %d MS1 scans (absent_min_points = %d)",
      nrow(xic), diag$n_scans_in_window, min_pts)
    return(out)
  }

  # ---- 4. signal does not rise above the noise --------------------------
  # The noise estimate needs enough points; below PQ_NOISE_MIN_POINTS the
  # differences are the peak itself, so the test is skipped on purpose.
  if (snr_cut > 0 && !is.na(height) && nrow(xic) >= PQ_NOISE_MIN_POINTS) {
    if (is.na(out$noise) || out$noise <= 0) {
      # a perfectly constant trace is not a peak either
      if (height <= 0) {
        out$presence <- "absent"
        out$reason <- "flat XIC (no intensity variation) - no peak in this sample"
        return(out)
      }
    } else if (out$snr < snr_cut) {
      out$presence <- "absent"
      out$reason <- sprintf(
        "peak height %.0f is only %.1fx the point-to-point noise (absent_snr = %.1f)",
        height, out$snr, snr_cut)
      return(out)
    }
  }

  out
}

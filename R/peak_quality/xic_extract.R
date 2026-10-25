# ============================================================
# XIC extraction for the Peak Quality module
# ============================================================
# Reuses the project-wide unified reader read_ms_file()
# (shiny_app/server/FeatureGeter_server.R). No second parser exists here:
# this file only decides *which* MS1 scans to look at and how the peaks
# inside the m/z window are collapsed into one intensity per scan.
#
# Documented extraction strategy
# -----------------------------
# * Only scans with msLevel == 1 are used. MS2 precursor information
#   (scan_table$ms2_value) is never used as chromatographic intensity.
# * A scan contributes a point only if at least one peak falls inside
#   [mz - tol, mz + tol]. Scans without a peak in the window are *absent*
#   from the XIC - they are NOT replaced by zero. This matches the upstream
#   pipeline, which only sees rows that exist in the EIC table; the author's
#   beta fit explicitly "accounts for missed scans" by scaling RT into
#   [0, 1]. The number of missing scans is reported per feature.
# * Several peaks inside the window in one scan are collapsed by
#   `aggregate`:
#       "max"     highest intensity (default)
#       "nearest" peak whose m/z is closest to the target
#       "sum"     sum of all intensities
#       "mean"    mean intensity
#   The applied strategy is stored with every result row and printed in the
#   report. Nothing is summed unless the user explicitly asks for "sum".
# ============================================================

# ------------------------------------------------------------
# Load a raw file and prepare it for repeated XIC extraction
# ------------------------------------------------------------
# The project-wide reader is called unchanged (read_ms_file(filepath)); the
# MS1-only view is then derived here, so this module can never drift away
# from the behaviour of Ms1Geter / Ms2Geter.
#
# Known performance limit: read_ms_file() parses every scan of the file
# (profile mode), which costs ~50 s for a 57 MB Thermo .raw on this machine.
# Parsed files are cached per run, so the cost is paid once per file, not
# once per feature.
pq_load_ms_file <- function(filepath, ms_level = 1) {
  t0 <- Sys.time()
  ms <- read_ms_file(filepath)
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  if (!is.null(ms_level)) {
    keep <- ms$scan_table$msLevel %in% ms_level
    ms$scan_table <- ms$scan_table[keep, , drop = FALSE]
    rownames(ms$scan_table) <- NULL
    ms$spectra <- ms$spectra[as.character(ms$scan_table$scan)]
  }

  ms <- pq_prepare_ms(ms)
  ms$read_seconds <- elapsed
  ms$filepath <- filepath
  ms
}

# Sort peak m/z inside every spectrum once, so per-feature window lookups can
# use findInterval() instead of a linear scan.
pq_prepare_ms <- function(ms) {
  sp <- ms$spectra
  for (i in seq_along(sp)) {
    mz <- as.numeric(sp[[i]]$mz)
    it <- as.numeric(sp[[i]]$intensity)
    if (length(mz) > 1) {
      o <- order(mz)
      mz <- mz[o]
      it <- it[o]
    }
    sp[[i]] <- list(mz = mz, intensity = it)
  }
  ms$spectra <- sp
  ms
}

# ------------------------------------------------------------
# MS1 scan index (scan numbers + retention times, in minutes)
# ------------------------------------------------------------
pq_ms1_index <- function(ms) {
  st <- ms$scan_table
  keep <- which(st$msLevel == 1)
  if (length(keep) == 0) {
    return(list(scan = numeric(), rt = numeric(), spectra = character()))
  }
  keep <- keep[order(st$StartTime[keep])]
  list(
    scan = as.numeric(st$scan[keep]),
    rt = as.numeric(st$StartTime[keep]),
    spectra = as.character(st$scan[keep])
  )
}

# ------------------------------------------------------------
# m/z tolerance window
# ------------------------------------------------------------
pq_mz_window <- function(target_mz, tol_value, tol_unit) {
  if (identical(tol_unit, "Da")) {
    c(target_mz - tol_value, target_mz + tol_value)
  } else {
    d <- target_mz * tol_value * 1e-6
    c(target_mz - d, target_mz + d)
  }
}

# ------------------------------------------------------------
# Collapse the peaks inside the window of one scan
# ------------------------------------------------------------
pq_collapse_window <- function(mz, intensity, target_mz, aggregate) {
  if (length(mz) == 0) {
    return(list(intensity = NA_real_, n_mz = 0L, nearest_mz = NA_real_))
  }
  if (aggregate == "max") {
    val <- max(intensity)
  } else if (aggregate == "sum") {
    val <- sum(intensity)
  } else if (aggregate == "mean") {
    val <- mean(intensity)
  } else {
    val <- intensity[which.min(abs(mz - target_mz))]
  }
  list(
    intensity = as.numeric(val),
    n_mz = length(mz),
    nearest_mz = mz[which.min(abs(mz - target_mz))]
  )
}

# ------------------------------------------------------------
# Main XIC extractor
# ------------------------------------------------------------
# ms            : object from pq_load_ms_file()
# ms1           : pq_ms1_index(ms) (can be reused across features)
# target_mz     : feature m/z
# input_rt      : peak-table apex RT, in MINUTES
# rt_half_window: half search window, in MINUTES
# Returns list(xic, diag, status, reason); status is "ok" when the XIC has at
# least one point, otherwise "no_ms1_scans" / "no_signal".
pq_extract_xic <- function(ms, ms1, target_mz, input_rt, rt_half_window,
                           mz_tol_value, mz_tol_unit, aggregate = "max") {
  win <- pq_mz_window(target_mz, mz_tol_value, mz_tol_unit)
  rt_lo <- input_rt - rt_half_window
  rt_hi <- input_rt + rt_half_window

  in_win <- which(ms1$rt >= rt_lo & ms1$rt <= rt_hi)

  empty_xic <- data.frame(
    rt = numeric(), intensity = numeric(), scan = numeric(),
    n_mz = integer(), ppm_dev = numeric(),
    stringsAsFactors = FALSE
  )

  diag <- list(
    target_mz = target_mz,
    mz_min = win[1], mz_max = win[2],
    mz_tol_value = mz_tol_value, mz_tol_unit = mz_tol_unit,
    rt_lo = rt_lo, rt_hi = rt_hi, input_rt = input_rt,
    rt_half_window = rt_half_window,
    aggregate = aggregate,
    n_scans_in_window = length(in_win),
    n_scans_with_signal = 0L,
    n_scans_missing = length(in_win),
    n_scans_multi = 0L,
    n_mz_matched = 0L,
    median_ppm_dev = NA_real_,
    noise = NA_real_
  )

  if (length(in_win) == 0) {
    return(list(xic = empty_xic, diag = diag, status = "no_ms1_scans",
                reason = "no MS1 scan inside the RT search window"))
  }

  rt_v <- numeric(length(in_win))
  int_v <- numeric(length(in_win))
  scan_v <- numeric(length(in_win))
  nmz_v <- integer(length(in_win))
  ppm_v <- numeric(length(in_win))

  for (k in seq_along(in_win)) {
    j <- in_win[k]
    sp <- ms$spectra[[ms1$spectra[j]]]
    rt_v[k] <- ms1$rt[j]
    scan_v[k] <- ms1$scan[j]

    if (is.null(sp) || length(sp$mz) == 0) {
      int_v[k] <- NA_real_; nmz_v[k] <- 0L; ppm_v[k] <- NA_real_
      next
    }

    lo_i <- findInterval(win[1], sp$mz, left.open = TRUE) + 1L
    hi_i <- findInterval(win[2], sp$mz)

    if (lo_i > hi_i) {
      int_v[k] <- NA_real_; nmz_v[k] <- 0L; ppm_v[k] <- NA_real_
      next
    }

    sel <- lo_i:hi_i
    mzs <- sp$mz[sel]
    its <- sp$intensity[sel]
    ok <- its > 0
    mzs <- mzs[ok]; its <- its[ok]

    if (length(mzs) == 0) {
      int_v[k] <- NA_real_; nmz_v[k] <- 0L; ppm_v[k] <- NA_real_
      next
    }

    col <- pq_collapse_window(mzs, its, target_mz, aggregate)
    int_v[k] <- col$intensity
    nmz_v[k] <- col$n_mz
    ppm_v[k] <- (col$nearest_mz - target_mz) / target_mz * 1e6
  }

  has_signal <- is.finite(int_v) & int_v > 0

  diag$n_scans_with_signal <- sum(has_signal)
  diag$n_scans_missing <- length(in_win) - sum(has_signal)
  diag$n_scans_multi <- sum(nmz_v > 1)
  diag$n_mz_matched <- sum(nmz_v)
  if (any(has_signal & is.finite(ppm_v))) {
    diag$median_ppm_dev <- stats::median(ppm_v[has_signal & is.finite(ppm_v)])
  }

  if (!any(has_signal)) {
    return(list(xic = empty_xic, diag = diag, status = "no_signal",
                reason = "no peak inside the m/z tolerance window in any MS1 scan"))
  }

  xic <- data.frame(
    rt = rt_v[has_signal],
    intensity = int_v[has_signal],
    scan = scan_v[has_signal],
    n_mz = nmz_v[has_signal],
    ppm_dev = ppm_v[has_signal],
    stringsAsFactors = FALSE
  )
  xic <- xic[order(xic$rt), , drop = FALSE]
  rownames(xic) <- NULL

  # Point-to-point noise of the chromatogram, estimated from successive
  # differences (robust to the peak itself, which only adds variance where the
  # slope is steep). Used ONLY to decide whether the compound is present in
  # this sample - it never enters the author's scoring function.
  diag$noise <- pq_point_noise(xic$intensity)

  list(xic = xic, diag = diag, status = "ok", reason = NA_character_)
}

# Robust estimate of the point-to-point noise of an intensity trace.
#   sigma = 1.4826 * MAD(diff(y)) / sqrt(2)
# Returns NA when there are fewer than 3 points (cannot be estimated).
pq_point_noise <- function(y) {
  y <- as.numeric(y)
  y <- y[is.finite(y)]
  if (length(y) < 3) return(NA_real_)
  d <- diff(y)
  s <- stats::mad(d, constant = 1.4826) / sqrt(2)
  if (!is.finite(s)) return(NA_real_)
  s
}

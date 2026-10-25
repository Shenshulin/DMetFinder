# ============================================================
# Adapter between the project data structures and the vendored author
# scoring function (R/peak_quality/vendor/squallms_qscore.R).
# ============================================================
# The adapter is allowed to
#   1. convert inputs into the shape the author function expects,
#   2. call the author function,
#   3. normalise the output (named list, status, failure reason).
# It must NOT change the algorithm. No arithmetic here.
# ============================================================

# ------------------------------------------------------------
# Input normalisation, faithfully documented
# ------------------------------------------------------------
# The author function assumes `int` is already ordered by `rt` (upstream
# RaMS/XCMC code sorts the EIC table before calling it) and that rt/int are
# the same length. Our XIC table is built per scan, so it is already sorted,
# but we sort defensively and collapse duplicated retention times
# (same RT twice in one file) by their maximum intensity - which is exactly
# what a per-scan XIC should contain. The number of collapsed rows is
# returned so it can be audited.
pq_prepare_scoring_input <- function(rt, intensity) {
  rt <- suppressWarnings(as.numeric(rt))
  intensity <- suppressWarnings(as.numeric(intensity))

  keep <- is.finite(rt) & is.finite(intensity)
  n_dropped_na <- sum(!keep)
  rt <- rt[keep]
  intensity <- intensity[keep]

  if (length(rt) == 0) {
    return(list(rt = numeric(), intensity = numeric(),
                n_dropped_na = n_dropped_na, n_duplicate_rt = 0L))
  }

  ord <- order(rt)
  rt <- rt[ord]
  intensity <- intensity[ord]

  dup <- duplicated(rt)
  n_dup <- sum(dup)
  if (n_dup > 0) {
    # keep max intensity per RT (never a sum: summing would invent signal)
    agg <- tapply(intensity, rt, max)
    rt <- as.numeric(names(agg))
    intensity <- as.numeric(agg)
  }

  list(rt = rt, intensity = intensity,
       n_dropped_na = n_dropped_na, n_duplicate_rt = as.integer(n_dup))
}

# ------------------------------------------------------------
# Score one XIC with the author function
# ------------------------------------------------------------
# Returns a one-row data.frame so it can be rbind()-ed into the report.
# `score_status` values:
#   "ok"        - function returned two finite numbers
#   "skipped"   - fewer than 5 points (author's own guard)
#   "failed"    - the author function raised an error (e.g. a perfectly
#                 flat XIC makes cor() return NA -> "incompatible dimensions")
#   "not_finite"- function ran but produced NA/NaN/Inf
pq_score_xic <- function(rt, intensity) {
  prep <- pq_prepare_scoring_input(rt, intensity)

  out <- data.frame(
    n_points_used = length(prep$rt),
    n_dropped_na  = prep$n_dropped_na,
    n_duplicate_rt = prep$n_duplicate_rt,
    peak_cor = NA_real_,
    SNR = NA_real_,
    score_status = "skipped",
    failure_reason = NA_character_,
    stringsAsFactors = FALSE
  )

  if (length(prep$rt) < 5) {
    out$failure_reason <- "fewer than 5 scans (author guard: length(rt) < 5)"
    return(out)
  }

  res <- tryCatch(
    pq_vendor_qscoreCalculator(prep$rt, prep$intensity),
    error = function(e) structure(list(message = conditionMessage(e)),
                                  class = "pq_score_error")
  )

  if (inherits(res, "pq_score_error")) {
    out$score_status <- "failed"
    out$failure_reason <- paste0("author function error: ", res$message)
    return(out)
  }

  out$peak_cor <- unname(res[["beta_cor"]])
  out$SNR <- unname(res[["beta_snr"]])

  if (!is.finite(out$peak_cor) || !is.finite(out$SNR)) {
    out$score_status <- "not_finite"
    out$failure_reason <- "author function returned NA/NaN/Inf"
    return(out)
  }

  out$score_status <- "ok"
  out
}

# ------------------------------------------------------------
# Human-readable provenance block (used by the report export)
# ------------------------------------------------------------
pq_provenance_lines <- function(dnn = "auto") {
  p <- PQ_PROVENANCE
  base <- c(
    paste0("Peak Quality engine        : DMetFinder ", PQ_ENGINE_VERSION,
           " / peak_quality module"),
    paste0("Paper                      : ", p$paper$title),
    paste0("                             ", p$paper$journal,
           ", doi:", p$paper$doi),
    paste0("Scoring function executed  : ", p$squallms$function_name,
           "() from ", p$squallms$repo),
    paste0("  package version / commit : ", p$squallms$package_version, " / ",
           p$squallms$commit, " (", p$squallms$commit_date, ")"),
    paste0("  file                     : ", p$squallms$file),
    paste0("  license                  : ", p$squallms$license),
    paste0("  local modifications      : none (vendored verbatim)"),
    paste0("Original paper code        : ", p$ms_metrics$repo),
    paste0("  commit / file            : ", p$ms_metrics$commit, " / ",
           p$ms_metrics$file),
    paste0("  license                  : ", p$ms_metrics$license),
    paste0("  equivalence              : identical arithmetic; squallms adds NA",
           " filtering and returns a named vector"),
    paste0("R session                  : R ", getRversion(), " (",
           R.version$platform, ")"),
    paste0("Exported at                : ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  )
  # The DNN block is appended automatically so every export carries the model
  # identity — or an explicit statement that there is no model. Silence about a
  # method is worse than a method that says it did not run.
  if (identical(dnn, "auto")) {
    dnn <- tryCatch(
      if (exists("pq_dnn_provenance_lines")) pq_dnn_provenance_lines() else NULL,
      error = function(e) paste0("DNN block unavailable: ", conditionMessage(e)))
  }
  if (!is.null(dnn) && length(dnn) > 0) base <- c(base, dnn)
  base
}

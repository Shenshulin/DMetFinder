# ============================================================
# Peak Quality - feature-level summary (aligned-table mode)
# ============================================================
# An aligned table (MS-DIAL / MZmine) describes a feature once for the whole
# cohort, so the module evaluates it in every raw file. The per-sample rows are
# the evidence; this file condenses them back to one row per feature.
#
# Presence is handled explicitly. A feature that is absent from a sample is
# not a bad score: the percentages below are always computed over the samples
# where the peak was actually present (n_present), and n_absent is reported
# next to them. Without that, a compound found in 5 of 20 samples would look
# like a 75% failure rate.
#
# IMPORTANT: this is a DESCRIPTIVE summary. It reports how consistent the
# per-sample results are (median and worst value are both kept). It does not
# decide whether a feature is "good", and peak_cor / SNR are never converted
# into a probability or a pass/fail verdict.
# ============================================================

pq_summary_columns <- c(
  "feature_id", "mz", "input_rt",
  "n_samples", "n_present", "n_absent", "n_unknown",
  "n_scored", "n_unsuccessful",
  "n_boundary_ok", "n_ambiguous",
  "pct_scored", "pct_boundary_ok", "pct_absent",
  "median_peak_cor", "min_peak_cor",
  "median_SNR", "min_SNR",
  "median_apex_offset", "median_abs_apex_offset", "max_abs_apex_offset",
  "median_ppm_dev",
  "consistency", "consistency_label"
)

pq_empty_summary <- function() {
  out <- as.data.frame(
    matrix(NA, nrow = 0, ncol = length(pq_summary_columns),
           dimnames = list(NULL, pq_summary_columns)),
    stringsAsFactors = FALSE)
  out
}

med <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  stats::median(x)
}
mn <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  min(x)
}
mx <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  max(x)
}

# ------------------------------------------------------------
# rows       : data.frame returned by pq_process_features()$rows
# thresholds : list from pq_summary_thresholds()
# ------------------------------------------------------------
pq_feature_summary <- function(rows, thresholds = pq_summary_thresholds()) {
  if (is.null(rows) || nrow(rows) == 0) return(pq_empty_summary())

  if (is.null(rows$presence)) rows$presence <- "present"

  keys <- unique(as.character(rows$feature_id))
  one <- function(k) {
    r <- rows[as.character(rows$feature_id) == k, , drop = FALSE]
    n_samples <- nrow(r)

    absent  <- sum(r$presence %in% "absent", na.rm = TRUE)
    present <- sum(r$presence %in% "present", na.rm = TRUE)
    unknown <- n_samples - absent - present

    # a row counts as scored only when the status says so AND a value exists
    scored    <- sum(r$score_status %in% "ok" & !is.na(r$peak_cor), na.rm = TRUE)
    b_ok      <- sum(r$boundary_status %in% "ok" & r$presence %in% "present",
                     na.rm = TRUE)
    ambig     <- sum(r$boundary_status %in% "ambiguous" & r$presence %in% "present",
                     na.rm = TRUE)

    denom  <- if (present > 0) present else NA_real_
    frac   <- if (!is.na(denom)) scored / denom else NA_real_
    bfrac  <- if (!is.na(denom)) b_ok / denom else NA_real_
    afrac  <- if (n_samples > 0) absent / n_samples else NA_real_

    cons <- if (present == 0 && absent > 0) {
      "absent_everywhere"
    } else if (scored == 0) {
      "not_evaluated"
    } else if (present == 1) {
      "single_sample"
    } else if (frac >= thresholds$min_scored_frac_consistent &&
               bfrac >= thresholds$min_boundary_frac_consistent) {
      "consistent"
    } else if (frac >= thresholds$min_scored_frac_variable) {
      "variable"
    } else {
      "poor"
    }

    # only rows where the peak was present contribute to the score statistics
    rp <- r[r$presence %in% "present", , drop = FALSE]

    data.frame(
      feature_id             = k,
      mz                     = r$mz[1],
      input_rt               = r$input_rt[1],
      n_samples              = n_samples,
      n_present              = present,
      n_absent               = absent,
      n_unknown              = unknown,
      n_scored               = scored,
      n_unsuccessful         = present - scored,
      n_boundary_ok          = b_ok,
      n_ambiguous            = ambig,
      pct_scored             = round(100 * frac, 1),
      pct_boundary_ok        = round(100 * bfrac, 1),
      pct_absent             = round(100 * afrac, 1),
      median_peak_cor        = round(med(rp$peak_cor), 5),
      min_peak_cor           = round(mn(rp$peak_cor), 5),
      median_SNR             = round(med(rp$SNR), 4),
      min_SNR                = round(mn(rp$SNR), 4),
      median_apex_offset     = round(med(rp$apex_offset), 4),
      median_abs_apex_offset = round(med(abs(rp$apex_offset)), 4),
      max_abs_apex_offset    = round(mx(abs(rp$apex_offset)), 4),
      median_ppm_dev         = round(med(rp$median_ppm_dev), 3),
      consistency            = cons,
      consistency_label      = pq_summary_label(cons),
      stringsAsFactors = FALSE
    )
  }

  out <- do.call(rbind, lapply(keys, one))
  rownames(out) <- NULL

  # worst first so that a review pass sees the problems at the top
  rank <- c(poor = 1L, variable = 2L, single_sample = 3L, consistent = 4L,
            absent_everywhere = 5L, not_evaluated = 6L)
  out <- out[order(match(out$consistency, names(rank)),
                   out$median_peak_cor, na.last = TRUE), , drop = FALSE]
  rownames(out) <- NULL
  out
}

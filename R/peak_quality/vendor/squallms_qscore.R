# ============================================================
# VENDORED THIRD-PARTY CODE - DO NOT EDIT
# ============================================================
# Source : squallms (author-maintained successor of MS_metrics)
#   repo      https://github.com/wkumler/squallms
#   commit    2f4038ce401b2415c36daeab5928957c214a3205  (2026-09-02)
#   version   0.99.7
#   file      R/extractChromMetricsFunctions.R  lines 21-56
#   license   MIT + file LICENSE  (Copyright (c) 2024 William Kumler)
#   paper     Kumler et al. 2023, BMC Bioinformatics 24:436
#             https://doi.org/10.1186/s12859-023-05533-4
#
# The paper's original implementation lives in
#   https://github.com/wkumler/MS_metrics  feature_extraction.R  lines 116-149
#   (commit 491deaf1d5f27f9d276e58acb4c1dfca2a2e21b9). That repository ships
#   NO license file, so its source is NOT redistributed in this project.
#   The function below is numerically identical to it: the only differences
#   are (a) NA filtering of `rt`/`int` at the top, (b) `vapply` instead of
#   `sapply`, and (c) a named numeric vector instead of a list as return
#   value. The scoring arithmetic (beta fit over skews 2.5/3/4/5,
#   shape2 = 5, normalized residuals, diff-based SD loop, SNR formula) is
#   character-for-character the same.
#
# Local modifications: NONE. The function body below is copied verbatim.
# Anything this project needs (sorting, de-duplication, error capture) lives
# in R/peak_quality/score_adapter.R and never touches this file.
# ============================================================

qscoreCalculator <- function(rt, int, na.rm = TRUE) {
    rt <- rt[!is.na(rt)]
    int <- int[!is.na(int)]
    # Check for bogus EICs
    if (length(rt) < 5) {
        return(c(beta_snr = NA, beta_cor = NA))
    }
    # Calculate where each rt would fall on a beta dist (accounts for missed scans)
    scaled_rts <- (rt - min(rt)) / (max(rt) - min(rt))

    # Create a couple different skews and test fit
    maybe_skews <- c(2.5, 3, 4, 5) # Add 7 to catch more multipeaks and more noise
    # Add 2 to catch very slopey peaks and more noise
    best_skew <- maybe_skews[which.max(vapply(maybe_skews, function(x) {
        cor(dbeta(scaled_rts, shape1 = x, shape2 = 5), int)
    }, numeric(1)))]
    perf_peak <- dbeta(scaled_rts, shape1 = best_skew, shape2 = 5)
    peak_cor <- cor(perf_peak, int)


    # Calculate the normalized residuals
    residuals <- int / max(int) - perf_peak / max(perf_peak)
    # Calculate the minimum SD, after normalizing for any shape discrepancy
    old_res_sd <- sd(residuals)
    norm_residuals <- diff(residuals)
    new_res_sd <- sd(norm_residuals)
    while (new_res_sd < old_res_sd) {
        old_res_sd <- new_res_sd
        norm_residuals <- diff(residuals)
        new_res_sd <- sd(residuals)
    }
    # Calculate SNR
    SNR <- (max(int) - min(int)) / sd(norm_residuals * max(int))
    # Return the quality score
    return(c(beta_snr = SNR, beta_cor = peak_cor))
}

# Stable alias used by R/peak_quality/score_adapter.R so that a future
# `library(squallms)` in the same session cannot shadow the scoring path.
pq_vendor_qscoreCalculator <- qscoreCalculator

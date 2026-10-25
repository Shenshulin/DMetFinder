# ============================================================
# Peak Quality - four-class quality verdict (PROVISIONAL)
# ============================================================
# The module must let the user see "good / poor / noise / cannot tell", but it
# must not present an unvalidated threshold set as a trained classifier.
#
# What this file is
#   * a *documented rule draft* over the author metrics and the diagnostics
#     that already exist in the result table,
#   * every verdict carries the rule id that fired, the numbers behind it and
#     the list of methods that produced no result,
#   * every verdict is stamped `quality_class_verified = FALSE` until an
#     independent, blind-labelled benchmark exists.
#
# What this file is NOT
#   * it does not train or load a model,
#   * it does not combine methods: CPC never changes the verdict. CPC values
#     are attached as corroboration only, so no cross-method score exists,
#   * it never classifies an `absent` row as noise. "No detectable signal in
#     this window" is not evidence of a noise peak; it is evidence that this
#     sample does not answer the question.
#   * it does not delete or reorder anything.
#
# Rule order (first match wins, so the verdict is always explainable by ONE
# rule id):
#   R1 presence unknown        -> unknown   (file/scan unusable)
#   R2 presence absent         -> unknown   (no signal; NOT noise)
#   R3 score_status != ok      -> unknown   (method produced no number)
#   R4 boundary_status != ok   -> unknown   (shape metrics not interpretable)
#   R5 presence_snr < noise    -> likely_noise
#   R6 peak_cor < poor         -> poor_quality
#   R7 peak_cor >= good AND presence_snr >= good_snr -> high_quality
#   R8 otherwise               -> unknown   (the middle band)
#
# Threshold provenance is stated per threshold in pq_quality_rules()$source.
# None of them comes from a fitted model; they are round numbers chosen so
# that the middle band stays `unknown` instead of being forced into a class.
# ============================================================

PQ_QUALITY_CLASSES <- c("high_quality", "poor_quality", "likely_noise", "unknown")

PQ_QUALITY_LABELS <- c(
  high_quality = "High quality",
  poor_quality = "Poor quality",
  likely_noise = "Likely noise",
  unknown      = "Cannot tell"
)

pq_quality_label <- function(x) {
  lab <- PQ_QUALITY_LABELS[as.character(x)]
  lab[is.na(lab)] <- as.character(x)[is.na(lab)]
  as.character(lab)
}

# ------------------------------------------------------------
# Rule thresholds, with their provenance
# ------------------------------------------------------------
# `verified = FALSE` is the only honest value until a blind benchmark exists.
# Changing any number here changes every verdict; the tests pin the mapping
# from (peak_cor, presence_snr, boundary_status) to a class id.
pq_quality_rules <- function() {
  list(
    version  = "provisional-1",
    verified = FALSE,
    # The author's own guard: qscoreCalculator() returns NA below 5 scans.
    # Reusing it here means we never ask for a verdict the author refuses to
    # compute.
    min_points_for_shape = 5L,
    # Shape: correlation between the intensity trace and the best-fitting
    # beta density. Range -1..1 in theory, ~0..1 in practice.
    peak_cor_good = 0.80,
    peak_cor_poor = 0.50,
    # Signal: peak height over the point-to-point noise of the same XIC.
    # `snr_noise` is deliberately below `absent_snr` (5 in the default
    # parameters): a row that reached this rule is already `present`, so this
    # value means "present, but only barely above the noise".
    snr_noise = 3,
    snr_good  = 10,
    source = list(
      min_points_for_shape = "author code: qscoreCalculator() guard, not a choice of this project",
      peak_cor_good = "round number, NOT validated on labelled peaks",
      peak_cor_poor = "round number, NOT validated on labelled peaks",
      snr_noise = "round number below absent_snr, NOT validated on labelled peaks",
      snr_good = "round number, NOT validated on labelled peaks"
    ),
    note = paste(
      "These thresholds are a rule DRAFT. They are not a trained classifier",
      "and no accuracy is claimed for them. A verdict of 'unknown' is the",
      "correct answer whenever the rules cannot separate the cases."
    )
  )
}

# ------------------------------------------------------------
# Which methods have no result, and why
# ------------------------------------------------------------
# Recorded on every row so a reader of the export can tell "this peak is bad"
# from "this method never ran on this row".
pq_missing_methods_string <- function(cpc_available = NULL) {
  if (is.null(cpc_available)) {
    av <- tryCatch(pq_cpc_available(), error = function(e) list(ok = FALSE,
                                                                reason = "probe failed"))
    cpc_available <- isTRUE(av$ok)
  }
  parts <- character(0)
  if (!isTRUE(cpc_available)) {
    parts <- c(parts, "cpc:not_installed")
  }
  parts <- c(parts, "dnn:no_published_weights")
  paste(parts, collapse = "; ")
}

# ------------------------------------------------------------
# The classifier
# ------------------------------------------------------------
# rows : the per-(feature, sample) result table of pq_process_features()
# cpc  : optional data.frame aligned BY POSITION with `rows` (cpc_* columns)
# p    : params list (used for the absent/noise thresholds when present)
# Returns `rows` with the verdict columns appended. Row order is untouched.
pq_classify_rows <- function(rows, cpc = NULL, params = NULL,
                             rules = pq_quality_rules()) {
  # NULL in, NULL out. The old code fell through to the 0-row branch below and
  # returned a LIST of empty columns (`out <- rows` is NULL, then the loop turns
  # it into a list), which is neither a table nor NULL: nrow() on it is not 0,
  # so `if (nrow(x) == 0)` blew up in the caller with "missing value where
  # TRUE/FALSE needed" and `x[i, j]` with "incorrect number of dimensions".
  if (is.null(rows)) return(NULL)
  if (nrow(rows) == 0) {
    out <- rows
    for (cc in c("quality_class", "quality_rule", "quality_reason",
                 "quality_evidence", "quality_methods_missing",
                 "quality_class_version", "quality_class_verified",
                 "quality_corroboration")) {
      out[[cc]] <- if (cc == "quality_class_verified") logical(0) else character(0)
    }
    return(out)
  }

  n <- nrow(rows)
  cls      <- rep("unknown", n)
  rule     <- rep("R0", n)
  reason   <- rep(NA_character_, n)
  evidence <- rep(NA_character_, n)

  has_cpc <- !is.null(cpc) && nrow(cpc) == n
  missing_methods <- pq_missing_methods_string(if (has_cpc) TRUE else NULL)

  # Column access that tolerates a missing column (older result tables).
  col_chr <- function(df, nm) {
    if (nm %in% names(df)) as.character(df[[nm]]) else rep(NA_character_, nrow(df))
  }
  col_num <- function(df, nm) {
    if (nm %in% names(df)) suppressWarnings(as.numeric(df[[nm]])) else rep(NA_real_, nrow(df))
  }

  presence <- col_chr(rows, "presence")
  bstatus  <- col_chr(rows, "boundary_status")
  sstatus  <- col_chr(rows, "score_status")
  freason  <- col_chr(rows, "failure_reason")
  pcor     <- col_num(rows, "peak_cor")
  psnr     <- col_num(rows, "presence_snr")
  npts     <- col_num(rows, "n_points")

  # A missing reason must read as "no reason recorded", never as character(0):
  # assigning a zero-length value into reason[i] would abort the whole run.
  why <- function(i) ifelse(is.na(freason[i]), "no reason recorded", freason[i])

  fmt <- function(x, d = 3) {
    ifelse(is.na(x), "NA", formatC(x, format = "f", digits = d))
  }

  # Compact, reproducible evidence string - the same fields in the same order.
  evid <- function(i) {
    paste0("peak_cor=", fmt(pcor[i]),
           "; presence_snr=", fmt(psnr[i], 2),
           "; n_points=", ifelse(is.na(npts[i]), "NA", as.character(as.integer(npts[i]))),
           "; boundary=", ifelse(is.na(bstatus[i]), "NA", bstatus[i]),
           "; presence=", ifelse(is.na(presence[i]), "NA", presence[i]))
  }

  for (i in seq_len(n)) {
    evidence[i] <- evid(i)
    pr <- presence[i]
    ss <- sstatus[i]
    bs <- bstatus[i]

    # ---- R1: the file / scan window could not be used -------------------
    if (is.na(pr) || identical(pr, "unknown")) {
      cls[i] <- "unknown"; rule[i] <- "R1"
      reason[i] <- paste0(
        "presence is unknown: the sample could not be evaluated (", why(i), ")")
      next
    }

    # ---- R2: no detectable signal -> NOT noise -------------------------
    if (identical(pr, "absent")) {
      cls[i] <- "unknown"; rule[i] <- "R2"
      reason[i] <- paste0(
        "no detectable signal in this m/z/RT window; ",
        "absence is not evidence of a noise peak, so no quality class is assigned (",
        why(i), ")")
      next
    }

    # ---- R3: a method ran but produced no usable number ----------------
    if (is.na(ss) || !identical(ss, "ok")) {
      cls[i] <- "unknown"; rule[i] <- "R3"
      reason[i] <- paste0(
        "no shape metric: score_status = ",
        ifelse(is.na(ss), "NA", ss), " (", why(i), ")")
      next
    }

    # ---- R4: shape metrics only mean something on a credible boundary --
    if (is.na(bs) || !identical(bs, "ok")) {
      cls[i] <- "unknown"; rule[i] <- "R4"
      reason[i] <- paste0(
        "boundary is not trustworthy (", ifelse(is.na(bs), "NA", bs),
        "); the scored slice would not be the peak, so no class is assigned")
      next
    }

    # From here on: present, scored, boundary ok.
    if (is.na(pcor[i])) {
      cls[i] <- "unknown"; rule[i] <- "R3"
      reason[i] <- "score_status is ok but peak_cor is empty"
      next
    }

    # ---- R5: signal barely above its own noise -------------------------
    if (!is.na(psnr[i]) && psnr[i] < rules$snr_noise) {
      cls[i] <- "likely_noise"; rule[i] <- "R5"
      reason[i] <- sprintf(
        "peak height is only %.1fx the point-to-point noise of the same XIC (threshold %.1f); the trace looks like noise rather than a peak",
        psnr[i], rules$snr_noise)
      next
    }

    # ---- R6: real signal, wrong shape ----------------------------------
    if (pcor[i] < rules$peak_cor_poor) {
      cls[i] <- "poor_quality"; rule[i] <- "R6"
      reason[i] <- sprintf(
        "peak_cor %.3f is below %.2f: the trace carries signal but does not follow any tested beta shape",
        pcor[i], rules$peak_cor_poor)
      next
    }

    # ---- R7: good shape + comfortable signal ---------------------------
    if (pcor[i] >= rules$peak_cor_good &&
        !is.na(psnr[i]) && psnr[i] >= rules$snr_good) {
      cls[i] <- "high_quality"; rule[i] <- "R7"
      reason[i] <- sprintf(
        "peak_cor %.3f >= %.2f and peak height %.1fx the noise >= %.1f",
        pcor[i], rules$peak_cor_good, psnr[i], rules$snr_good)
      next
    }

    # ---- R8: the middle band -------------------------------------------
    cls[i] <- "unknown"; rule[i] <- "R8"
    reason[i] <- sprintf(
      "intermediate evidence (peak_cor %.3f, presence_snr %s); the draft rules do not separate this case, so it stays unknown",
      pcor[i], fmt(psnr[i], 1))
  }

  # ---- corroboration only: CPC never changes the verdict ----------------
  corrob <- rep(NA_character_, n)
  if (has_cpc) {
    tf  <- col_num(cpc, "cpc_tf")
    csn <- col_num(cpc, "cpc_sn")
    cst <- col_chr(cpc, "cpc_status")
    for (i in seq_len(n)) {
      if (is.na(cst[i]) || !identical(cst[i], "ok")) {
        corrob[i] <- "cpc: no result"
      } else {
        bits <- character(0)
        if (!is.na(tf[i])) {
          bits <- c(bits, sprintf("tf=%.2f%s", tf[i],
                                  if (tf[i] > 3) " (strong tailing)" else ""))
        }
        if (!is.na(csn[i])) bits <- c(bits, sprintf("sn=%.1f", csn[i]))
        corrob[i] <- paste0("cpc: ", paste(bits, collapse = ", "))
      }
    }
  }

  rows$quality_class   <- cls
  rows$quality_rule    <- rule
  rows$quality_reason  <- reason
  rows$quality_evidence <- evidence
  rows$quality_corroboration <- corrob
  rows$quality_methods_missing <- missing_methods
  rows$quality_class_version <- rules$version
  # Written into every export: these verdicts are a draft, not a validated
  # classifier. Flip only after the benchmark in section 9 exists.
  rows$quality_class_verified <- isTRUE(rules$verified)
  rows
}

# ------------------------------------------------------------
# Summaries
# ------------------------------------------------------------
# Counts per class. `denominator` is reported explicitly because the honest
# denominator is NOT always "all rows": most rows of an aligned table are
# present-but-unscorable or absent.
pq_class_summary <- function(rows, by = NULL) {
  if (is.null(rows) || nrow(rows) == 0) {
    return(data.frame(quality_class = character(), n = integer(),
                      pct = numeric(), denominator = integer(),
                      stringsAsFactors = FALSE))
  }
  cls <- if ("quality_class" %in% names(rows)) as.character(rows$quality_class) else
    rep("unknown", nrow(rows))
  cls[is.na(cls)] <- "unknown"
  tab <- table(factor(cls, levels = PQ_QUALITY_CLASSES))
  n <- sum(tab)
  data.frame(
    quality_class = names(tab),
    quality_class_label = pq_quality_label(names(tab)),
    n = as.integer(tab),
    pct = if (n > 0) round(100 * as.integer(tab) / n, 2) else NA_real_,
    denominator = n,
    stringsAsFactors = FALSE
  )
}

# Wilson score interval - correct for proportions near 0/1 and for small n,
# unlike the normal approximation.
pq_wilson_ci <- function(k, n, conf = 0.95) {
  if (is.na(n) || n <= 0) return(c(NA_real_, NA_real_))
  z <- stats::qnorm(1 - (1 - conf) / 2)
  p <- k / n
  denom <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / denom
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom
  c(max(0, centre - half), min(1, centre + half))
}

# ------------------------------------------------------------
# Cross-software comparison (stage G)
# ------------------------------------------------------------
# One row per (software, quality class) plus the denominator and a 95% Wilson
# interval. The point is a like-for-like count of what each tool produced when
# every candidate was re-extracted from the same raw files under the same
# tolerances - NOT a comparison of the tools' own internal scores, which are
# never read by this module.
#
# Rows without a `software` value are grouped as "(not stated)" rather than
# dropped: an unknown provenance must stay visible.
pq_class_by_software <- function(rows, conf = 0.95) {
  if (is.null(rows) || nrow(rows) == 0) {
    return(data.frame(software = character(), quality_class = character(),
                      n = integer(), denominator = integer(), pct = numeric(),
                      ci_low = numeric(), ci_high = numeric(),
                      stringsAsFactors = FALSE))
  }
  sw <- if ("software" %in% names(rows)) as.character(rows$software) else
    rep(NA_character_, nrow(rows))
  sw[is.na(sw) | !nzchar(trimws(sw))] <- "(not stated)"
  sw <- trimws(sw)

  parts <- lapply(sort(unique(sw)), function(s) {
    sel <- sw == s
    tab <- pq_class_summary(rows[sel, , drop = FALSE])
    ci <- lapply(seq_len(nrow(tab)), function(i)
      pq_wilson_ci(tab$n[i], tab$denominator[i], conf))
    data.frame(
      software = s,
      quality_class = tab$quality_class,
      n = tab$n,
      denominator = tab$denominator,
      pct = tab$pct,
      ci_low = round(vapply(ci, function(x) 100 * x[1], numeric(1)), 2),
      ci_high = round(vapply(ci, function(x) 100 * x[2], numeric(1)), 2),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, parts)
  rownames(out) <- NULL
  out
}

# ------------------------------------------------------------
# Raw metric distribution per software (stage G)
# ------------------------------------------------------------
# Deliberately reports the DISTRIBUTION, not a ranking. A tool whose candidates
# are fewer and easier will look better on any per-candidate average, so the
# numbers must be read with the candidate count next to them.
pq_metrics_by_software <- function(rows) {
  if (is.null(rows) || nrow(rows) == 0) {
    return(data.frame(software = character(), metric = character(),
                      n = integer(), median = numeric(), q05 = numeric(),
                      q95 = numeric(), stringsAsFactors = FALSE))
  }
  sw <- if ("software" %in% names(rows)) as.character(rows$software) else
    rep(NA_character_, nrow(rows))
  sw[is.na(sw) | !nzchar(trimws(sw))] <- "(not stated)"
  sw <- trimws(sw)

  metrics <- intersect(c("peak_cor", "SNR", "presence_snr", "n_points",
                         "median_ppm_dev"), names(rows))
  if (length(metrics) == 0) {
    return(data.frame(software = character(), metric = character(),
                      n = integer(), median = numeric(), q05 = numeric(),
                      q95 = numeric(), stringsAsFactors = FALSE))
  }

  out <- list()
  for (s in sort(unique(sw))) {
    for (m in metrics) {
      v <- suppressWarnings(as.numeric(rows[[m]][sw == s]))
      v <- v[is.finite(v)]
      out[[length(out) + 1L]] <- data.frame(
        software = s, metric = m, n = length(v),
        median = if (length(v)) round(stats::median(v), 5) else NA_real_,
        q05 = if (length(v)) round(as.numeric(stats::quantile(v, 0.05, names = FALSE)), 5) else NA_real_,
        q95 = if (length(v)) round(as.numeric(stats::quantile(v, 0.95, names = FALSE)), 5) else NA_real_,
        stringsAsFactors = FALSE)
    }
  }
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

# Human-readable caveat that must accompany every cross-software table.
pq_software_compare_note <- function(rows) {
  n_sw <- if ("software" %in% names(rows)) {
    length(unique(stats::na.omit(as.character(rows$software))))
  } else 0L
  c(
    paste0("candidates re-extracted from the same raw files: ",
           nrow(rows), " (feature, sample) row(s), ", n_sw,
           " software value(s) stated"),
    paste("each row is one (feature, sample); rows of the same feature in",
          "different samples are NOT independent biological replicates, so",
          "the intervals describe row-level proportions only"),
    paste("a higher 'high_quality' share does not prove a better tool:",
          "the peak tables may cover different regions of the chromatogram,",
          "and a tool that reports fewer, easier peaks can win on proportion"),
    "absence and 'unknown' are reported, never merged into a quality class",
    paste("the class rules are a provisional draft",
          "(quality_class_version = ", pq_quality_rules()$version,
          ", verified = FALSE)", sep = "")
  )
}

# ------------------------------------------------------------
# Column dictionary for the export
# ------------------------------------------------------------
pq_quality_dictionary <- function() {
  r <- pq_quality_rules()
  data.frame(
    column = c("quality_class", "quality_rule", "quality_reason",
               "quality_evidence", "quality_corroboration",
               "quality_methods_missing", "quality_class_version",
               "quality_class_verified"),
    meaning = c(
      "high_quality | poor_quality | likely_noise | unknown (PROVISIONAL rule draft, not a trained classifier)",
      "id of the rule that produced the verdict (R1..R8); exactly one rule fires per row",
      "human-readable justification, including the reason a row stays 'unknown'",
      "the numbers behind the verdict, same fields and order on every row",
      "CPC values shown as corroboration ONLY; they never change the verdict",
      "methods that produced no result on this row, with the reason",
      paste0("rule-set version (", r$version, ")"),
      paste0("FALSE = the thresholds are not validated against a blind-labelled ",
             "benchmark; do not report these classes as a measured accuracy")
    ),
    stringsAsFactors = FALSE
  )
}

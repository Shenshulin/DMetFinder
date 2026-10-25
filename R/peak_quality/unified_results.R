# ============================================================
# Peak Quality - unified result structure
# ============================================================
# The task requires ONE result structure shared by all methods, with the
# fields
#   feature_id, sample_id, mz, input_rt, start_rt, apex_rt, end_rt, n_points,
#   method, raw_score, quality_probability, boundary_status, score_status,
#   failure_reason
# and three hard rules:
#   * raw_score holds a native value only, the metric name is stored next to
#     it (raw_score_name) and every native metric is also written to the
#     long MethodMetrics table;
#   * quality_probability is filled only when a model really produces a
#     probability - never inferred from a correlation or a ratio;
#   * scores of different methods are neither compared by magnitude nor
#     averaged. There is no composite score anywhere in this file.
#
# Which method contributes what
#   raw_score
#     Kumler  peak_cor (a correlation; NOT a probability)
#     CPC     NA - the package publishes a profile of metrics, not one
#             scalar; the native `sn` is not used as a stand-in because its
#             noise pool is contaminated (audit 2.4)
#     DNN     NA - no model weights exist, so nothing is predicted
#   quality_probability
#     only DNN could fill it, and it never runs in this build.
# ============================================================

PQ_UNIFIED_CORE <- c(
  "feature_id", "sample_id", "mz", "input_rt", "start_rt", "apex_rt",
  "end_rt", "n_points", "method", "raw_score", "quality_probability",
  "boundary_status", "score_status", "failure_reason"
)

# Traceability columns required by the task ("method version, parameters and
# input data must always remain traceable").
PQ_UNIFIED_TRACE <- c(
  "raw_score_name", "method_version", "method_params", "presence",
  "engine_version", "file", "xic_smoothing"
)

PQ_UNIFIED_COLUMNS <- c(PQ_UNIFIED_CORE, PQ_UNIFIED_TRACE)

pq_unified_dictionary <- function() {
  data.frame(
    column = PQ_UNIFIED_COLUMNS,
    meaning = c(
      "Feature identifier as supplied in the peak table",
      "Sample identifier; empty when the row was not bound to a sample",
      "Feature m/z used for the XIC",
      "Apex RT from the peak table (minutes)",
      "Peak start used by THIS method (minutes)",
      "Peak apex found by THIS method (minutes)",
      "Peak end used by THIS method (minutes)",
      "Scans inside the peak used by THIS method",
      "kumler | cpc | dnn",
      "Native scalar of the method, named in raw_score_name. Empty when the method has no single scalar (CPC, DNN). Never a composite score.",
      "Filled only when a model emits a probability. Empty for Kumler and CPC, and for DNN in this build (no weights).",
      "Method-wide boundary verdict: ok | ambiguous | boundary_unclear | too_few_points | no_signal | no_clear_apex | apex_outside | not_run",
      "Did the method produce a usable result: ok | absent | skipped | failed | not_detected | too_few_points | not_run | unavailable",
      "Why the row has no score, or what the boundary problem is",
      "Name of the metric stored in raw_score (peak_cor for Kumler; empty for CPC)",
      "Version of the executed code (package version or vendored commit)",
      "The parameters this method actually ran with, as key=value; (semicolon separated)",
      "Peak presence in this sample: present | absent | unknown",
      "Version of the Peak Quality engine that produced the row",
      "Raw file basename",
      "XIC smoothing applied before the analysis: 'none' (the scores are the author's raw-data output) or e.g. 'Savitzky-Golay (window 7, order 2)', in which case the values are NOT comparable to a raw run"
    ),
    stringsAsFactors = FALSE
  )
}

pq_unified_empty <- function() {
  df <- data.frame(
    feature_id = character(), sample_id = character(),
    mz = numeric(), input_rt = numeric(),
    start_rt = numeric(), apex_rt = numeric(), end_rt = numeric(),
    n_points = integer(),
    method = character(), raw_score = numeric(),
    quality_probability = numeric(),
    boundary_status = character(), score_status = character(),
    failure_reason = character(),
    raw_score_name = character(), method_version = character(),
    method_params = character(), presence = character(),
    engine_version = character(), file = character(),
    xic_smoothing = character(),
    stringsAsFactors = FALSE
  )
  df[, PQ_UNIFIED_COLUMNS, drop = FALSE]
}

# Compact, stable parameter string for one method.
pq_method_param_string <- function(x) {
  if (is.null(x) || length(x) == 0) return("")
  x <- x[!vapply(x, is.null, logical(1))]
  if (length(x) == 0) return("")
  vals <- vapply(x, function(v) {
    if (length(v) == 0) return("")
    paste(as.character(v), collapse = ",")
  }, character(1))
  paste0(names(x), "=", vals, collapse = ";")
}

# The Kumler parameters of a run, as recorded in its rows.
pq_kumler_param_string <- function(params) {
  if (is.null(params)) return("")
  keep <- intersect(c("mz_tol_unit", "mz_tol_ppm", "mz_tol_da", "xic_aggregate",
                      "rt_window", "min_points", "smooth_points",
                      "min_prominence_frac", "min_rel_prominence",
                      "min_height_frac", "edge_frac", "valley_frac",
                      "apex_tolerance", "detect_absent", "absent_snr"),
                    names(params))
  s <- pq_method_param_string(params[keep])
  # The XIC smoothing setting is part of how the score was produced: without
  # it a smoothed peak_cor could be read as the author's raw-data value.
  sm <- if (is.null(params$eic_smooth_method)) "none" else
    pq_eic_smooth_tag(params$eic_smooth_method,
                      params$eic_smooth_window,
                      params$eic_smooth_order)
  paste0(s, if (nzchar(s)) ";" else "", "xic_smoothing=", sm)
}

pq_cpc_param_string <- function(settings) {
  if (is.null(settings)) return("")
  pq_method_param_string(settings[c("smooth_method", "smooth_times",
                                    "smooth_win", "min_pts", "min_inf_width")])
}

# ------------------------------------------------------------
# Long unified table: one row per (feature, sample, method)
# ------------------------------------------------------------
# rows : the existing per-sample result table of the Kumler pipeline
# cpc  : data.frame aligned BY POSITION with `rows`, carrying cpc_* columns
#        (NULL when CPC was not run)
pq_unified_from_run <- function(rows, cpc = NULL, params = NULL,
                                cpc_settings = NULL,
                                engine_version = PQ_ENGINE_VERSION) {
  if (is.null(rows) || nrow(rows) == 0) return(pq_unified_empty())
  n <- nrow(rows)
  has_cpc <- !is.null(cpc)
  if (has_cpc && nrow(cpc) != n) {
    stop("cpc table must be aligned with the result rows", call. = FALSE)
  }

  kumler_params <- pq_kumler_param_string(params)
  kumler_ver <- pq_method_info("kumler")$provenance$commit
  cpc_ver <- {
    av <- pq_cpc_available()
    if (isTRUE(av$ok)) paste0("cpc ", av$version) else "cpc (not installed)"
  }

  n_rows <- if (has_cpc) n * 2L else n
  out <- pq_unified_empty()[rep(1L, n_rows), , drop = FALSE]
  rownames(out) <- NULL

  # Per row, not per run: a row whose trace was too short to smooth says so.
  has_sm <- "eic_smoothing" %in% names(rows)

  idx <- 0L
  for (i in seq_len(n)) {
    r <- rows[i, , drop = FALSE]
    absent <- identical(r$presence, "absent")
    sm_lab <- if (has_sm && !is.na(rows$eic_smoothing[i])) {
      rows$eic_smoothing[i]
    } else {
      "none"
    }

    # ---------------- Kumler ----------------
    idx <- idx + 1L
    out$feature_id[idx] <- r$feature_id
    out$sample_id[idx] <- r$sample_id
    out$mz[idx] <- r$mz
    out$input_rt[idx] <- r$input_rt
    out$start_rt[idx] <- r$start_rt
    out$apex_rt[idx] <- r$apex_rt
    out$end_rt[idx] <- r$end_rt
    out$n_points[idx] <- r$n_points
    out$method[idx] <- "kumler"
    out$raw_score[idx] <- if (absent) NA_real_ else r$peak_cor
    out$raw_score_name[idx] <- if (absent) NA_character_ else "peak_cor"
    out$quality_probability[idx] <- NA_real_
    out$boundary_status[idx] <- if (absent) NA_character_ else r$boundary_status
    out$score_status[idx] <- if (absent) "absent" else r$score_status
    out$failure_reason[idx] <- r$failure_reason
    out$method_version[idx] <- kumler_ver
    out$method_params[idx] <- kumler_params
    out$presence[idx] <- r$presence
    out$engine_version[idx] <- engine_version
    out$file[idx] <- r$file
    out$xic_smoothing[idx] <- sm_lab

    if (!has_cpc) next

    # ---------------- CPC ----------------
    idx <- idx + 1L
    c <- cpc[i, , drop = FALSE]
    out$feature_id[idx] <- r$feature_id
    out$sample_id[idx] <- r$sample_id
    out$mz[idx] <- r$mz
    out$input_rt[idx] <- r$input_rt
    out$start_rt[idx] <- c$cpc_rtmin
    out$apex_rt[idx] <- c$cpc_rt
    out$end_rt[idx] <- c$cpc_rtmax
    out$n_points[idx] <- c$cpc_n_points
    out$method[idx] <- "cpc"
    out$raw_score[idx] <- NA_real_
    out$raw_score_name[idx] <- NA_character_
    out$quality_probability[idx] <- NA_real_
    out$boundary_status[idx] <- c$cpc_boundary_status
    out$score_status[idx] <- if (absent) "absent" else
      ifelse(is.na(c$cpc_status), "not_run", c$cpc_status)
    out$failure_reason[idx] <- if (absent) r$failure_reason else c$cpc_reason
    out$method_version[idx] <- cpc_ver
    out$method_params[idx] <- pq_cpc_param_string(cpc_settings)
    out$presence[idx] <- r$presence
    out$engine_version[idx] <- engine_version
    out$file[idx] <- r$file
    out$xic_smoothing[idx] <- sm_lab
  }

  out
}

# ------------------------------------------------------------
# Long native-metric table: one row per (feature, sample, method, metric)
# ------------------------------------------------------------
# This is where "the specific metric names are stored separately" - the
# unified table only carries the single raw_score slot.
pq_metrics_long <- function(rows, cpc = NULL) {
  empty <- data.frame(feature_id = character(), sample_id = character(),
                      method = character(), metric = character(),
                      label = character(), unit = character(),
                      value = numeric(), note = character(),
                      status = character(), scope = character(),
                      model_version = character(),
                      stringsAsFactors = FALSE)
  if (is.null(rows) || nrow(rows) == 0) return(empty)

  kumler_ver <- pq_method_info("kumler")$provenance$commit
  cpc_av <- pq_cpc_available()
  cpc_ver <- if (isTRUE(cpc_av$ok)) paste0("cpc ", cpc_av$version) else
    "cpc (not installed)"

  metric_row <- function(fid, sid, method, metric, value, status, version) {
    d <- pq_metric_def(method, metric)
    data.frame(feature_id = fid, sample_id = sid, method = method,
               metric = metric, label = d$label, unit = d$unit,
               value = as.numeric(value), note = d$note,
               # `status` says whether the *method* produced this value for this
               # row; a metric can be NA either because the method failed or
               # because the sample does not contain the peak, and those are
               # different facts.
               status = status,
               scope = pq_method_scope(method),
               model_version = version,
               stringsAsFactors = FALSE)
  }

  # Kumler status: "absent" is a valid answer, not a failure.
  k_status <- ifelse(rows$presence %in% "absent", "absent",
                     ifelse(is.na(rows$score_status), "not_run",
                            rows$score_status))

  parts <- list()
  parts[[1]] <- rbind(
    metric_row(rows$feature_id, rows$sample_id, "kumler", "peak_cor",
               rows$peak_cor, k_status, kumler_ver),
    metric_row(rows$feature_id, rows$sample_id, "kumler", "SNR",
               rows$SNR, k_status, kumler_ver)
  )

  if (!is.null(cpc) && nrow(cpc) == nrow(rows)) {
    cpc_metrics <- c("rt", "rtmin", "rtmax", "fwhm", "wb", "a", "b", "tf",
                     "height", "area", "sn")
    c_status <- ifelse(is.na(cpc$cpc_status), "not_run", cpc$cpc_status)
    c_status[rows$presence %in% "absent"] <- "absent"
    for (m in cpc_metrics) {
      parts[[length(parts) + 1L]] <- metric_row(
        rows$feature_id, rows$sample_id, "cpc", m, cpc[[paste0("cpc_", m)]],
        c_status, cpc_ver)
    }
    # boundary codes are text, keep them in the wide table only
  }

  out <- do.call(rbind, parts)
  rownames(out) <- NULL
  out
}

# ------------------------------------------------------------
# Wide comparison table: one row per (feature, sample), one column per metric
# ------------------------------------------------------------
# Nothing is combined: every column belongs to exactly one method.
pq_wide_compare <- function(rows, cpc = NULL) {
  if (is.null(rows) || nrow(rows) == 0) return(NULL)

  base <- data.frame(
    feature_id = rows$feature_id,
    sample_id = rows$sample_id,
    mz = rows$mz,
    input_rt = rows$input_rt,
    presence = rows$presence,
    file = rows$file,
    stringsAsFactors = FALSE
  )
  base$kumler_score_status <- ifelse(rows$presence %in% "absent", "absent",
                                     rows$score_status)
  base$kumler_boundary_status <- rows$boundary_status
  base$kumler_start_rt <- rows$start_rt
  base$kumler_apex_rt <- rows$apex_rt
  base$kumler_end_rt <- rows$end_rt
  base$kumler_n_points <- rows$n_points
  base$kumler_peak_cor <- rows$peak_cor
  base$kumler_snr <- rows$SNR

  if (is.null(cpc) || nrow(cpc) != nrow(rows)) {
    base$method_agreement <- ifelse(rows$presence %in% "absent", "absent", "not_run")
    return(base)
  }

  wide <- cbind(base, cpc, stringsAsFactors = FALSE)

  kumler_ok <- !is.na(rows$score_status) & rows$score_status %in% "ok"
  cpc_ok <- !is.na(cpc$cpc_status) & cpc$cpc_status %in% "ok"
  absent <- rows$presence %in% "absent"

  wide$method_agreement <- ifelse(absent, "absent",
                            ifelse(kumler_ok & cpc_ok, "both_scored",
                            ifelse(kumler_ok, "kumler_only",
                            ifelse(cpc_ok, "cpc_only", "neither"))))
  wide$d_start_rt <- ifelse(kumler_ok & cpc_ok,
                            wide$cpc_rtmin - rows$start_rt, NA_real_)
  wide$d_apex_rt <- ifelse(kumler_ok & cpc_ok,
                           wide$cpc_rt - rows$apex_rt, NA_real_)
  wide$d_end_rt <- ifelse(kumler_ok & cpc_ok,
                          wide$cpc_rtmax - rows$end_rt, NA_real_)
  wide$same_boundary_verdict <- ifelse(kumler_ok & cpc_ok,
                                       rows$boundary_status == cpc$cpc_boundary_status,
                                       NA)
  wide
}

# Counts for the UI cards and the report. Never a quality judgement.
pq_agreement_summary <- function(wide) {
  if (is.null(wide) || nrow(wide) == 0) return(NULL)
  agr <- if ("method_agreement" %in% names(wide)) wide$method_agreement else
    rep("not_run", nrow(wide))
  core <- table(factor(agr, levels = c("both_scored", "kumler_only", "cpc_only",
                                       "neither", "absent", "not_run")))
  out <- data.frame(category = names(core), n = as.integer(core),
                    value = NA_real_, stringsAsFactors = FALSE)
  if ("d_apex_rt" %in% names(wide)) {
    d <- wide$d_apex_rt[is.finite(wide$d_apex_rt)]
    ds <- wide$d_start_rt[is.finite(wide$d_start_rt)]
    de <- wide$d_end_rt[is.finite(wide$d_end_rt)]
    out <- rbind(out, data.frame(
      category = c("median |d apex RT| (min)", "95th pct |d apex RT| (min)",
                   "median |d start RT| (min)", "median |d end RT| (min)"),
      n = NA_integer_,
      value = c(if (length(d)) stats::median(abs(d)) else NA_real_,
                if (length(d)) as.numeric(stats::quantile(abs(d), 0.95, names = FALSE)) else NA_real_,
                if (length(ds)) stats::median(abs(ds)) else NA_real_,
                if (length(de)) stats::median(abs(de)) else NA_real_),
      stringsAsFactors = FALSE))
  }
  rownames(out) <- NULL
  out
}

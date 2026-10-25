# ============================================================
# Peak Quality - the three published result tables
# ============================================================
# One place that turns the per-run objects into the three tables a reader
# actually consumes:
#
#   GroupResults   one row per feature   (the DNN's unit of analysis)
#   SampleResults  one row per feature x sample (CPC / Kumler's unit)
#   MethodMetrics  one row per method x metric (long, with units and status)
#
# The rules that shape every function here
# ----------------------------------------
# 1. Scope is never implicit. A DNN score is written with scope = "peak_group"
#    and repeated on each sample row by construction; CPC and Kumler values are
#    scope = "single_sample". `dnn_scope` is copied into the sample rows so a
#    reader who only opens SampleResults cannot mistake the group score for a
#    per-sample probability.
# 2. Absence is not failure. `presence = absent` keeps its own status and is
#    never rewritten as a low score, an error or a zero.
# 3. Missing stays missing. If a method did not run, its metric columns are NA
#    and its status says why; nothing is filled with 0 to look complete.
# 4. No composite. There is no total column, no weighted sum, no ranking. The
#    three methods answer three different questions and are stored side by
#    side.
# ============================================================

# ------------------------------------------------------------
# A. GroupResults - one row per feature
# ------------------------------------------------------------
# `rows` is the pipeline table (feature x sample). `dnn` is optional and is
# either the pq_dnn_apply() result or a table that already carries dnn_*
# columns; when it is absent the DNN columns exist but say "not_run".
pq_group_results <- function(rows, dnn = NULL) {
  empty <- data.frame(
    feature_id = character(), mz = numeric(), rt_reference = numeric(),
    rt_reference_source = character(),
    n_samples = integer(), n_present = integer(), n_absent = integer(),
    n_unknown = integer(),
    dnn_status = character(), dnn_scope = character(),
    dnn_model_version = character(), dnn_input_status = character(),
    dnn_prediction = numeric(), dnn_score = numeric(),
    dnn_threshold = numeric(), dnn_applicability = character(),
    dnn_error = character(),
    stringsAsFactors = FALSE
  )
  if (is.null(rows) || nrow(rows) == 0L) return(empty)

  # Prefer the table that carries the DNN columns, when one was supplied.
  if (!is.null(dnn)) {
    if (is.list(dnn) && !is.null(dnn$rows)) rows <- dnn$rows
    else if (is.data.frame(dnn) && nrow(dnn) == nrow(rows)) rows <- dnn
  }
  has_dnn <- "dnn_scope" %in% names(rows)

  fid <- as.character(rows$feature_id)
  keys <- unique(fid)
  pres <- as.character(rows$presence)
  pres[is.na(pres) | !nzchar(pres)] <- "unknown"

  out <- vector("list", length(keys))
  for (k in seq_along(keys)) {
    i <- which(fid == keys[k])
    rt <- suppressWarnings(as.numeric(rows$input_rt[i]))
    rt_f <- rt[is.finite(rt)]
    rt_ref <- if (length(rt_f) > 0) stats::median(rt_f) else NA_real_
    # A single distinct RT means the peak table was already aligned, so the
    # value is a cohort reference; several values mean each sample carried its
    # own RT and the median is our summary, not a measurement.
    rt_src <- if (length(unique(rt_f)) <= 1L) "aligned_table" else
      "per_sample_median"

    mz_v <- suppressWarnings(as.numeric(rows$mz[i]))
    mz_v <- mz_v[is.finite(mz_v)]
    p <- pres[i]

    out[[k]] <- data.frame(
      feature_id = keys[k],
      mz = if (length(mz_v) > 0) mz_v[1] else NA_real_,
      rt_reference = rt_ref,
      rt_reference_source = rt_src,
      n_samples = length(i),
      n_present = sum(p == "present"),
      n_absent = sum(p == "absent"),
      n_unknown = sum(p == "unknown"),
      dnn_status = if (has_dnn) as.character(rows$dnn_status[i][1]) else "not_run",
      dnn_scope = if (has_dnn) as.character(rows$dnn_scope[i][1]) else "peak_group",
      dnn_model_version = if (has_dnn) as.character(rows$dnn_model_version[i][1]) else NA_character_,
      dnn_input_status = if (has_dnn) as.character(rows$dnn_input_status[i][1]) else NA_character_,
      dnn_prediction = if (has_dnn) suppressWarnings(as.numeric(rows$dnn_prediction[i][1])) else NA_real_,
      dnn_score = if (has_dnn) suppressWarnings(as.numeric(rows$dnn_score[i][1])) else NA_real_,
      dnn_threshold = if (has_dnn) suppressWarnings(as.numeric(rows$dnn_threshold[i][1])) else NA_real_,
      dnn_applicability = if (has_dnn) as.character(rows$dnn_applicability[i][1]) else NA_character_,
      dnn_error = if (has_dnn) as.character(rows$dnn_error[i][1]) else NA_character_,
      stringsAsFactors = FALSE
    )
  }
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

# ------------------------------------------------------------
# B. SampleResults - one row per feature x sample
# ------------------------------------------------------------
# `cpc` must be aligned by position with `rows` when supplied (that is how
# pq_run_cpc() returns it). When it is NULL the cpc_* columns still exist and
# are NA with cpc_status = "not_run", so the schema of an exported file does
# not depend on whether the optional method was ticked.
pq_sample_results <- function(rows, cpc = NULL) {
  cpc_num <- c("rt", "rtmin", "rtmax", "fwhm", "wb", "a", "b", "tf",
               "height", "area", "sn")
  cpc_cols <- c(paste0("cpc_", cpc_num),
                "cpc_front_code", "cpc_tail_code", "cpc_n_points",
                "cpc_boundary_status", "cpc_status", "cpc_reason")
  cpc_text <- c("cpc_front_code", "cpc_tail_code", "cpc_boundary_status",
                "cpc_status", "cpc_reason")

  empty <- as.data.frame(c(
    list(feature_id = character(), sample_id = character(),
         raw_file = character(), mz = numeric(), rt_reference = numeric(),
         sample_rt_apex = numeric(), presence_status = character(),
         boundary_status = character(), kumler_peak_cor = numeric(),
         kumler_snr = numeric(), kumler_status = character()),
    stats::setNames(lapply(cpc_cols, function(cc) {
      if (cc %in% cpc_text) character()
      else if (identical(cc, "cpc_n_points")) integer()
      else numeric()
    }), cpc_cols),
    list(xic_smoothing = character(), ppm_tolerance = numeric(),
         mz_tolerance = character(), rt_window = numeric(),
         dnn_scope = character(), dnn_score = numeric(),
         dnn_status = character(), cpc_status_family = character(),
         method_errors = character())
  ), stringsAsFactors = FALSE)
  if (is.null(rows) || nrow(rows) == 0L) return(empty)

  n <- nrow(rows)
  has_cpc <- !is.null(cpc) && nrow(cpc) == n
  if (!is.null(cpc) && nrow(cpc) != n) {
    stop("cpc table must be aligned with the result rows", call. = FALSE)
  }

  pres <- as.character(rows$presence)
  pres[is.na(pres) | !nzchar(pres)] <- "unknown"

  kumler_status <- ifelse(pres == "absent", "absent",
                          ifelse(is.na(rows$score_status), "not_run",
                                 as.character(rows$score_status)))

  # ppm tolerance is parsed out of the recorded m/z tolerance so it can be used
  # numerically; the original string is kept next to it because "5 Da" and
  # "5 ppm" are not interchangeable.
  mz_tol <- if ("mz_tol" %in% names(rows)) as.character(rows$mz_tol) else
    rep(NA_character_, n)
  ppm <- suppressWarnings(as.numeric(sub("\\s*ppm$", "", mz_tol)))
  ppm[!grepl("ppm", mz_tol)] <- NA_real_

  out <- data.frame(
    feature_id = as.character(rows$feature_id),
    sample_id = as.character(rows$sample_id),
    raw_file = as.character(rows$file),
    mz = as.numeric(rows$mz),
    rt_reference = as.numeric(rows$input_rt),
    sample_rt_apex = as.numeric(rows$apex_rt),
    presence_status = pres,
    boundary_status = as.character(rows$boundary_status),
    kumler_peak_cor = as.numeric(rows$peak_cor),
    kumler_snr = as.numeric(rows$SNR),
    kumler_status = kumler_status,
    stringsAsFactors = FALSE
  )

  for (cc in cpc_cols) {
    if (has_cpc && cc %in% names(cpc)) {
      out[[cc]] <- cpc[[cc]]
    } else if (cc == "cpc_status") {
      out[[cc]] <- rep("not_run", n)
    } else if (cc %in% c("cpc_front_code", "cpc_tail_code",
                         "cpc_boundary_status", "cpc_reason")) {
      out[[cc]] <- rep(NA_character_, n)
    } else if (cc == "cpc_n_points") {
      out[[cc]] <- rep(NA_integer_, n)
    } else {
      out[[cc]] <- rep(NA_real_, n)
    }
  }
  # absence outranks a method status: the sample does not contain the peak, so
  # CPC had nothing to characterise. That is an answer, not a failure.
  out$cpc_status[pres == "absent"] <- "absent"
  # The published four-word vocabulary (ok / not_installed / invalid_input /
  # error, plus not_detected and absent) next to the fine-grained one.
  out$cpc_status_family <- pq_cpc_status_family(out$cpc_status)

  out$xic_smoothing <- if ("eic_smoothing" %in% names(rows)) {
    as.character(rows$eic_smoothing)
  } else rep(NA_character_, n)
  out$ppm_tolerance <- ppm
  out$mz_tolerance <- mz_tol
  out$rt_window <- if ("rt_window" %in% names(rows)) as.numeric(rows$rt_window) else
    rep(NA_real_, n)
  out$dnn_scope <- if ("dnn_scope" %in% names(rows)) as.character(rows$dnn_scope) else
    rep(NA_character_, n)
  out$dnn_score <- if ("dnn_score" %in% names(rows)) as.numeric(rows$dnn_score) else
    rep(NA_real_, n)
  out$dnn_status <- if ("dnn_status" %in% names(rows)) as.character(rows$dnn_status) else
    rep(NA_character_, n)

  # One free-text field that says what went wrong, per method, without erasing
  # which method said it.
  err <- character(n)
  for (i in seq_len(n)) {
    bits <- character(0)
    if (!identical(kumler_status[i], "ok") && !identical(kumler_status[i], "absent") &&
        !is.na(rows$failure_reason[i]) && nzchar(rows$failure_reason[i])) {
      bits <- c(bits, paste0("kumler: ", rows$failure_reason[i]))
    }
    if (has_cpc && !is.na(out$cpc_reason[i]) && nzchar(out$cpc_reason[i]) &&
        !identical(out$cpc_status[i], "ok")) {
      bits <- c(bits, paste0("cpc: ", out$cpc_reason[i]))
    }
    err[i] <- paste(bits, collapse = " | ")
  }
  out$method_errors <- err

  rownames(out) <- NULL
  out
}

# ------------------------------------------------------------
# C. MethodMetrics - long, one row per method x metric
# ------------------------------------------------------------
# Delegates the two single-XIC methods to pq_metrics_long() (one
# implementation of the metric dictionary) and appends the DNN, whose rows are
# feature-level and therefore carry an empty sample_id plus scope = peak_group.
pq_method_metrics <- function(rows, cpc = NULL, dnn = NULL) {
  base <- pq_metrics_long(rows, cpc)

  if (is.null(rows) || nrow(rows) == 0L) return(base)
  if (!is.null(dnn)) {
    if (is.list(dnn) && !is.null(dnn$rows)) rows <- dnn$rows
    else if (is.data.frame(dnn) && nrow(dnn) == nrow(rows)) rows <- dnn
  }
  if (!"dnn_score" %in% names(rows)) return(base)

  grp <- pq_group_results(rows)
  if (nrow(grp) == 0L) return(base)

  dnn_row <- function(metric, value, status, note) {
    data.frame(
      feature_id = grp$feature_id,
      sample_id = "",          # the DNN has no per-sample measurement
      method = "dnn",
      metric = metric,
      label = metric,
      unit = if (identical(metric, "dnn_score")) "model score in [0, 1]" else
        "0/1 class",
      value = as.numeric(value),
      note = note,
      status = status,
      scope = "peak_group",
      model_version = grp$dnn_model_version,
      stringsAsFactors = FALSE
    )
  }
  dnn_rows <- rbind(
    dnn_row("dnn_score", grp$dnn_score, grp$dnn_status,
            "model output for the acceptable-peak class; NOT a calibrated probability"),
    dnn_row("dnn_prediction", grp$dnn_prediction, grp$dnn_status,
            "1 = the model calls the whole peak group acceptable")
  )

  out <- rbind(base, dnn_rows)
  rownames(out) <- NULL
  out
}

# ------------------------------------------------------------
# D. Provenance block
# ------------------------------------------------------------
# Every export ends with this. It answers, in plain lines: which code ran, at
# which version, under which licence, on which model, with which parameters,
# and did each method actually execute.
pq_provenance_block <- function(params = NULL, methods_run = NULL,
                                paths = NULL, dnn = "auto",
                                cpc_settings = NULL) {
  eng <- tryCatch(PQ_ENGINE_VERSION, error = function(e) "unknown")
  lines <- c(
    "==========================================================",
    "PEAK QUALITY - PROVENANCE",
    "==========================================================",
    paste0("Engine                     : DMetFinder / Peak Quality ", eng),
    paste0("Exported at                : ",
           format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    paste0("R                          : R ", getRversion(), " (",
           R.version$platform, ")"),
    "",
    "---- methods that actually ran in this session ----"
  )

  ids <- c("kumler", "cpc", "dnn")
  ran <- if (is.null(methods_run)) character(0) else as.character(methods_run)
  for (id in ids) {
    info <- tryCatch(pq_method_info(id), error = function(e) NULL)
    av <- tryCatch(pq_method_available(id), error = function(e)
      list(ok = FALSE, version = NA_character_, reason = "unavailable"))
    did <- id %in% ran
    lines <- c(lines, sprintf(
      "%-8s scope=%-12s executed=%-3s available=%-3s %s",
      toupper(id), pq_method_scope(id), if (did) "yes" else "no",
      if (isTRUE(av$ok)) "yes" else "no",
      if (is.null(info)) "" else info$label))
    if (!did) {
      why <- if (isTRUE(av$ok)) "not selected for this run" else
        paste0("unavailable: ", av$reason)
      lines <- c(lines, paste0("         reason: ", why))
    }
  }

  # ---- per-method identity, source and licence ----
  for (id in ids) {
    lines <- c(lines, "", paste0("---- ", toupper(id), " ----"))
    lines <- c(lines, tryCatch(pq_method_provenance_lines(id),
                               error = function(e) paste0("  error: ",
                                                          conditionMessage(e))))
  }

  # ---- DNN model identity (or an explicit statement that there is none) ----
  if (identical(dnn, "auto")) {
    dnn <- tryCatch(
      if (exists("pq_dnn_provenance_lines")) {
        pq_dnn_provenance_lines(if (is.null(paths)) pq_dnn_paths() else paths)
      } else NULL,
      error = function(e) paste0("DNN block unavailable: ",
                                 conditionMessage(e)))
  }
  if (!is.null(dnn) && length(dnn) > 0) lines <- c(lines, "", dnn)

  # ---- inputs / parameters / environment ----
  lines <- c(lines, "", "---- inputs and parameters ----")
  if (!is.null(params)) {
    kv <- tryCatch(pq_params_table(params), error = function(e) NULL)
    if (!is.null(kv)) {
      lines <- c(lines, sprintf("  %-28s %s", kv$parameter, kv$value))
    }
  }
  if (!is.null(cpc_settings)) {
    lines <- c(lines,
      sprintf("  %-28s %s",
              paste0("cpc.", names(cpc_settings)),
              vapply(cpc_settings, function(v) paste(as.character(v),
                                                    collapse = ","),
                     character(1))))
  }

  lines <- c(lines, "", "---- environment ----")
  cpc_av <- tryCatch(pq_cpc_available(), error = function(e) list(ok = FALSE))
  lines <- c(lines,
    paste0("  cpc package              : ",
           if (isTRUE(cpc_av$ok)) paste0("cpc ", cpc_av$version, " from ",
                                         cpc_av$lib) else "not installed"),
    paste0("  kumler source            : ",
           tryCatch(pq_method_info("kumler")$provenance$code,
                    error = function(e) "unknown")))
  if (!is.null(paths)) {
    lines <- c(lines,
      paste0("  python                   : ", paths$python,
             if (file.exists(paths$python)) " (present)" else " (missing)"))
    m <- tryCatch(pq_dnn_find_model(paths), error = function(e) NULL)
    if (!is.null(m)) {
      lines <- c(lines,
        paste0("  tensorflow / keras       : ",
               if (is.null(m$tensorflow)) "unknown" else m$tensorflow, " / ",
               if (is.null(m$keras)) "unknown" else m$keras))
    }
  }
  lines <- c(lines,
    "  local modifications       : see the 'local modifications' line of each",
    "                              method above; nothing is re-implemented",
    "                              silently",
    "==========================================================")
  lines
}

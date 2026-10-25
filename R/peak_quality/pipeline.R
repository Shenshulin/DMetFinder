# ============================================================
# Peak Quality - batch pipeline
# ============================================================
# Ties together: file selection -> XIC extraction -> boundary detection ->
# presence check -> author scoring. Kept UI-free so it can be tested from
# plain Rscript.
#
# Job size
#   An aligned table (one row per feature, shared average m/z and RT) is
#   expanded to feature x raw file BEFORE this function is called. 3450
#   features x 20 files = 69000 rows is a normal job, not an error: the
#   safety cap lives on the peak-table rows in the server, and this function
#   processes every row it is given.
#
# Scheduling
#   Rows are grouped by raw file and processed file by file, so each file is
#   parsed once and released before the next one is loaded. The parsed file
#   is also reused for its MS1 scan index instead of being rebuilt per row.
#   The result table keeps the original row order.
# ============================================================

# One row of the report, all columns present even when a step fails.
pq_empty_row <- function() {
  data.frame(
    feature_id = NA_character_, sample_id = NA_character_,
    mz = NA_real_, input_rt = NA_real_, rt_unit = NA_character_,
    start_rt = NA_real_, apex_rt = NA_real_, end_rt = NA_real_,
    n_points = NA_integer_, n_xic_points = NA_integer_,
    peak_cor = NA_real_, SNR = NA_real_,
    presence = NA_character_,
    boundary_status = NA_character_, score_status = NA_character_,
    failure_reason = NA_character_,
    file = NA_character_, rt_window = NA_real_,
    mz_tol = NA_character_, xic_aggregate = NA_character_,
    n_scans_in_window = NA_integer_, n_scans_missing = NA_integer_,
    n_mz_matched = NA_integer_, n_scans_multi = NA_integer_,
    median_ppm_dev = NA_real_,
    peak_height = NA_real_, xic_noise = NA_real_, presence_snr = NA_real_,
    n_candidates = NA_integer_, edge_touched = NA_character_,
    apex_offset = NA_real_,
    eic_smoothing = NA_character_, eic_smoothing_applied = NA,
    # provenance carried from the peak table (stage G: cross-software compare)
    software = NA_character_, original_id = NA_character_,
    rt_source = NA_character_,
    stringsAsFactors = FALSE
  )
}

pq_row_from <- function(feat, params) {
  row <- pq_empty_row()
  row$feature_id <- feat$feature_id
  row$sample_id <- ifelse(is.na(feat$sample_id), "", feat$sample_id)
  row$mz <- feat$mz
  row$input_rt <- feat$rt_min
  row$rt_unit <- feat$rt_unit
  row$rt_window <- params$rt_window
  # Where did the RT used for the search come from? An aligned table carries
  # a cohort average; a per-sample table (or a per-sample override) carries
  # the value measured in this very sample. Recorded, never guessed.
  row$rt_source <- if ("rt_source" %in% names(feat) && !is.na(feat$rt_source)) {
    as.character(feat$rt_source)
  } else if ("aligned" %in% names(feat) && isTRUE(feat$aligned)) {
    "cohort_average"
  } else {
    "per_sample"
  }
  row$software <- if ("software" %in% names(feat)) {
    as.character(feat$software)
  } else NA_character_
  row$original_id <- if ("original_id" %in% names(feat)) {
    as.character(feat$original_id)
  } else NA_character_
  row$mz_tol <- if (identical(params$mz_tol_unit, "Da")) {
    paste0(params$mz_tol_da, " Da")
  } else {
    paste0(params$mz_tol_ppm, " ppm")
  }
  row$xic_aggregate <- params$xic_aggregate
  # The requested setting is recorded even for rows that never reach the
  # smoothing step (unmatched sample, unreadable file), so the export always
  # states which configuration was asked for; `eic_smoothing_applied` says
  # whether it actually ran on this row.
  row$eic_smoothing <- pq_eic_smooth_label(params$eic_smooth_method,
                                           params$eic_smooth_window,
                                           params$eic_smooth_order)
  row$eic_smoothing_applied <- FALSE
  row
}

# ------------------------------------------------------------
# Job planning: how many rows will this run actually process?
# ------------------------------------------------------------
# The safety cap on the peak table is expressed in FEATURES, because that is
# what the user uploaded. An aligned table is then multiplied by the number of
# raw files, and that multiplication must never be truncated: a 3450-feature
# MS-DIAL table evaluated in 20 files is a 69000-row job, not a 5000-row job.
#
# Two limits are applied, in this order:
#   1. max_features  - peak-table rows; the excess is dropped WITH a message.
#   2. max_rows      - expanded job size; exceeding it ABORTS the run.
# Nothing is ever processed partially without being reported.
pq_plan_job <- function(n_features, n_files, broadcast,
                        max_features = 20000L, max_rows = 200000L) {
  n_features <- as.integer(n_features)
  n_files <- as.integer(n_files)
  truncate <- n_features > max_features
  keep <- if (truncate) as.integer(max_features) else n_features
  rows_planned <- if (isTRUE(broadcast)) keep * n_files else keep

  msgs <- character(0)
  if (truncate) {
    msgs <- c(msgs, sprintf(
      "The peak table holds %d feature(s); only the first %d are processed (Maximum features per run = %d).",
      n_features, max_features, max_features))
  }
  if (rows_planned > max_rows) {
    msgs <- c(msgs, sprintf(
      paste0("ABORTED: %d row(s) to process exceed the limit of %d. ",
             "Nothing was processed; raise 'Maximum rows per run' or split the peak table."),
      rows_planned, max_rows))
  }

  list(
    n_features_input = n_features,
    n_files = n_files,
    broadcast = isTRUE(broadcast),
    truncate_features = truncate,
    keep_features = keep,
    rows_planned = rows_planned,
    abort = rows_planned > max_rows,
    messages = msgs
  )
}

# ------------------------------------------------------------
# features    : standardised data.frame (pq_standardize_features()$ok)
# params      : pq_default_params() list, user-adjusted
# file_lookup : data.frame(sample_id, file, match)
# ms_cache    : optional environment for caching parsed files across calls
# log_fun     : function(msg)
# progress_fun: function(value, detail)   (value in [0,1])
# ------------------------------------------------------------
pq_process_features <- function(features, params, file_lookup,
                                ms_cache = NULL,
                                log_fun = function(...) invisible(NULL),
                                progress_fun = function(value, detail) invisible(NULL)) {
  if (is.null(ms_cache)) ms_cache <- new.env(parent = emptyenv())

  n_total <- nrow(features)
  rows <- vector("list", n_total)
  detail <- vector("list", n_total)
  names(detail) <- paste(features$feature_id, features$sample_id, sep = "|")

  tol_value <- if (identical(params$mz_tol_unit, "Da")) params$mz_tol_da else params$mz_tol_ppm

  # ==========================================================
  # Pass 0 - resolve sample_id -> raw file for every row
  # ==========================================================
  # Rows that cannot be resolved are finished immediately; the rest are
  # scheduled file by file below. Nothing is skipped silently: every
  # unresolved row keeps a status and a reason.
  row_file <- rep(NA_character_, n_total)

  for (i in seq_len(n_total)) {
    feat <- features[i, , drop = FALSE]
    sid <- ifelse(is.na(feat$sample_id), "", feat$sample_id)
    lk <- file_lookup[file_lookup$sample_id %in% sid, , drop = FALSE]

    if (!nzchar(sid) || nrow(lk) == 0 || is.na(lk$file[1])) {
      row <- pq_row_from(feat, params)
      st <- if (nrow(lk) > 0 && identical(lk$match[1], "ambiguous")) {
        "sample_ambiguous"
      } else {
        "sample_unmatched"
      }
      row$boundary_status <- st
      row$presence <- "unknown"
      row$score_status <- "not_run"
      row$failure_reason <- if (st == "sample_ambiguous") {
        "sample_id matches more than one raw file"
      } else {
        "no raw file could be matched to this sample_id"
      }
      rows[[i]] <- row
      next
    }

    row_file[i] <- lk$file[1]
  }

  # ==========================================================
  # Pass 1 - schedule: group the resolved rows by raw file
  # ==========================================================
  active <- which(!is.na(row_file))
  if (length(active) > 0) {
    file_rank <- match(row_file[active], unique(row_file[active]))
    active <- active[order(file_rank, active)]
  }
  files_in_order <- unique(row_file[active])
  n_files <- length(files_in_order)
  n_active <- length(active)

  current_file <- NULL
  ms <- NULL
  ms1 <- NULL

  for (k in seq_along(active)) {
    i <- active[k]
    feat <- features[i, , drop = FALSE]
    row <- pq_row_from(feat, params)
    file <- row_file[i]
    row$file <- basename(file)

    progress_fun(if (n_active > 0) (k - 1) / n_active else 1,
                 sprintf("%s - feature %d/%d", basename(file), k, n_active))

    # ---- switch file: load once, release the previous one ----
    if (is.null(current_file) || !identical(file, current_file)) {
      # only one parsed file is kept in memory at a time. Dropping the cache is
      # not enough: the parsed spectra are still bound to `ms`, so the old file
      # stayed alive next to the new one. Clear both, then collect - on a
      # 20-file cohort that is the difference between one and two files' worth
      # of spectra at every switch.
      if (length(ls(ms_cache)) > 0) rm(list = ls(ms_cache), envir = ms_cache)
      ms <- NULL
      ms1 <- NULL
      invisible(gc(verbose = FALSE))
      current_file <- file

      t_load <- Sys.time()
      loaded <- tryCatch(list(ok = TRUE, ms = pq_load_ms_file(file, ms_level = 1)),
                         error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
      load_s <- as.numeric(difftime(Sys.time(), t_load, units = "secs"))

      if (!isTRUE(loaded$ok)) {
        assign("__load_error", loaded$msg, envir = ms_cache)
        log_fun(sprintf("ERROR reading %s: %s", basename(file), loaded$msg))
        ms <- NULL
        ms1 <- NULL
      } else if (is.null(loaded$ms$scan_table) || nrow(loaded$ms$scan_table) == 0) {
        assign("__load_error",
               "the reader returned no scan (file empty or not a valid .raw/.mzML/.mzXML)",
               envir = ms_cache)
        log_fun(paste0("ERROR: no scan found in ", basename(file)))
        ms <- NULL
        ms1 <- NULL
      } else {
        ms <- loaded$ms
        ms1 <- pq_ms1_index(ms)
        assign("__load_error", NULL, envir = ms_cache)
        log_fun(sprintf(
          "File %d/%d %s: %d MS1 scan(s) in %.1f s",
          match(file, files_in_order), n_files, basename(file),
          length(ms1$rt), load_s))
      }
    }

    load_error <- get0("__load_error", envir = ms_cache, inherits = FALSE)
    if (!is.null(load_error)) {
      row$boundary_status <- "file_error"
      row$presence <- "unknown"
      row$score_status <- "not_run"
      row$failure_reason <- paste0("raw file read error: ", load_error)
      rows[[i]] <- row
      next
    }

    # ---- 1. XIC ----
    xic_res <- pq_extract_xic(
      ms = ms, ms1 = ms1,
      target_mz = feat$mz,
      input_rt = feat$rt_min,
      rt_half_window = params$rt_window,
      mz_tol_value = tol_value,
      mz_tol_unit = params$mz_tol_unit,
      aggregate = params$xic_aggregate
    )

    row$n_scans_in_window <- xic_res$diag$n_scans_in_window
    row$n_scans_missing <- xic_res$diag$n_scans_missing
    row$n_mz_matched <- xic_res$diag$n_mz_matched
    row$n_scans_multi <- xic_res$diag$n_scans_multi
    row$median_ppm_dev <- xic_res$diag$median_ppm_dev
    row$n_xic_points <- nrow(xic_res$xic)

    # ---- 1b. optional XIC smoothing: builds the ANALYSIS trace ----
    # Everything downstream (boundaries, the scored slice, the peer methods,
    # the peak-group image) works on `xic_analysis`. The raw trace is kept
    # next to it for the presence test and for the plots. With the default
    # setting ("none") the two objects are identical.
    sm <- pq_smooth_xic(xic_res$xic,
                        method = params$eic_smooth_method,
                        window = params$eic_smooth_window,
                        order  = params$eic_smooth_order)
    xic_analysis <- sm$xic
    row$eic_smoothing <- sm$info$label
    row$eic_smoothing_applied <- isTRUE(sm$info$applied)
    if (!isTRUE(sm$info$applied) && !identical(sm$info$method, "none")) {
      log_fun(sprintf("%s - %s: %s", feat$feature_id, sm$info$label,
                      sm$info$reason))
    }

    # ---- 2. boundaries (on the analysis trace) ----
    det <- pq_detect_peaks(xic_analysis, feat$rt_min, params)
    row$boundary_status <- det$status
    row$n_candidates <- det$n_candidates
    row$start_rt <- det$peak$start_rt
    row$apex_rt <- det$peak$apex_rt
    row$end_rt <- det$peak$end_rt
    row$n_points <- det$peak$n_points
    row$edge_touched <- det$peak$edge_touched
    if (!is.na(det$peak$apex_rt)) {
      row$apex_offset <- det$peak$apex_rt - feat$rt_min
    }

    # ---- 3. presence: is the compound in this sample at all? ----
    # Judged on the RAW chromatogram with its OWN boundaries, so the verdict
    # is provably independent of the smoothing switch: presence asks what the
    # measurement contains, not how the trace was post-processed. The extra
    # detection is skipped when nothing was smoothed.
    det_raw <- if (isTRUE(sm$info$applied)) {
      pq_detect_peaks(xic_res$xic, feat$rt_min, params)
    } else {
      det
    }
    pr <- pq_assess_presence(xic_res$diag, xic_res$xic, det_raw, params)
    row$presence <- pr$presence
    row$peak_height <- pr$height
    row$xic_noise <- pr$noise
    row$presence_snr <- if (is.null(pr$snr)) NA_real_ else pr$snr

    if (identical(pr$presence, "absent")) {
      # not scored, and NOT a failure: the sample simply does not contain it
      row$score_status <- "absent"
      row$failure_reason <- pr$reason
      rows[[i]] <- row
      detail[[i]] <- list(
        xic = xic_res$xic, xic_analysis = xic_analysis, smoothing = sm$info,
        diag = xic_res$diag, peak = det$peak, peak_presence = det_raw$peak,
        candidates = det$candidates, boundary_status = det$status,
        boundary_reason = det$reason,
        file = basename(file), filepath = file, presence = pr
      )
      next
    }

    if (identical(pr$presence, "unknown") && !is.null(pr$reason)) {
      row$score_status <- "not_run"
      row$failure_reason <- pr$reason
      rows[[i]] <- row
      next
    }

    # ---- 4. author scoring on the analysis peak slice ----
    # With eic_smooth_method = "none" (the default) this is the raw slice.
    # With smoothing on, peak_cor and SNR are the author's function applied
    # to a smoothed trace, which the row records and the report states.
    if (identical(xic_res$status, "ok") && !is.na(det$peak$start_index)) {
      slice <- pq_peak_slice(xic_analysis, det$peak)
      sc <- pq_score_xic(slice$rt, slice$intensity)
      row$peak_cor <- sc$peak_cor
      row$SNR <- sc$SNR
      row$score_status <- sc$score_status
      row$failure_reason <- sc$failure_reason
    } else {
      row$score_status <- "not_run"
      row$failure_reason <- if (identical(xic_res$status, "no_signal")) {
        "no MS1 signal inside the m/z tolerance window"
      } else if (identical(xic_res$status, "no_ms1_scans")) {
        "no MS1 scan inside the RT window"
      } else {
        det$reason
      }
    }

    # boundary problems are kept even when scoring succeeded
    if (identical(row$score_status, "ok") && !det$status %in% "ok") {
      row$failure_reason <- det$reason
    }

    rows[[i]] <- row
    detail[[i]] <- list(
      xic = xic_res$xic,
      xic_analysis = xic_analysis,
      smoothing = sm$info,
      diag = xic_res$diag,
      peak = det$peak,
      peak_presence = det_raw$peak,
      candidates = det$candidates,
      boundary_status = det$status,
      boundary_reason = det$reason,
      file = basename(file),
      filepath = file,
      presence = pr
    )
  }

  progress_fun(1, "done")

  rows_df <- do.call(rbind, rows)
  rownames(rows_df) <- NULL
  list(rows = rows_df, detail = detail)
}

# ------------------------------------------------------------
# Failure list (for the export)
# ------------------------------------------------------------
# A row that is absent from the sample is NOT a failure: it is a valid
# answer. It is exported in its own table so the two never get mixed up.
pq_failures <- function(rows) {
  bad <- rows[!rows$score_status %in% "ok" &
                !rows$presence %in% "absent", , drop = FALSE]
  if (nrow(bad) == 0) return(bad)
  keep <- c("feature_id", "sample_id", "mz", "input_rt", "file",
            "presence", "boundary_status", "score_status", "failure_reason",
            "n_points")
  bad[, keep, drop = FALSE]
}

# ------------------------------------------------------------
# Absent rows (exported separately, never deleted from the results)
# ------------------------------------------------------------
pq_absent_table <- function(rows) {
  if (is.null(rows) || nrow(rows) == 0) {
    return(data.frame(feature_id = character(), sample_id = character(),
                      mz = numeric(), input_rt = numeric(), file = character(),
                      n_mz_matched = integer(), n_xic_points = integer(),
                      peak_height = numeric(), xic_noise = numeric(),
                      presence_snr = numeric(), failure_reason = character(),
                      stringsAsFactors = FALSE))
  }
  ab <- rows[rows$presence %in% "absent", , drop = FALSE]
  keep <- c("feature_id", "sample_id", "mz", "input_rt", "file",
            "n_mz_matched", "n_xic_points", "peak_height", "xic_noise",
            "presence_snr", "failure_reason")
  ab[, keep, drop = FALSE]
}

# ------------------------------------------------------------
# Candidate table across all features (long format)
# ------------------------------------------------------------
pq_candidates_table <- function(detail) {
  parts <- lapply(names(detail), function(k) {
    d <- detail[[k]]
    if (is.null(d) || is.null(d$candidates) || nrow(d$candidates) == 0) return(NULL)
    cbind(feature_key = k, d$candidates, stringsAsFactors = FALSE)
  })
  parts <- parts[!vapply(parts, is.null, logical(1))]
  if (length(parts) == 0) {
    return(data.frame(feature_key = character(), candidate_id = integer(),
                      apex_rt = numeric(), stringsAsFactors = FALSE))
  }
  out <- do.call(rbind, parts)
  rownames(out) <- NULL
  out
}

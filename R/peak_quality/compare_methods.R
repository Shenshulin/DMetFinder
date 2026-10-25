# ============================================================
# Peak Quality - running a second single-XIC method on the same peaks
# ============================================================
# The Kumler pipeline (pipeline.R) already stored, for every evaluated row,
# the XIC of the whole RT search window and the located peak. CPC is run on
# exactly that trace, with the apex of the same located peak as its starting
# point, so both methods look at the same candidate. They are NOT given the
# same slice: CPC must be free to place its own boundaries, otherwise
# "boundary differences between methods" would be an artefact of the input.
#
# This file never averages, ranks or combines the two methods.
# ============================================================

pq_cpc_plan <- function(n_rows, max_rows) {
  if (is.null(max_rows) || is.na(max_rows) || max_rows <= 0) {
    return(list(run = n_rows, skip = 0L, limited = FALSE))
  }
  max_rows <- as.integer(max_rows)
  list(run = min(n_rows, max_rows), skip = max(0L, n_rows - max_rows),
       limited = n_rows > max_rows)
}

# detail : the `detail` list returned by pq_process_features()
# rows   : the aligned result table (same order as detail)
pq_run_cpc <- function(detail, rows, params = list(), max_rows = NULL,
                       log_fun = function(...) invisible(NULL),
                       progress_fun = function(value, detail) invisible(NULL)) {
  n <- length(detail)
  out <- pq_cpc_empty_row()[rep(1L, n), , drop = FALSE]
  rownames(out) <- NULL
  out$cpc_status <- NA_character_

  if (n == 0) {
    return(list(table = out, settings = NULL, n_run = 0L, n_ok = 0L,
                elapsed = 0, skipped_by_limit = 0L))
  }

  plan <- pq_cpc_plan(n, max_rows)
  if (plan$limited) {
    log_fun(sprintf(paste0(
      "CPC: only the first %d of %d row(s) are processed (CPC row limit); ",
      "the remaining %d stay 'not_run' and are reported as such."),
      plan$run, n, plan$skip))
  }

  settings_used <- NULL
  t0 <- Sys.time()
  n_ok <- 0L
  n_absent <- 0L
  n_skipped_limit <- 0L
  win_source <- character(0)

  for (i in seq_len(n)) {
    if (i %% 500L == 0L || i == n) {
      progress_fun(i / n, sprintf("CPC %d/%d", i, n))
    }
    if (i > plan$run) {
      out$cpc_status[i] <- "not_run"
      out$cpc_reason[i] <- "not run (CPC row limit reached)"
      n_skipped_limit <- n_skipped_limit + 1L
      next
    }

    d <- detail[[i]]
    # Both methods must see the SAME trace, otherwise a difference in
    # boundaries could simply be a difference in input. When XIC smoothing is
    # enabled this is the smoothed trace.
    xic_cpc <- pq_analysis_xic(d)
    if (is.null(xic_cpc) || nrow(xic_cpc) == 0) {
      out$cpc_status[i] <- "not_run"
      out$cpc_reason[i] <- "no XIC was stored for this row"
      next
    }
    if (identical(rows$presence[i], "absent")) {
      out$cpc_status[i] <- "absent"
      out$cpc_reason[i] <- "no peak in this sample; CPC not run"
      n_absent <- n_absent + 1L
      next
    }

    apex <- d$peak$apex_index
    res <- pq_cpc_score(xic_cpc, apex, params)
    src <- attr(res, "cpc_smooth_win_source")
    if (!is.null(src) && !is.na(src)) win_source <- c(win_source, src)
    out[i, names(res)] <- res
    if (identical(res$cpc_status, "ok")) {
      n_ok <- n_ok + 1L
      if (is.null(settings_used)) {
        settings_used <- pq_cpc_settings(length(xic_cpc$rt), params,
                                         y = xic_cpc$intensity, apex = apex)
      }
    }
  }

  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  # "failed" used to lump EVERY non-ok answer together, so a healthy run whose
  # only problem was CPC not finding a peak in some traces reported itself as
  # "failed=32" while the summary underneath said "not detected=32, failed=0".
  # A not_detected answer is a valid answer, not a crash: report by family.
  fam <- pq_cpc_status_family(out$cpc_status)
  n_not_detected <- sum(fam == "not_detected")
  n_broken <- sum(fam %in% c("invalid_input", "error"))
  log_fun(sprintf(paste0(
    "CPC finished in %.1f s: ok=%d, not_detected=%d, absent=%d, ",
    "invalid_or_error=%d, not_run=%d."),
    elapsed, n_ok, n_not_detected, n_absent, n_broken, n_skipped_limit))

  # The smoothing window decides whether CPC can see a peak at all: on real
  # narrow XICs an over-wide window flattens the peak and CPC answers
  # "not_detected". Say out loud how many windows came from the coarse n/3
  # fallback instead of letting a run of not_detected look like clean data.
  win_counts <- table(win_source)
  n_fallback <- sum(win_counts[names(win_counts) %in%
                                 c("one_third_fallback", "fwhm+clamped_to_trace",
                                   "one_third_fallback+clamped_to_trace")])
  if (length(win_source) > 0 && n_fallback > 0) {
    log_fun(sprintf(paste0(
      "CPC smoothing window: %d of %d trace(s) could not derive a window from ",
      "the peak width and fell back to one third of the trace (source: %s). ",
      "Wide windows can flatten narrow peaks and make CPC report not_detected; ",
      "set cpc.smooth_win explicitly to override."),
      as.integer(n_fallback), length(win_source),
      paste(names(win_counts), as.integer(win_counts), sep = "=", collapse = ", ")))
  } else if (length(win_source) > 0) {
    log_fun(sprintf("CPC smoothing window: %d trace(s), all derived from the peak width (%s).",
                    length(win_source),
                    paste(names(win_counts), as.integer(win_counts),
                          sep = "=", collapse = ", ")))
  }

  list(table = out, settings = settings_used, n_run = n - n_skipped_limit,
       n_ok = n_ok, elapsed = elapsed, skipped_by_limit = n_skipped_limit,
       smooth_win_source = win_counts)
}

# ------------------------------------------------------------
# The "Compare methods" bundle
# ------------------------------------------------------------
# Returns every representation at once so the server and the export never
# disagree about what was computed.
pq_compare_bundle <- function(rows, detail, params = list(), max_rows = NULL,
                              log_fun = function(...) invisible(NULL),
                              progress_fun = function(value, detail) invisible(NULL)) {
  if (is.null(rows) || nrow(rows) == 0) return(NULL)

  run <- pq_run_cpc(detail, rows, params, max_rows = max_rows,
                    log_fun = log_fun, progress_fun = progress_fun)

  list(
    cpc = run$table,
    cpc_settings = run$settings,
    n_cpc_ok = run$n_ok,
    elapsed = run$elapsed,
    unified = pq_unified_from_run(rows, run$table, params,
                                  cpc_settings = run$settings),
    metrics = pq_metrics_long(rows, run$table),
    wide = pq_wide_compare(rows, run$table),
    summary = pq_agreement_summary(pq_wide_compare(rows, run$table))
  )
}

# Rows where the two methods disagree - the cases the task asks to inspect.
pq_divergent_cases <- function(wide, pattern = c("kumler_only", "cpc_only",
                                                 "neither"), limit = 500L) {
  if (is.null(wide) || !"method_agreement" %in% names(wide)) return(NULL)
  keep <- wide[wide$method_agreement %in% pattern, , drop = FALSE]
  if (nrow(keep) == 0) return(keep)
  utils::head(keep, limit)
}

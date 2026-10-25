# ============================================================
# Shared helpers for the Peak Quality test suite
# ============================================================
# Plain Rscript, no testthat dependency (matches the existing project style).
# Run everything with:
#   Rscript tests/peak_quality/run_all.R
# ============================================================

invisible(tryCatch(Sys.setlocale("LC_ALL", "Chinese (Simplified)_China.utf8"),
                   error = function(e) NULL))

PQT <- new.env(parent = emptyenv())
PQT$pass <- 0L
PQT$fail <- 0L
PQT$skip <- 0L
PQT$messages <- character(0)

pq_proj_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", args[grep("^--file=", args)])
  if (length(f) == 1) {
    return(normalizePath(file.path(dirname(f), "../.."), winslash = "/",
                         mustWork = FALSE))
  }
  normalizePath(getwd(), winslash = "/")
}

pq_source_project <- function(root = pq_proj_root()) {
  files <- c(
    "shiny_app/server/FeatureGeter_server.R",   # read_ms_file (shared reader)
    "R/peak_quality/peak_quality_config.R",
    "R/peak_quality/run_log.R",                # on-disk log / job estimate / snapshot
    "R/peak_quality/eic_smooth.R",
    "R/peak_quality/vendor/squallms_qscore.R",
    "R/peak_quality/score_adapter.R",
    "R/peak_quality/xic_extract.R",
    "R/peak_quality/peak_detect.R",
    "R/peak_quality/presence.R",
    "R/peak_quality/peak_table.R",
    "R/peak_quality/feature_summary.R",
    "R/peak_quality/pipeline.R",
    "R/peak_quality/plot_peak_quality.R",
    "R/peak_quality/method_registry.R",
    "R/peak_quality/cpc_adapter.R",
    "R/peak_quality/unified_results.R",
    "R/peak_quality/quality_class.R",
    "R/peak_quality/pq_dnn_data.R",
    "R/peak_quality/pq_dnn_integration.R",
    "R/peak_quality/result_tables.R",
    "R/peak_quality/compare_methods.R",
    "R/peak_quality/peak_group.R",
    "R/peak_quality/plot_compare.R",
    "R/peak_quality/export_peak_quality.R"
  )
  for (f in files) {
    p <- file.path(root, f)
    if (!file.exists(p)) stop("missing source file: ", p)
    source(p, encoding = "UTF-8", local = FALSE)
  }
  invisible(root)
}

pq_ok <- function(msg) {
  PQT$pass <- PQT$pass + 1L
  cat("  PASS:", msg, "\n")
}

pq_fail <- function(msg) {
  PQT$fail <- PQT$fail + 1L
  PQT$messages <- c(PQT$messages, msg)
  cat("  FAIL:", msg, "\n")
}

pq_skip <- function(msg) {
  PQT$skip <- PQT$skip + 1L
  cat("  SKIP:", msg, "\n")
}

pq_assert <- function(cond, msg) {
  cond <- isTRUE(cond)
  if (cond) pq_ok(msg) else pq_fail(msg)
  invisible(cond)
}

pq_assert_equal <- function(actual, expected, msg, tol = 1e-10) {
  ok <- isTRUE(all.equal(actual, expected, tolerance = tol, check.attributes = FALSE))
  if (ok) pq_ok(msg) else pq_fail(paste0(msg, " | got: ",
                                         paste(format(actual), collapse = ","),
                                         " expected: ",
                                         paste(format(expected), collapse = ",")))
  invisible(ok)
}

pq_assert_true <- function(cond, msg) pq_assert(cond, msg)

pq_assert_contains <- function(text, pattern, msg) {
  ok <- any(grepl(pattern, text, fixed = TRUE))
  if (ok) pq_ok(msg) else pq_fail(paste0(msg, " | pattern not found: ", pattern))
  invisible(ok)
}

pq_section <- function(title) cat("\n==", title, "==\n")

pq_summary <- function() {
  total <- PQT$pass + PQT$fail
  cat(sprintf("\n---- %d checks: %d passed, %d failed, %d skipped ----\n",
              total, PQT$pass, PQT$fail, PQT$skip))
  if (PQT$fail > 0) {
    cat("Failures:\n")
    cat(paste0("  - ", PQT$messages, collapse = "\n"), "\n")
    return(FALSE)
  }
  TRUE
}

# ------------------------------------------------------------
# Synthetic run: result rows + detail, no raw file needed
# ------------------------------------------------------------
# Used by the stage-2/3 tests (CPC adapter, unified structure, peak groups).
# It produces exactly the objects pipeline.R produces, so the comparison and
# peak-group code is exercised without parsing a 57 MB .raw file.
pq_synth_xic <- function(base_rt, amp = 2e5, sigma = 0.05, noise = NULL,
                         n = 61, shift = 0, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  if (is.null(noise)) noise <- amp * 0.008
  rt <- seq(base_rt - 0.30, base_rt + 0.30, length.out = n)
  y <- amp * exp(-0.5 * ((rt - (base_rt + shift)) / sigma)^2) +
    stats::rnorm(n, 0, noise)
  data.frame(rt = rt, intensity = pmax(y, 0), scan = seq_len(n),
             n_mz = 1L, ppm_dev = 0, stringsAsFactors = FALSE)
}

pq_make_synthetic_run <- function(n_samples = 3L,
                                  features = c("F1", "F2"),
                                  seed = 11L,
                                  smooth_method = "none",
                                  smooth_window = 7L,
                                  smooth_order = 2L) {
  params <- pq_default_params()
  params$eic_smooth_method <- smooth_method
  params$eic_smooth_window <- smooth_window
  params$eic_smooth_order <- smooth_order
  rows <- list()
  detail <- list()
  set.seed(seed)
  for (fi in seq_along(features)) {
    f <- features[fi]
    mz <- 300 + fi * 4.1234
    base_rt <- 5 + fi * 1.5
    for (s in seq_len(n_samples)) {
      sid <- sprintf("S%02d", s)
      # the last sample of the last feature has noise only -> absent
      # (only when the fixture has enough samples to keep a group alive)
      absent <- n_samples >= 3L && fi == length(features) && s == n_samples
      xic <- if (absent) {
        pq_synth_xic(base_rt, amp = 0, sigma = 0.05, noise = 800, n = 61)
      } else {
        pq_synth_xic(base_rt, amp = 2e5, sigma = 0.05,
                     shift = stats::rnorm(1, 0, 0.01), n = 61)
      }
      noise <- pq_point_noise(xic$intensity)
      diag <- list(n_scans_in_window = nrow(xic), n_scans_missing = 0L,
                   n_mz_matched = nrow(xic), n_scans_multi = 0L,
                   median_ppm_dev = 0, noise = noise)

      # mirror pipeline.R: boundaries and scores use the analysis trace,
      # presence uses the raw trace with its own detection
      sm <- pq_smooth_xic(xic, smooth_method, smooth_window, smooth_order)
      xa <- sm$xic
      det <- pq_detect_peaks(xa, base_rt, params)
      det_raw <- if (isTRUE(sm$info$applied)) pq_detect_peaks(xic, base_rt, params) else det
      pr <- pq_assess_presence(diag, xic, det_raw, params)
      row <- pq_row_from(data.frame(feature_id = f, sample_id = sid,
                                    mz = mz, rt_min = base_rt,
                                    rt_unit = "min", stringsAsFactors = FALSE),
                         params)
      row$eic_smoothing <- sm$info$label
      row$eic_smoothing_applied <- isTRUE(sm$info$applied)
      row$file <- paste0(sid, ".raw")
      row$n_scans_in_window <- nrow(xic)
      row$n_scans_missing <- 0L
      row$n_mz_matched <- nrow(xic)
      row$n_scans_multi <- 0L
      row$median_ppm_dev <- 0
      row$n_xic_points <- nrow(xic)
      row$boundary_status <- det$status
      row$n_candidates <- det$n_candidates
      row$start_rt <- det$peak$start_rt
      row$apex_rt <- det$peak$apex_rt
      row$end_rt <- det$peak$end_rt
      row$n_points <- det$peak$n_points
      row$edge_touched <- det$peak$edge_touched
      if (!is.na(det$peak$apex_rt)) row$apex_offset <- det$peak$apex_rt - base_rt
      row$presence <- pr$presence
      row$peak_height <- pr$height
      row$xic_noise <- pr$noise
      row$presence_snr <- pr$snr

      if (identical(pr$presence, "absent")) {
        row$score_status <- "absent"
        row$failure_reason <- pr$reason
      } else if (!is.na(det$peak$start_index)) {
        slice <- pq_peak_slice(xa, det$peak)
        sc <- pq_score_xic(slice$rt, slice$intensity)
        row$peak_cor <- sc$peak_cor
        row$SNR <- sc$SNR
        row$score_status <- sc$score_status
        row$failure_reason <- sc$failure_reason
      } else {
        row$score_status <- "not_run"
        row$failure_reason <- det$reason
      }

      key <- paste(f, sid, sep = "|")
      rows[[key]] <- row
      detail[[key]] <- list(
        xic = xic, xic_analysis = xa, smoothing = sm$info,
        diag = diag, peak = det$peak, peak_presence = det_raw$peak,
        candidates = det$candidates, boundary_status = det$status,
        boundary_reason = det$reason, file = row$file,
        filepath = file.path(tempdir(), row$file), presence = pr
      )
    }
  }
  rows_df <- do.call(rbind, rows)
  rownames(rows_df) <- NULL
  # the pipeline builds detail in the same row order
  detail <- detail[names(rows)]
  list(rows = rows_df, detail = detail, params = params)
}

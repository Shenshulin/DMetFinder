# ============================================================
# Peak Quality - export helpers
# ============================================================
# Everything exported carries the parameters and the provenance block so a
# result table can always be traced back to inputs and code version.
# Low-scoring peaks are never dropped automatically.
# ============================================================

pq_safe_name <- function(x, max_len = 60) {
  x <- gsub("[^A-Za-z0-9._-]+", "_", as.character(x))
  x <- gsub("_+", "_", x)
  x <- sub("^_|_$", "", x)
  ifelse(nchar(x) == 0, "feature", substr(x, 1, max_len))
}

pq_params_table <- function(params) {
  data.frame(
    parameter = names(params),
    value = vapply(params, function(v) paste(as.character(v), collapse = ","), character(1)),
    stringsAsFactors = FALSE
  )
}

pq_result_columns <- function(rows) {
  preferred <- c(
    "feature_id", "sample_id", "mz", "input_rt", "start_rt", "apex_rt",
    "end_rt", "n_points", "peak_cor", "SNR", "presence",
    # the provisional verdict sits next to the evidence it was derived from
    "quality_class", "quality_rule", "quality_reason",
    # the DNN is a separate method with a different unit of analysis (a peak
    # group, not one sample), so it sits after the single-peak verdict and
    # never inside it. dnn_scope is carried next to the score because the same
    # group score is repeated on every sample row and must not be read as a
    # per-sample measurement.
    "dnn_status", "dnn_scope", "dnn_model_version", "dnn_input_status",
    "dnn_prediction", "dnn_score", "dnn_threshold", "dnn_source",
    "dnn_applicability", "dnn_error",
    "boundary_status", "score_status", "failure_reason"
  )
  # intersect, not a blind c(): this helper is also called on a table that has
  # not been classified yet (e.g. before the export path runs), and asking a
  # data.frame for a column it does not have is an error, not a NULL subset.
  c(intersect(preferred, names(rows)), setdiff(names(rows), preferred))
}

# ------------------------------------------------------------
# XLSX workbook
# ------------------------------------------------------------
pq_export_xlsx <- function(path, rows, detail, params, mapping, lookup,
                           summary = NULL,
                           provenance = NULL,
                           cpc = NULL, cpc_settings = NULL,
                           unified = NULL, metrics = NULL, compare = NULL,
                           group_diag = NULL, groups = NULL, samples = NULL,
                           methods_run = NULL, paths = NULL) {
  wb <- openxlsx::createWorkbook()

  add <- function(name, df) {
    openxlsx::addWorksheet(wb, name)
    openxlsx::writeData(wb, name, df)
    openxlsx::freezePane(wb, name, firstRow = TRUE)
    openxlsx::setColWidths(wb, name, cols = seq_len(max(1, ncol(df))),
                           widths = "auto")
  }

  # The verdict columns are appended here so that every export path (XLSX,
  # CSV, ZIP) carries them without the caller having to remember. CPC is
  # passed in as corroboration only; it never changes a class.
  rows <- pq_classify_rows(rows, cpc)

  res <- rows[, pq_result_columns(rows), drop = FALSE]
  res$presence_label <- pq_presence_label(res$presence)
  res$boundary_status_label <- pq_status_label(res$boundary_status)
  res$quality_class_label <- pq_quality_label(res$quality_class)
  add("Results", res)

  # ---- the three published tables -------------------------------------
  # GroupResults is one row per feature because that is what the DNN scored;
  # SampleResults is one row per feature x sample because that is where CPC and
  # Kumler operate. Both are derived here so the file cannot drift from the
  # in-app tables.
  if (is.null(groups)) groups <- pq_group_results(rows)
  if (is.null(samples)) samples <- pq_sample_results(rows, cpc)
  if (!is.null(groups) && nrow(groups) > 0) add("GroupResults", groups)
  if (!is.null(samples) && nrow(samples) > 0) add("SampleResults", samples)

  # ---- provisional classification: counts, per software -----------------
  add("QualityClassSummary", pq_class_summary(rows))
  sw <- pq_class_by_software(rows)
  if (nrow(sw) > 0) {
    add("SoftwareComparison", sw)
    add("SoftwareComparisonNote",
        data.frame(note = pq_software_compare_note(rows), stringsAsFactors = FALSE))
  }

  if (!is.null(summary) && nrow(summary) > 0) add("FeatureSummary", summary)

  # ---- method comparison: never combined into one score ----
  if (!is.null(unified) && nrow(unified) > 0) add("UnifiedResults", unified)
  # MethodMetrics is always written: a missing metric is information (the method
  # did not run, or the sample does not contain the peak), and a sheet that
  # silently disappears would hide that.
  if (is.null(metrics)) metrics <- pq_method_metrics(rows, cpc)
  if (!is.null(metrics) && nrow(metrics) > 0) add("MethodMetrics", metrics)
  if (!is.null(compare) && nrow(compare) > 0) {
    cmp <- compare
    num <- vapply(cmp, is.numeric, logical(1))
    cmp[num] <- lapply(cmp[num], function(x) round(x, 6))
    add("MethodComparison", cmp)
  }
  if (!is.null(cpc) && nrow(cpc) > 0) {
    cpc_out <- cbind(feature_id = rows$feature_id, sample_id = rows$sample_id,
                     cpc, stringsAsFactors = FALSE)
    add("CpcPeaks", cpc_out)
  }
  if (!is.null(group_diag) && nrow(group_diag) > 0) add("PeakGroups", group_diag)

  add("Candidates", pq_candidates_table(detail))
  add("AbsentPeaks", pq_absent_table(rows))
  add("Failures", pq_failures(rows))

  par_tbl <- pq_params_table(params)
  # the classification thresholds belong to the parameter sheet: a verdict
  # cannot be reproduced without them
  qr <- pq_quality_rules()
  par_tbl <- rbind(par_tbl, data.frame(
    parameter = c("quality_class.version", "quality_class.verified",
                  "quality_class.min_points_for_shape",
                  "quality_class.peak_cor_good", "quality_class.peak_cor_poor",
                  "quality_class.snr_noise", "quality_class.snr_good",
                  "quality_class.source"),
    value = c(qr$version, as.character(qr$verified),
              as.character(qr$min_points_for_shape),
              as.character(qr$peak_cor_good), as.character(qr$peak_cor_poor),
              as.character(qr$snr_noise), as.character(qr$snr_good),
              paste(unlist(qr$source), collapse = " | ")),
    stringsAsFactors = FALSE))
  if (!is.null(cpc_settings)) par_tbl <- rbind(par_tbl, pq_cpc_param_table(cpc_settings))
  add("Parameters", par_tbl)

  add("SampleMapping", lookup)

  map_df <- data.frame(field = names(mapping),
                       mapped_column = unlist(mapping, use.names = FALSE),
                       stringsAsFactors = FALSE)
  add("FieldMapping", map_df)

  # what every unified column means, and which method produced it
  add("ColumnDictionary", rbind(pq_unified_dictionary(), pq_quality_dictionary()))
  add("Methods", pq_methods_table())

  # The provenance block states, per method, whether it executed. Building it
  # here (instead of defaulting to a fixed string) means an export can never
  # claim CPC ran when the box was never ticked.
  if (is.null(provenance)) {
    provenance <- pq_provenance_block(params = params,
                                      methods_run = methods_run,
                                      paths = paths,
                                      cpc_settings = cpc_settings)
  }
  add("Provenance", data.frame(line = provenance, stringsAsFactors = FALSE))

  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  path
}

# ------------------------------------------------------------
# ZIP report: tables + parameters + provenance + per-peak PNGs + PDF
# ------------------------------------------------------------
pq_export_report_zip <- function(zipfile, workdir, rows, detail, params,
                                 mapping, lookup, summary = NULL, max_plots = 200,
                                 provenance = NULL,
                                 cpc = NULL, cpc_settings = NULL,
                                 unified = NULL, metrics = NULL, compare = NULL,
                                 group_diag = NULL, groups = NULL, samples = NULL,
                                 methods_run = NULL, paths = NULL) {
  dir.create(workdir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(workdir, recursive = TRUE, force = TRUE), add = TRUE)

  # same rule as the XLSX path: classify once, then every CSV below carries
  # the verdict columns
  rows <- pq_classify_rows(rows, cpc)

  if (is.null(groups)) groups <- pq_group_results(rows)
  if (is.null(samples)) samples <- pq_sample_results(rows, cpc)
  if (is.null(metrics)) metrics <- pq_method_metrics(rows, cpc)

  utils::write.csv(rows[, pq_result_columns(rows), drop = FALSE],
                   file.path(workdir, "peak_quality_results.csv"),
                   row.names = FALSE, na = "")
  if (!is.null(groups) && nrow(groups) > 0) {
    utils::write.csv(groups, file.path(workdir, "group_results.csv"),
                     row.names = FALSE, na = "")
  }
  if (!is.null(samples) && nrow(samples) > 0) {
    utils::write.csv(samples, file.path(workdir, "sample_results.csv"),
                     row.names = FALSE, na = "")
  }
  utils::write.csv(pq_class_summary(rows),
                   file.path(workdir, "quality_class_summary.csv"),
                   row.names = FALSE, na = "")
  sw <- pq_class_by_software(rows)
  if (nrow(sw) > 0) {
    utils::write.csv(sw, file.path(workdir, "quality_class_by_software.csv"),
                     row.names = FALSE, na = "")
    writeLines(pq_software_compare_note(rows),
               file.path(workdir, "software_comparison_note.txt"),
               useBytes = TRUE)
  }
  if (!is.null(summary) && nrow(summary) > 0) {
    utils::write.csv(summary, file.path(workdir, "feature_summary.csv"),
                     row.names = FALSE, na = "")
  }
  if (!is.null(unified) && nrow(unified) > 0) {
    utils::write.csv(unified, file.path(workdir, "unified_results.csv"),
                     row.names = FALSE, na = "")
  }
  if (!is.null(metrics) && nrow(metrics) > 0) {
    utils::write.csv(metrics, file.path(workdir, "method_metrics_long.csv"),
                     row.names = FALSE, na = "")
  }
  if (!is.null(compare) && nrow(compare) > 0) {
    utils::write.csv(compare, file.path(workdir, "method_comparison.csv"),
                     row.names = FALSE, na = "")
  }
  if (!is.null(cpc) && nrow(cpc) > 0) {
    utils::write.csv(cbind(feature_id = rows$feature_id,
                           sample_id = rows$sample_id, cpc),
                     file.path(workdir, "cpc_peaks.csv"), row.names = FALSE, na = "")
  }
  if (!is.null(group_diag) && nrow(group_diag) > 0) {
    utils::write.csv(group_diag, file.path(workdir, "peak_group_diagnostics.csv"),
                     row.names = FALSE, na = "")
  }
  utils::write.csv(rbind(pq_unified_dictionary(), pq_quality_dictionary()),
                   file.path(workdir, "column_dictionary.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(pq_methods_table(),
                   file.path(workdir, "methods.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(pq_candidates_table(detail),
                   file.path(workdir, "peak_quality_candidates.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(pq_absent_table(rows),
                   file.path(workdir, "peak_quality_absent.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(pq_failures(rows),
                   file.path(workdir, "peak_quality_failures.csv"),
                   row.names = FALSE, na = "")
  par_tbl <- pq_params_table(params)
  if (!is.null(cpc_settings)) par_tbl <- rbind(par_tbl, pq_cpc_param_table(cpc_settings))
  utils::write.csv(par_tbl, file.path(workdir, "parameters.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(lookup, file.path(workdir, "sample_mapping.csv"),
                   row.names = FALSE, na = "")
  utils::write.csv(
    data.frame(field = names(mapping),
               mapped_column = unlist(mapping, use.names = FALSE),
               stringsAsFactors = FALSE),
    file.path(workdir, "field_mapping.csv"), row.names = FALSE, na = "")

  if (is.null(provenance)) {
    provenance <- pq_provenance_block(params = params,
                                      methods_run = methods_run,
                                      paths = paths,
                                      cpc_settings = cpc_settings)
  }
  writeLines(provenance, file.path(workdir, "provenance.txt"),
             useBytes = TRUE)
  utils::capture.output(utils::sessionInfo(),
                        file = file.path(workdir, "sessionInfo.txt"))

  # ---- per-peak PNGs + one PDF ----
  keys <- names(detail)
  keys <- keys[vapply(detail, function(d) !is.null(d) && nrow(d$xic) > 0, logical(1))]
  keys <- utils::head(keys, max_plots)

  if (length(keys) > 0) {
    pdir <- file.path(workdir, "peaks")
    dir.create(pdir, showWarnings = FALSE)

    pdf_path <- file.path(workdir, "peak_quality_report.pdf")
    grDevices::pdf(pdf_path, width = 8, height = 5, onefile = TRUE)

    for (k in keys) {
      d <- detail[[k]]
      ri <- which(rows$feature_id == d_feature_id(k) &
                    rows$sample_id == d_sample_id(k))
      if (length(ri) == 0) next
      r <- rows[ri[1], , drop = FALSE]
      crow <- if (!is.null(cpc) && nrow(cpc) == nrow(rows)) cpc[ri[1], , drop = FALSE] else NULL

      # page in the PDF
      try(pq_plot_peak_base(d, r, show_fit = TRUE, smooth_points = 0,
                            cpc_row = crow),
          silent = TRUE)

      # standalone PNG
      png_path <- file.path(pdir, paste0(pq_safe_name(k), ".png"))
      try({
        grDevices::png(png_path, width = 1000, height = 640)
        pq_plot_peak_base(d, r, show_fit = TRUE, smooth_points = 0,
                          cpc_row = crow)
        grDevices::dev.off()
      }, silent = TRUE)
      if (!file.exists(png_path)) {
        try(grDevices::dev.off(), silent = TRUE)
      }
    }
    try(grDevices::dev.off(), silent = TRUE)
  }

  # zip::zip keeps the relative structure; fall back to utils::zip
  if (requireNamespace("zip", quietly = TRUE)) {
    zip::zip(zipfile = zipfile,
             files = list.files(workdir, recursive = TRUE),
             root = workdir, mode = "mirror")
  } else {
    files <- list.files(workdir, recursive = TRUE, full.names = TRUE)
    old <- setwd(workdir)
    on.exit(setwd(old), add = TRUE)
    utils::zip(zipfile, files, flags = "-r9X")
  }
  zipfile
}

# detail names are "feature_id|sample_id"
d_feature_id <- function(key) sub("\\|.*$", "", key)
d_sample_id  <- function(key) sub("^.*\\|", "", key)

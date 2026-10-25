# ============================================================
# Test 01: end-to-end pipeline on synthetic mzML / mzXML files
# ============================================================
# Covers: multi-file / multi-sample matching, every boundary status in one
# run, author scores flowing into the report, raw-file error handling,
# and the three export formats.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))

ROOT <- normalizePath(file.path(here, "../.."), winslash = "/")
pq_source_project(ROOT)
source(file.path(here, "fixtures/make_fixtures.R"))

fx <- pq_fixture_make(file.path(tempdir(), "pq_fix_pipe"))
p <- pq_default_params()

mapping <- list(feature_id = "feature_id", mz = "mz", rt = "rt",
                sample_id = "sample_id", area = "", height = "", polarity = "",
                charge = "", software = "", original_id = "")

std <- pq_standardize_features(pq_read_table(fx$features_min), mapping, "min")
feat <- std$ok

files <- c(fx$mzml, fx$mzml2)
lookup <- pq_match_samples(unique(feat$sample_id), files)
pq_section("sample matching inside the pipeline")
pq_assert_equal(lookup$match[1], "exact", "S1 matched to S1.mzML (S2 not used)")

pq_section("pipeline results, one row per feature")
res <- pq_process_features(feat, p, lookup, ms_cache = new.env(parent = emptyenv()))
rows <- res$rows

pq_assert(nrow(rows) == 10, "10 feature rows in the report")
pq_assert(all(c("feature_id", "sample_id", "mz", "input_rt", "start_rt", "apex_rt",
                "end_rt", "n_points", "peak_cor", "SNR", "presence",
                "boundary_status", "score_status", "failure_reason") %in% names(rows)),
          "all required report columns present (plus presence)")

# every injected compound is physically present in this file
pq_assert(sum(rows$presence %in% "present") == 8,
          "8 of 10 features carry a real peak in this sample")

get <- function(id) rows[rows$feature_id == id, , drop = FALSE]

r <- get("F_CLEAN")
pq_assert(r$boundary_status == "ok", "F_CLEAN: boundary ok")
pq_assert(r$score_status == "ok", "F_CLEAN: scored")
pq_assert(r$peak_cor > 0.95, "F_CLEAN: peak_cor > 0.95")
pq_assert(r$SNR > 10, "F_CLEAN: SNR > 10")
pq_assert(abs(r$apex_rt - 6.0) < 0.01, "F_CLEAN: apex recovered at ~6.00 min")
pq_assert(abs(r$input_rt - 6.0) < 1e-9, "F_CLEAN: input RT reported")
pq_assert(r$n_points > 30, "F_CLEAN: enough scans inside the peak")
pq_assert(grepl("ppm", r$mz_tol), "F_CLEAN: m/z tolerance recorded")

r <- get("F_NOISY")
pq_assert(r$score_status == "ok", "F_NOISY: still scored")
pq_assert(r$peak_cor < get("F_CLEAN")$peak_cor,
          "F_NOISY: noisier peak gets a lower peak_cor than the clean one")

r <- get("F_TWO")
pq_assert(r$boundary_status == "ambiguous", "F_TWO: two local maxima -> ambiguous")
pq_assert(r$score_status == "ok", "F_TWO: ambiguous peak is still scored for review")
pq_assert_contains(r$failure_reason, "candidate apexes", "F_TWO: reason lists the candidates")

r <- get("F_SHOULDER")
pq_assert(r$boundary_status == "ambiguous", "F_SHOULDER: asymmetric peak flagged")
pq_assert(r$score_status == "ok", "F_SHOULDER: scored")

r <- get("F_MULTI")
pq_assert(r$score_status == "ok", "F_MULTI: scored")
pq_assert(r$n_scans_multi > 0, "F_MULTI: several m/z per scan detected and reported")

r <- get("F_SHIFT")
pq_assert(r$boundary_status == "apex_outside", "F_SHIFT: apex outside tolerance flagged")
pq_assert(r$score_status == "ok", "F_SHIFT: still scored, with the flag visible")

r <- get("F_EDGE")
pq_assert(r$boundary_status == "boundary_unclear", "F_EDGE: clipped flank flagged")
pq_assert(!is.na(r$edge_touched), "F_EDGE: clipped side recorded")

r <- get("F_NARROW")
pq_assert(r$boundary_status == "too_few_points", "F_NARROW: too few scans flagged")
pq_assert(r$score_status == "skipped", "F_NARROW: author's <5 guard applied")
pq_assert(is.na(r$peak_cor), "F_NARROW: no score invented")

r <- get("F_NOSIGNAL")
pq_assert(r$boundary_status == "no_signal", "F_NOSIGNAL: no signal")
pq_assert(r$presence == "absent", "F_NOSIGNAL: reported absent in this sample")
pq_assert(r$score_status == "absent", "F_NOSIGNAL: not attempted, marked absent")
pq_assert_contains(r$failure_reason, "no ion inside the m/z tolerance window",
                   "F_NOSIGNAL: reason recorded")

r <- get("F_LATE")
pq_assert(r$boundary_status == "no_signal", "F_LATE: apex outside the window -> no signal")
pq_assert(r$presence == "absent", "F_LATE: absent from this sample as well")

pq_assert(!any(rows$score_status %in% c("ok", "skipped") & is.na(rows$peak_cor)
               & rows$score_status == "ok"),
          "no row claims 'ok' with a missing score")

pq_section("failure list keeps every non-scored feature but not the absent ones")
fails <- pq_failures(rows)
pq_assert(nrow(fails) == sum(!rows$score_status %in% c("ok", "absent")),
          "every non-scored, non-absent row appears in the failure list")
pq_assert(!any(fails$feature_id == "F_CLEAN"), "scored rows are not in the failure list")
pq_assert(!any(fails$feature_id %in% c("F_NOSIGNAL", "F_LATE")),
          "absent peaks are not listed as failures")
absent <- pq_absent_table(rows)
pq_assert(nrow(absent) == sum(rows$presence %in% "absent"),
          "absent peaks have their own table, so nothing disappears")
pq_assert(all(rows$score_status[rows$presence %in% "absent"] %in% "absent"),
          "absent rows are never scored")

pq_section("candidate table is exported for review")
cands <- pq_candidates_table(res$detail)
pq_assert(nrow(cands) >= 10, "candidate rows present")
pq_assert(all(c("feature_key", "apex_rt", "start_rt", "end_rt", "selected")
              %in% names(cands)), "candidate table has boundaries and the selection flag")

pq_section("unmatched sample and unreadable file are reported, not skipped")
feat_bad <- feat[1, , drop = FALSE]
feat_bad$sample_id <- "S9"
lookup_bad <- pq_match_samples("S9", files)
res_bad <- pq_process_features(feat_bad, p, lookup_bad)
pq_assert(res_bad$rows$boundary_status == "sample_unmatched",
          "unmatched sample -> sample_unmatched")
pq_assert(res_bad$rows$score_status == "not_run", "unmatched sample -> not scored")

bogus <- file.path(tempdir(), "does_not_exist.mzML")
writeLines("not a mass spec file", bogus)
feat_err <- feat[1, , drop = FALSE]
feat_err$sample_id <- "S1"
lookup_err <- data.frame(sample_id = "S1", file = bogus, match = "manual",
                         n_candidates = 1L, stringsAsFactors = FALSE)
res_err <- pq_process_features(feat_err, p, lookup_err)
pq_assert(res_err$rows$boundary_status == "file_error",
          "unreadable file -> file_error with a message")
pq_assert_contains(res_err$rows$failure_reason, "read error",
                   "file_error keeps the parser message")

pq_section("mzXML file gives the same answer as mzML")
feat_x <- feat[feat$feature_id == "F_CLEAN", , drop = FALSE]
lookup_x <- pq_match_samples("S1", fx$mzxml)
res_x <- pq_process_features(feat_x, p, lookup_x, ms_cache = new.env(parent = emptyenv()))
pq_assert(res_x$rows$score_status == "ok", "mzXML: scored")
pq_assert_equal(res_x$rows$peak_cor, get("F_CLEAN")$peak_cor,
                "mzXML and mzML give the same peak_cor", tol = 1e-6)
pq_assert_equal(res_x$rows$n_points, get("F_CLEAN")$n_points,
                "mzXML and mzML give the same peak width")

pq_section("second sample is processed with its own file")
feat_s2 <- feat[feat$feature_id == "F_CLEAN", , drop = FALSE]
feat_s2$sample_id <- "S2"
lookup_s2 <- pq_match_samples("S2", files)
res_s2 <- pq_process_features(feat_s2, p, lookup_s2, ms_cache = new.env(parent = emptyenv()))
pq_assert(res_s2$rows$score_status == "ok", "S2: scored from S2.mzML")
pq_assert(abs(res_s2$rows$apex_rt - 6.0) < 0.01, "S2: same apex RT")
pq_assert_contains(res_s2$rows$file, "S2.mzML", "S2: correct file recorded")

pq_section("exports")
csv_p <- file.path(tempdir(), "pq_out.csv")
utils::write.csv(rows[, pq_result_columns(rows)], csv_p, row.names = FALSE)
pq_assert(file.exists(csv_p) && nrow(utils::read.csv(csv_p)) == 10, "CSV export")

xlsx_p <- file.path(tempdir(), "pq_out.xlsx")
pq_export_xlsx(xlsx_p, rows, res$detail, p, mapping, lookup)
sh <- openxlsx::getSheetNames(xlsx_p)
pq_assert(all(c("Results", "Candidates", "Failures", "Parameters",
                "SampleMapping", "FieldMapping", "Provenance") %in% sh),
          "XLSX export has all sheets")
res_sheet <- openxlsx::read.xlsx(xlsx_p, sheet = "Results")
pq_assert(nrow(res_sheet) == 10, "XLSX Results sheet holds all rows")
prov_sheet <- openxlsx::read.xlsx(xlsx_p, sheet = "Provenance")
pq_assert(any(grepl("squallms", prov_sheet[[1]])), "XLSX carries the provenance")

zip_p <- file.path(tempdir(), "pq_report.zip")
pq_export_report_zip(zip_p, file.path(tempdir(), "pq_zip_work"), rows, res$detail,
                     p, mapping, lookup, max_plots = 3)
zl <- utils::unzip(zip_p, list = TRUE)
pq_assert(any(grepl("peak_quality_results.csv", zl$Name)), "ZIP contains the results table")
pq_assert(any(grepl("peak_quality_failures.csv", zl$Name)), "ZIP contains the failure list")
pq_assert(any(grepl("parameters.csv", zl$Name)), "ZIP contains the run parameters")
pq_assert(any(grepl("provenance.txt", zl$Name)), "ZIP contains the provenance")
pq_assert(any(grepl("sessionInfo.txt", zl$Name)), "ZIP contains sessionInfo")
pq_assert(any(grepl("peak_quality_report.pdf", zl$Name)), "ZIP contains the PDF report")
pq_assert(any(grepl("peaks/.*png", zl$Name)), "ZIP contains per-peak PNGs")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

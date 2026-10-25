# ============================================================
# Full-scale validation: run the exact job that used to be truncated
# ============================================================
#   Rscript tests/peak_quality/demo/run_full_scale.R
#
# 3450 aligned features x 20 real Thermo .raw files = 69000 sample rows.
# This is not a unit test (it needs the local raw data); it exists to prove
# that the job-size fix works at real scale and to report how many rows are
# absent / scored.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
ROOT <- normalizePath(file.path(here, "../../.."), winslash = "/")
source(file.path(ROOT, "tests/peak_quality/helpers.R"))
pq_source_project(ROOT)

RAW_DIR <- "G:/method_ms2/MSDIAL_TEST"
TABLE <- file.path(RAW_DIR, "peak_quality_demo_aligned20.csv")
OUT <- file.path(tempdir(), "pq_full_scale")
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

files <- sort(list.files(RAW_DIR, pattern = "\\.(raw|mzML|mzXML)$",
                         ignore.case = TRUE, full.names = TRUE))
# optional argv[1] = how many raw files to use (default: all)
argv <- commandArgs(trailingOnly = TRUE)
if (length(argv) >= 1 && nzchar(argv[1])) {
  files <- utils::head(files, as.integer(argv[1]))
}
cat(sprintf("raw files: %d\n", length(files)))

raw_tab <- pq_read_table(TABLE)
cat(sprintf("peak table: %d rows, %d columns\n", nrow(raw_tab), ncol(raw_tab)))

map <- pq_guess_mapping(names(raw_tab))
str(map)
std <- pq_standardize_features(raw_tab, map, rt_unit = "min")
cat(sprintf("standardised: %d valid, %d rejected\n", nrow(std$ok),
            if (is.null(std$bad)) 0L else nrow(std$bad)))

p <- pq_default_params()
plan <- pq_plan_job(nrow(std$ok), length(files), broadcast = TRUE,
                    max_features = p$max_features,
                    max_rows = p$max_expanded_rows)
cat(sprintf("plan: %d features x %d files = %d rows | truncate=%s abort=%s\n",
            plan$n_features_input, plan$n_files, plan$rows_planned,
            plan$truncate_features, plan$abort))
if (length(plan$messages) > 0) cat(paste(plan$messages, collapse = "\n"), "\n")

feat <- pq_expand_features(std$ok, files)
cat(sprintf("expanded: %d rows\n", nrow(feat)))
stopifnot(nrow(feat) == plan$rows_planned)

lookup <- pq_match_samples(unique(feat$sample_id), files)
cat(sprintf("samples matched: %d of %d\n",
            sum(!lookup$match %in% c("none", "ambiguous")), nrow(lookup)))

t0 <- Sys.time()
res <- pq_process_features(
  feat, p, lookup,
  ms_cache = new.env(parent = emptyenv()),
  log_fun = function(msg) cat(sprintf("[%s] %s\n", format(Sys.time(), "%H:%M:%S"), msg)),
  progress_fun = function(value, detail) {
    if (value >= 0.999) cat("progress: done\n")
  })
elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

rows <- res$rows
cat(sprintf("\n==== done in %.1f s (%.1f min) ====\n", elapsed, elapsed / 60))
cat(sprintf("rows returned          : %d\n", nrow(rows)))
cat(sprintf("scored (ok)            : %d\n", sum(rows$score_status == "ok")))
cat(sprintf("absent (no peak)       : %d\n", sum(rows$presence %in% "absent")))
cat(sprintf("fully evaluated feats  : %d of %d\n",
            sum(tapply(rows$presence, rows$feature_id,
                       function(x) any(x %in% "present"))),
            length(unique(rows$feature_id))))
print(table(rows$boundary_status, useNA = "ifany"))
print(table(rows$presence, useNA = "ifany"))

sm <- pq_feature_summary(rows)
cat("\nfeature summary:\n")
print(table(sm$consistency))
cat(sprintf("median peak_cor across scored rows: %.4f\n",
            stats::median(rows$peak_cor, na.rm = TRUE)))

xl <- file.path(OUT, "full_scale.xlsx")
pq_export_xlsx(xl, rows, res$detail, p, map, lookup, summary = sm)
cat(sprintf("xlsx: %s (%.1f MB)\n", xl, file.size(xl) / 1e6))
g <- gc()
cat(sprintf("peak memory in this process: %.0f MB\n", sum(g[, 6])))

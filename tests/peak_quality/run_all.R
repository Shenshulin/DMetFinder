# ============================================================
# Run the whole Peak Quality test suite
# ============================================================
#   Rscript tests/peak_quality/run_all.R
#
# Each test file runs in its own R process so that a failure cannot leave
# state behind for the next one. Exit status is non-zero when any check fails.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()

rscript <- file.path(R.home("bin"), "Rscript")
files <- sort(list.files(here, pattern = "^test_.*[.]R$", full.names = TRUE))

results <- data.frame(file = basename(files), status = NA_character_,
                      checks = NA_character_, stringsAsFactors = FALSE)

for (i in seq_along(files)) {
  f <- files[i]
  cat("\n\n########## ", basename(f), " ##########\n")
  out <- suppressWarnings(system2(rscript, c("--vanilla", shQuote(f)),
                                  stdout = TRUE, stderr = TRUE))
  cat(paste(out, collapse = "\n"), "\n")
  status <- attr(out, "status")
  if (is.null(status)) status <- 0L
  summary_line <- grep("^---- .*checks:", out, value = TRUE)
  results$checks[i] <- if (length(summary_line) > 0) {
    sub("^---- ", "", summary_line[length(summary_line)])
  } else {
    "no summary (crashed)"
  }
  results$status[i] <- if (status == 0) "OK" else "FAILED"
}

cat("\n\n================ SUMMARY ================\n")
print(results, row.names = FALSE)
failed <- sum(results$status != "OK")
cat(sprintf("\n%d/%d test files passed\n", length(files) - failed, length(files)))
if (failed > 0) quit(save = "no", status = 1)

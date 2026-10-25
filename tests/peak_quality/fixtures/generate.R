# Generate the synthetic fixtures into a directory (CLI helper).
#   Rscript tests/peak_quality/fixtures/generate.R [outdir]
# Default outdir: tests/peak_quality/fixtures/generated
# Used by the UI smoke test and by manual browser testing.

args <- commandArgs(trailingOnly = TRUE)
here <- {
  a <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", a[grep("^--file=", a)])
  if (length(f) == 1) dirname(normalizePath(f)) else getwd()
}

source(file.path(here, "make_fixtures.R"))

out <- if (length(args) >= 1) args[1] else file.path(here, "generated")
fx <- pq_fixture_make(out)
cat("fixtures written to:", fx$dir, "\n")
cat("  mzML :", basename(fx$mzml), "\n")
cat("  mzML2:", basename(fx$mzml2), "\n")
cat("  mzXML:", basename(fx$mzxml), "\n")
cat("  peak tables:", paste(basename(c(fx$features_min, fx$features_sec,
                                      fx$features_mzmine, fx$features_msdial)),
                            collapse = ", "), "\n")

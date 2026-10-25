# ============================================================
# Test 05 (scoring): the vendored author function must reproduce the
# published implementation bit-for-bit on fixed inputs.
# ============================================================
# The expected values in fixtures/qscore_oracle.csv were produced by running
# the ORIGINAL MS_metrics implementation (feature_extraction.R,
# commit 491deaf1d5f27f9d276e58acb4c1dfca2a2e21b9) on the fixed XIC vectors
# stored in fixtures/cases.rds. The upstream source is not redistributed
# because that repository has no license file; only its numeric output is
# stored here, which is what this regression test needs.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))

ROOT <- normalizePath(file.path(here, "../.."), winslash = "/")
pq_source_project(ROOT)

pq_section("author scoring function - oracle regression")

cases <- readRDS(file.path(here, "fixtures/cases.rds"))
oracle <- read.csv(file.path(here, "fixtures/qscore_oracle.csv"),
                   stringsAsFactors = FALSE, na.strings = "NA")

for (k in seq_len(nrow(oracle))) {
  nm <- oracle$case[k]
  cc <- cases[[nm]]
  sc <- pq_score_xic(cc$rt, cc$int)

  if (!is.na(oracle$upstream_error[k])) {
    pq_assert(sc$score_status == "failed",
              sprintf("%s: upstream error surfaced as score_status='failed'", nm))
    pq_assert_contains(sc$failure_reason, "author function error",
                       sprintf("%s: failure_reason names the author function", nm))
    next
  }

  if (is.na(oracle$SNR[k])) {
    pq_assert(sc$score_status == "skipped",
              sprintf("%s: <5 points -> skipped by the author guard", nm))
    pq_assert_contains(sc$failure_reason, "fewer than 5 scans",
                       sprintf("%s: failure reason explains the guard", nm))
    next
  }

  pq_assert(sc$score_status == "ok", sprintf("%s: scored", nm))
  pq_assert_equal(sc$SNR, as.numeric(oracle$SNR[k]),
                  sprintf("%s: SNR matches MS_metrics output", nm), tol = 1e-12)
  pq_assert_equal(sc$peak_cor, as.numeric(oracle$peak_cor[k]),
                  sprintf("%s: peak_cor matches MS_metrics output", nm), tol = 1e-12)
}

pq_section("input normalisation is explicit and auditable")
prep <- pq_prepare_scoring_input(c(6.2, 6.0, 6.1, 6.1), c(10, 30, 20, 99))
pq_assert_equal(prep$rt, c(6.0, 6.1, 6.2), "rt sorted ascending")
pq_assert_equal(prep$intensity, c(30, 99, 10),
                "duplicated RT collapsed by maximum intensity (never summed)")
pq_assert_equal(prep$n_duplicate_rt, 1L, "duplicate RT counted")

prep2 <- pq_prepare_scoring_input(c(6, NA, 6.1), c(10, 5, NA))
pq_assert_equal(length(prep2$rt), 1L, "NA pairs dropped")
pq_assert_equal(prep2$n_dropped_na, 2L, "dropped NA pairs counted")

pq_section("scoring never invents numbers")
sc_empty <- pq_score_xic(numeric(0), numeric(0))
pq_assert(sc_empty$score_status == "skipped" && is.na(sc_empty$SNR),
          "empty XIC -> skipped, SNR NA")
sc_flat <- pq_score_xic(seq(5, 5.4, length.out = 20), rep(100, 20))
pq_assert(sc_flat$score_status == "failed" && is.na(sc_flat$peak_cor),
          "flat XIC -> failed (upstream cor() error), no fabricated score")
sc_na <- pq_score_xic(c(5, NA, 5.1, 5.2, 5.3, 5.4), c(1, 2, NA, 4, 5, 6))
pq_assert(sc_na$score_status %in% c("ok", "failed", "not_finite", "skipped"),
          "NA-containing XIC does not crash the run")

pq_section("provenance is carried with every export")
prov <- pq_provenance_lines()
pq_assert_contains(prov, "491deaf1d5f27f9d276e58acb4c1dfca2a2e21b9",
                   "provenance records the MS_metrics commit")
pq_assert_contains(prov, "2f4038ce401b2415c36daeab5928957c214a3205",
                   "provenance records the squallms commit")
pq_assert_contains(prov, "MIT", "provenance records the license")
pq_assert_contains(prov, "No LICENSE file",
                   "provenance records that MS_metrics has no license")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

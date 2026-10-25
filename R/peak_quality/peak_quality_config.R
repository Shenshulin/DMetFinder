# ============================================================
# Peak Quality Assessment - configuration and provenance
# ============================================================
# This module is an addition to DMetFinder 1.0.3. It reads user-supplied
# feature lists (MZmine / MS-DIAL / other), re-extracts the XIC of every
# feature from the user-supplied raw files, locates candidate peak
# boundaries automatically, and scores peak shape with the scoring code
# published by Kumler et al. 2023 (BMC Bioinformatics 24:436).
#
# The upstream scoring function is NOT re-implemented here; see
# R/peak_quality/vendor/squallms_qscore.R for provenance.
# ============================================================

PQ_ENGINE_VERSION <- "1.0.0"

# ------------------------------------------------------------
# Provenance of the scoring algorithm
# ------------------------------------------------------------
PQ_PROVENANCE <- list(
  paper = list(
    title = "Picky with peakpicking: assessing chromatographic peak quality with simple metrics in metabolomics",
    journal = "BMC Bioinformatics 24:436 (2023)",
    doi = "10.1186/s12859-023-05533-4"
  ),
  # Paper's original code repo - NO license file, therefore not redistributed
  ms_metrics = list(
    repo = "https://github.com/wkumler/MS_metrics",
    commit = "491deaf1d5f27f9d276e58acb4c1dfca2a2e21b9",
    commit_date = "2023-08-02",
    file = "feature_extraction.R",
    function_name = "qscoreCalculator",
    license = "No LICENSE file in repository (GitHub license API returns 404) - source not redistributed"
  ),
  # Author-maintained successor package - MIT, used as the executable source
  squallms = list(
    repo = "https://github.com/wkumler/squallms",
    commit = "2f4038ce401b2415c36daeab5928957c214a3205",
    commit_date = "2026-09-02",
    package_version = "0.99.7",
    file = "R/extractChromMetricsFunctions.R",
    function_name = "qscoreCalculator",
    license = "MIT + file LICENSE (Copyright 2024 William Kumler)"
  )
)

# Numeric equivalence between the two upstream copies was verified by
# running both on the fixed inputs stored in
# tests/peak_quality/fixtures/qscore_oracle.csv (see
# tests/peak_quality/test_05_scoring.R). Documented differences:
#   - squallms version drops NA rt/int before scoring
#   - squallms returns a named numeric vector, MS_metrics a list
# The arithmetic is identical.

# ------------------------------------------------------------
# Default analysis parameters
# ------------------------------------------------------------
# These are *starting points*, not validated optima. The UI labels them as
# defaults and lets the user change every one of them.
pq_default_params <- function() {
  list(
    # ---- m/z matching (exactly one unit is active) ----
    mz_tol_unit = "ppm",       # "ppm" | "Da"
    mz_tol_ppm  = 10,
    mz_tol_da   = 0.005,
    # how multiple peaks inside the tolerance window are collapsed into one
    # intensity value per scan: "max" | "nearest" | "sum" | "mean"
    xic_aggregate = "max",

    # ---- RT search ----
    rt_unit = "min",           # peak-table RT unit: "min" | "sec"
    rt_window = 0.30,          # half-window (in the unit above), minutes
    rt_min = 0.0,
    rt_max = 30.0,

    # ---- XIC smoothing applied BEFORE the analysis (opt-in) ----
    # Off by default. When enabled, the smoothed trace is what boundary
    # detection, the scored peak slice, the CPC input and the peak-group
    # image all see. Peak presence is NOT affected: its height and
    # point-to-point noise are always measured on the raw trace, because
    # smoothing would lower the noise estimate and manufacture presence.
    # See R/peak_quality/eic_smooth.R.
    eic_smooth_method = "none",  # "none" | "savgol" | "movavg"
    eic_smooth_window = 7L,      # scans; forced to an odd number >= 3
    eic_smooth_order  = 2L,      # Savitzky-Golay polynomial order (max 3)

    # ---- peak boundary detection (pre-processing, not the paper metrics) ----
    min_points      = 5,       # scans required inside the detected peak
    # Extra moving average used ONLY to locate the apex, applied on top of
    # the analysis trace. It never changes the intensities that are scored.
    # This is NOT the same switch as eic_smooth_* above, which does change
    # them; keep both 0/"none" unless you know which one you want.
    smooth_points   = 0,       # 0 = no smoothing for detection (odd numbers only)
    min_prominence_frac = 0.05,
    min_height_frac = 0.10,
    min_rel_prominence = 0.25, # vs the largest prominence in the window
    edge_frac       = 0.10,
    valley_frac     = 0.05,    # a valley must drop this low to split two peaks
    apex_tolerance  = 0.20,    # min; |apex_rt - input_rt| beyond this is flagged

    # ---- peak presence (is the compound in this sample at all?) ----
    # An aligned table asks for "this feature in every sample", but a compound
    # is frequently absent from some samples. Those rows must not be reported
    # as scoring failures, and must not drag down the per-feature summary.
    detect_absent   = TRUE,    # FALSE = every row with any ion in the window is scored
    absent_snr      = 5,       # peak height / point-to-point noise below this -> absent
    absent_min_points = 3,     # fewer XIC points than this -> absent (no peak can form)

    # ---- batch ----
    # Safety cap on the number of PEAK TABLE features (rows of the input file).
    # It is applied BEFORE an aligned table is expanded, so a 3450-feature
    # aligned table times 20 raw files is never truncated to a handful of rows.
    max_features = 20000L,
    # Hard guard on the expanded job size. It aborts loudly instead of
    # silently dropping rows; nothing is ever processed partially.
    max_expanded_rows = 200000L,
    sequential = TRUE,         # the current architecture has no parallel backend

    # ---- sample scope ----
    # "auto"      : use the sample_id column when it is mapped, otherwise
    #               evaluate every feature in every raw file
    # "all_files" : always evaluate every feature in every raw file (aligned
    #               tables such as the MS-DIAL alignment result: one row per
    #               feature with a shared average m/z and RT)
    # "by_column" : always require the sample_id column
    sample_scope = "auto"
  )
}

# ------------------------------------------------------------
# Feature-level summary (aligned-table mode)
# ------------------------------------------------------------
# These thresholds are descriptive defaults chosen for readability, NOT
# validated cut-offs. The summary never claims pass/fail; it only says how
# consistent the per-sample results of one feature are.
pq_summary_thresholds <- function() {
  list(
    min_scored_frac_consistent   = 0.8,
    min_boundary_frac_consistent = 0.8,
    min_scored_frac_variable     = 0.5
  )
}

# Rows rendered in the interactive table before the browser starts to
# struggle. Nothing is hidden from the exports: CSV / XLSX / ZIP always carry
# every row, and the table says so when it is truncated for display only.
#
# 5000, not 20000: the table is client-side DT, so every row is serialised into
# one websocket message and then expanded into JS objects in the tab. Measured
# on the 44-column result table, 20000 rows is a 9.6 MB message and a few
# hundred MB in the browser - on a machine that is already short of memory that
# is enough to take the tab (and the session) down. 5000 rows is ~2.4 MB and
# still more than anyone reviews by hand.
PQ_DISPLAY_ROWS <- 5000L

# Feature choices sent to the "Feature to inspect" dropdown. The list is
# searchable but every entry is shipped to the browser, so it is capped on
# very large jobs (the table and the exports are never capped).
PQ_PEAK_CHOICES <- 10000L

PQ_SUMMARY_LABELS <- c(
  consistent        = "Consistent across samples",
  variable          = "Variable across samples",
  poor              = "Poor across samples",
  single_sample     = "Only one sample with the peak",
  absent_everywhere = "No peak in any sample",
  not_evaluated     = "Not evaluated in any sample"
)

pq_summary_label <- function(x) {
  lab <- PQ_SUMMARY_LABELS[as.character(x)]
  lab[is.na(lab)] <- as.character(x)[is.na(lab)]
  as.character(lab)
}

PQ_SCOPE_CHOICES <- c(
  "Auto (use sample_id column when mapped)" = "auto",
  "Every feature in every raw file (aligned table)" = "all_files",
  "Match rows by the sample_id column" = "by_column"
)

# ------------------------------------------------------------
# Lookup tables used by the UI
# ------------------------------------------------------------
PQ_AGGREGATE_CHOICES <- c(
  "Highest intensity (max)"        = "max",
  "Closest m/z (nearest)"          = "nearest",
  "Sum of window (sum)"            = "sum",
  "Mean of window (mean)"          = "mean"
)

PQ_STATUS_LABELS <- c(
  ok               = "OK",
  ambiguous        = "Ambiguous (multiple candidates)",
  boundary_unclear = "Boundary unclear",
  too_few_points   = "Too few scans",
  no_signal        = "No MS1 signal",
  no_clear_apex    = "No clear apex",
  apex_outside     = "Apex outside window",
  no_ms1_scans     = "No MS1 scans in window",
  sample_unmatched = "Sample not matched to a file",
  sample_ambiguous = "Sample matched to several files",
  file_error       = "Raw file could not be read",
  invalid_row      = "Invalid peak table row"
)

# ------------------------------------------------------------
# Peak presence
# ------------------------------------------------------------
# "present" : a peak above the noise exists in this sample -> scored
# "absent"  : the compound is not in this sample -> NOT scored, NOT a failure
# "unknown" : the file / scan could not be used, presence cannot be judged
PQ_PRESENCE_LABELS <- c(
  present = "Peak present",
  absent  = "No peak in this sample",
  unknown = "Presence not determined"
)

pq_presence_label <- function(x) {
  lab <- PQ_PRESENCE_LABELS[as.character(x)]
  lab[is.na(lab)] <- as.character(x)[is.na(lab)]
  as.character(lab)
}

pq_status_label <- function(x) {
  lab <- PQ_STATUS_LABELS[as.character(x)]
  lab[is.na(lab)] <- as.character(x)[is.na(lab)]
  as.character(lab)
}

# ============================================================
# Peak Quality - method registry
# ============================================================
# One place that says, for every scoring method the module knows about:
#   * what kind of input it needs (one XIC vs. a cross-sample peak group),
#   * which native metrics it publishes and in which unit,
#   * where the code comes from, under which licence, at which commit,
#   * whether it can actually run in this session right now.
#
# Nothing in the UI or the pipeline may claim a method is available without
# asking pq_method_available() first: a method that is merely *known* is not
# a method that can be *executed*.
# ============================================================

PQ_METHOD_IDS <- c("kumler", "cpc", "dnn")

# ------------------------------------------------------------
# Static descriptions (code provenance, input contract, licences)
# ------------------------------------------------------------
PQ_METHODS <- list(
  kumler = list(
    id = "kumler",
    label = "Kumler: peak-shape correlation + custom SNR",
    short = "Kumler",
    kind = "single_xic",
    input = "one XIC per sample",
    metrics = c("peak_cor", "SNR"),
    default_raw_score = "peak_cor",
    probability = FALSE,
    provenance = list(
      paper = "Kumler et al. 2023, BMC Bioinformatics 24:436",
      doi = "10.1186/s12859-023-05533-4",
      code = "squallms 0.99.7, qscoreCalculator()",
      commit = "2f4038ce401b2415c36daeab5928957c214a3205",
      license = "MIT",
      local_changes = "none (vendored verbatim)"
    ),
    note = paste("Two independent metrics; no composite score exists in the",
                 "paper. peak_cor is a correlation, not a probability.")
  ),

  cpc = list(
    id = "cpc",
    label = "CPC: chromatographic peak characterisation + boundaries",
    short = "CPC",
    kind = "single_xic",
    input = "one XIC per sample (cpc::chromFromTrace, no XCMS object)",
    metrics = c("rt", "rtmin", "rtmax", "fwhm", "wb", "a", "b", "tf",
                "height", "area", "sn", "front_code", "tail_code"),
    default_raw_score = NA_character_,
    probability = FALSE,
    provenance = list(
      paper = "Pirttila et al. 2022, Comprehensive Peak Characterization (CPC) in Untargeted LC-MS Analysis",
      doi = "10.3390/metabo12020109",
      code = "cpc 0.1.0, chromFromTrace() + processChromatogram()",
      commit = "GitHub krispir/cpc master as installed (version 0.1.0)",
      license = "GPL (>= 2) - used as an external package, NOT vendored",
      local_changes = "none (author code called as installed)"
    ),
    note = paste("area is reported exactly as the package computes it: its",
                 "unit is intensity x scan count, NOT intensity x time, so it",
                 "must not be compared across different scan rates.",
                 "sn is reported unfiltered; the package's min_sn filter is",
                 "never applied.")
  ),

  dnn = list(
    id = "dnn",
    label = "Deep neural network: cross-sample peak-group classification",
    short = "DNN",
    kind = "peak_group",
    input = paste("one aligned peak group (all samples of a feature) rendered as",
                  "an image, then converted to the model grid"),
    metrics = c("dnn_score", "dnn_prediction"),
    default_raw_score = "dnn_score",
    # The network was never calibrated (no isotonic / Platt step anywhere in the
    # author code), so its output is a score, not a probability. Saying
    # probability = TRUE here would leak into the unified table and let a reader
    # average it with a correlation.
    probability = FALSE,
    provenance = list(
      paper = "Kantz et al. 2019, Deep Neural Networks for Classification of LC-MS Spectral Peaks",
      doi = "10.1021/acs.analchem.9b02983",
      code = "JainLab/Manuscript-DNNs-for-Classification-of-LCMS-Peaks",
      commit = "94237bf45e790a8332e45a2f2842116f46a18aa9",
      license = paste("code: Univ. of California (research / non-profit only).",
                      "data: CC0 1.0. Weights: locally trained derivative of the",
                      "author code - treated as the stricter of the two."),
      local_changes = paste("training script ported to Keras 3 / TF 2.x; the",
                            "published .mat is used as-is, so the network,",
                            "the split and the labels are the author's"),
      weights = "DNN_reference/models/*.h5, verified against *_train_log.json",
      data = "MassIVE MSV000084186 (CC0 1.0), EDML_trainTestCalData15.mat"
    ),
    note = paste("One prediction per peak group, not per sample. The score is",
                 "an uncalibrated model output; it is not a probability and it",
                 "never becomes a quality_class. Scores are not comparable",
                 "between runs with different numbers of samples, and the model",
                 "is known to accept double peaks and shoulders.")
  )
)

# Unit of analysis. The whole point of keeping this in the registry is that no
# caller has to remember which method answers a group-level question and which
# one answers a single-peak question.
pq_method_scope <- function(id) {
  info <- PQ_METHODS[[as.character(id)[1]]]
  if (is.null(info)) return(NA_character_)
  if (identical(info$kind, "peak_group")) "peak_group" else "single_sample"
}

pq_method_info <- function(id) {
  info <- PQ_METHODS[[as.character(id)[1]]]
  if (is.null(info)) stop("unknown method: ", id, call. = FALSE)
  info
}

# ------------------------------------------------------------
# Native metric dictionary
# ------------------------------------------------------------
# unit is shown in the UI and in the export; generic = FALSE marks a value
# that must not be pooled with another method's value of a similar name.
PQ_METRIC_DEFS <- list(
  # ---- Kumler ----
  kumler.peak_cor = list(label = "Beta-fit correlation", unit = "correlation (-1..1)",
                         note = "NOT a probability of being a good peak"),
  kumler.SNR = list(label = "Custom signal-to-noise", unit = "ratio (unitless)",
                    note = "max-min divided by the residual derivative scale; not comparable to CPC sn"),

  # ---- CPC ----
  cpc.rt = list(label = "Apex retention time", unit = "min", note = ""),
  cpc.rtmin = list(label = "Peak start", unit = "min", note = "CPC front peak bound"),
  cpc.rtmax = list(label = "Peak end", unit = "min", note = "CPC tail peak bound"),
  cpc.fwhm = list(label = "FWHM", unit = "min", note = "width at 50% height"),
  cpc.wb = list(label = "Base width", unit = "min", note = "width at 1% height"),
  cpc.a = list(label = "Front width", unit = "min", note = "apex - RT at 10% height"),
  cpc.b = list(label = "Tail width", unit = "min", note = "RT at 10% height - apex"),
  cpc.tf = list(label = "Tailing factor", unit = "ratio", note = "b / a, 1.0 = symmetric"),
  cpc.height = list(label = "Peak height", unit = "intensity", note = "above the fitted baseline"),
  cpc.area = list(label = "Peak area (author value)",
                  unit = "intensity x scan count",
                  note = paste("CPC integrates over scan INDICES, not over RT",
                               "(audit 2.3); scales with the scan rate, do not",
                               "compare across methods or scan rates")),
  cpc.sn = list(label = "Signal-to-noise (author value)", unit = "ratio",
                note = paste("2*height/N with the author's noise pool; the pool",
                             "keeps part of the peak, so sn shrinks as the peak",
                             "gets wider (audit 2.4). Reported, never filtered.")),
  cpc.front_code = list(label = "Front boundary code", unit = "B/V/S/R",
                        note = "B baseline, V valley, S shoulder, R rounded"),
  cpc.tail_code = list(label = "Tail boundary code", unit = "B/V/S/R",
                       note = "B baseline, V valley, S shoulder, R rounded")
)

pq_metric_def <- function(method, metric) {
  key <- paste0(method, ".", metric)
  d <- PQ_METRIC_DEFS[[key]]
  if (is.null(d)) {
    return(list(label = metric, unit = "", note = ""))
  }
  d
}

# ------------------------------------------------------------
# Availability
# ------------------------------------------------------------
# A method is executable only when its runtime is present. `kumler` is
# vendored (always available). `cpc` needs the GPL package cpc, which is
# deliberately NOT bundled: it is a compiled package that drags in xcms.
# `dnn` needs a trained model whose SHA-256 still matches its training log.
#
# The DNN answer is expensive-ish (hashing a few MB of weights), so it is
# memoised on the file's path + size + mtime. The memo is in this session only;
# a rebuilt or swapped model invalidates it automatically.
PQ_DNN_AVAIL_CACHE <- new.env(parent = emptyenv())

pq_method_available <- function(id) {
  id <- as.character(id)[1]
  if (identical(id, "kumler")) {
    return(list(ok = TRUE, version = "squallms 0.99.7 (vendored)",
                reason = NA_character_))
  }
  if (identical(id, "cpc")) return(pq_cpc_available())
  if (identical(id, "dnn")) {
    # The registry is sourced before the DNN bridge in some contexts (and only
    # the registry in others), so never assume the function is there.
    if (!exists("pq_dnn_find_model", mode = "function")) {
      return(list(ok = FALSE, version = NA_character_,
                  reason = "the DNN bridge is not loaded in this session"))
    }
    paths <- tryCatch(pq_dnn_paths(), error = function(e) NULL)
    if (is.null(paths)) {
      return(list(ok = FALSE, version = NA_character_,
                  reason = "the DNN reference directory could not be located"))
    }
    h5 <- list.files(paths$model_dir, pattern = "\\.h5$", full.names = TRUE)
    key <- if (length(h5) == 0) "none" else {
      st <- file.info(h5[which.max(file.info(h5)$mtime)])
      paste(st$size, as.numeric(st$mtime), sep = "-")
    }
    # NB: indexed access, not get()/exists(). A user script in this project
    # defines its own `get()`, and a masked base function would make this cache
    # fail at run time rather than at load time.
    if (key %in% ls(PQ_DNN_AVAIL_CACHE)) {
      return(PQ_DNN_AVAIL_CACHE[[key]])
    }
    m <- tryCatch(pq_dnn_find_model(paths), error = function(e) NULL)
    out <- if (is.null(m)) {
      list(ok = FALSE, version = NA_character_,
           reason = "the DNN model could not be inspected")
    } else if (isTRUE(m$available)) {
      list(ok = TRUE, version = substr(as.character(m$sha256), 1, 12),
           reason = NA_character_, model = m)
    } else {
      list(ok = FALSE, version = NA_character_,
           reason = paste0("model_not_available: ", m$status, " - ", m$detail))
    }
    assign(key, out, envir = PQ_DNN_AVAIL_CACHE)
    return(out)
  }
  list(ok = FALSE, version = NA_character_, reason = paste0("unknown method: ", id))
}

# One row per method, for the UI status strip and the export.
pq_methods_table <- function() {
  rows <- lapply(PQ_METHOD_IDS, function(id) {
    info <- PQ_METHODS[[id]]
    av <- pq_method_available(id)
    data.frame(
      method = id,
      label = info$short,
      kind = info$kind,
      available = isTRUE(av$ok),
      version = ifelse(is.na(av$version), "", av$version),
      license = info$provenance$license,
      status = if (isTRUE(av$ok)) "ready" else "unavailable",
      reason = if (is.na(av$reason)) "" else av$reason,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

# Methods the user can tick in the UI for a single-XIC run.
pq_selectable_methods <- function() {
  ids <- PQ_METHOD_IDS[vapply(PQ_METHOD_IDS, function(id)
    identical(PQ_METHODS[[id]]$kind, "single_xic"), logical(1))]
  stats::setNames(ids, vapply(ids, function(id) PQ_METHODS[[id]]$short, character(1)))
}

# Human-readable provenance for one method (used by the report / export).
pq_method_provenance_lines <- function(id) {
  p <- pq_method_info(id)$provenance
  c(
    paste0("Method                     : ", pq_method_info(id)$label),
    paste0("  paper                    : ", p$paper),
    paste0("  doi                      : ", p$doi),
    paste0("  code                     : ", p$code),
    paste0("  commit                   : ", p$commit),
    paste0("  license                  : ", p$license),
    paste0("  local modifications      : ", p$local_changes)
  )
}

# ============================================================
# Peak Quality - CPC adapter (Pirttila et al. 2022)
# ============================================================
# CPC is used as an EXTERNAL package (GPL >= 2). Its source is not copied
# into this repository: the adapter only calls the exported entry points
#   cpc::chromFromTrace(st, trace, param)
#   cpc::processChromatogram(chrom)
# and reads the resulting slots. No arithmetic of the published method is
# re-implemented here.
#
# What the adapter is allowed to do
#   1. normalise the input trace (same cleaning as the Kumler adapter),
#   2. build a cpcChromParam object from user-visible parameters,
#   3. call the package,
#   4. copy the returned values into a flat row and classify them.
# It must not "fix" a value or filter a peak on the user's behalf.
#
# Documented author-code defects (see PEAK_QUALITY_ALGORITHM_AUDIT.md)
#   * area is integrated over scan INDICES, not over RT (classes.R:1030
#     appends the interpolated tail bound to a misspelled variable
#     `intergral_x`, so peak_integral() falls back to x = 1:ny).
#     -> reported unchanged, labelled "intensity x scan count".
#   * sn draws its noise pool from the least-curved 95% of the trace, which
#     still contains most of a wide peak, so sn falls as the peak widens.
#     -> reported unchanged, and the package's min_sn filter is NEVER run.
# ============================================================

# ------------------------------------------------------------
# Locating / loading the package
# ------------------------------------------------------------
# cpc is a compiled package that depends on xcms, so it is not bundled and
# must not be installed into a shared environment without the user asking.
# An isolated library can be pointed at with
#   options(dmetfinder.cpc.lib = "path/to/lib")   or
#   Sys.setenv(DMETFINDER_CPC_LIB = "path/to/lib")
pq_cpc_extra_lib <- function() {
  p <- getOption("dmetfinder.cpc.lib", "")
  if (!nzchar(p)) p <- Sys.getenv("DMETFINDER_CPC_LIB", "")
  p <- as.character(p)[1]
  if (is.na(p) || !nzchar(p)) return(character(0))
  if (!dir.exists(p)) return(character(0))
  normalizePath(p, winslash = "/", mustWork = FALSE)
}

pq_cpc_lib_candidates <- function() {
  unique(c(pq_cpc_extra_lib(), .libPaths()))
}

# Checks for an installed copy WITHOUT loading it (loading cpc pulls in xcms
# and takes several seconds, which would happen on every UI repaint).
pq_cpc_available <- function() {
  for (lib in pq_cpc_lib_candidates()) {
    found <- tryCatch(find.package("cpc", lib.loc = lib, quiet = TRUE),
                      error = function(e) character(0))
    if (length(found) == 0) next
    ver <- tryCatch(as.character(utils::packageVersion("cpc", lib.loc = lib)),
                    error = function(e) NA_character_)
    return(list(ok = TRUE, version = ver, lib = lib, reason = NA_character_))
  }
  list(ok = FALSE, version = NA_character_, lib = NA_character_,
       reason = paste("the R package 'cpc' is not installed; install it into",
                      "an isolated library and point DMETFINDER_CPC_LIB at it",
                      "(xcms is a hard dependency of cpc)"))
}

# Actually load the namespace. Returns TRUE/FALSE with a reason; the first
# failure is cached so a broken installation is not retried 60000 times.
PQ_CPC_LOAD_STATE <- new.env(parent = emptyenv())

pq_cpc_load <- function() {
  if (exists("ok", envir = PQ_CPC_LOAD_STATE, inherits = FALSE)) {
    return(get("ok", envir = PQ_CPC_LOAD_STATE, inherits = FALSE))
  }
  av <- pq_cpc_available()
  if (!isTRUE(av$ok)) {
    assign("ok", list(ok = FALSE, reason = av$reason), envir = PQ_CPC_LOAD_STATE)
    return(get("ok", envir = PQ_CPC_LOAD_STATE, inherits = FALSE))
  }
  # make the isolated library visible for the dependency chain as well
  if (nzchar(av$lib) && !av$lib %in% .libPaths()) .libPaths(c(av$lib, .libPaths()))
  res <- tryCatch({
    suppressPackageStartupMessages(loadNamespace("cpc"))
    list(ok = TRUE, reason = NA_character_)
  }, error = function(e) {
    list(ok = FALSE, reason = paste0("cpc could not be loaded: ",
                                     conditionMessage(e)))
  })
  assign("ok", res, envir = PQ_CPC_LOAD_STATE)
  res
}

# ------------------------------------------------------------
# Parameters
# ------------------------------------------------------------
# min_sn / min_pts are the author's defaults and are kept in the parameter
# object for provenance; the filtering functions that use them
# (filterPeaks / characterize_xcms_peaklist) are never called, so no peak is
# ever removed because of them.
pq_cpc_defaults <- function() {
  list(
    smooth_method = "savgol",
    smooth_times = 2L,
    smooth_win = NA_integer_,   # NA = derive from the number of points
    min_pts = 7L,
    min_inf_width = 3,
    min_sn_author_default = 10, # recorded only, never applied
    min_w = 5L,
    max_w = 21L
  )
}

# Smoothing window used for a trace.
# The author derives it from the peak sigma recorded by XCMS (w ~ 2.354*s).
# We have no XCMS peak table, so sigma is measured from the trace itself:
# FWHM is located around the supplied apex and sigma = FWHM / 2.355, which
# makes w come out at roughly the FWHM in scan points. When the crossings
# cannot be found the window falls back to a third of the trace.
#
# The fallback is NOT harmless. Measured on eight real XICs from P173.raw
# (2026-10-21): four traces had sloping baselines so the half-height crossings
# could not be bracketed, the window went to n/3 (11-21 points), and CPC then
# reported not_detected for 6 of 8 traces. With an explicit 7-point window
# 7 of 8 were detected. The window is therefore recorded per run as
# smooth_win_source = "fwhm" | "one_third_fallback" | "user", so a run whose
# windows all came from the fallback is visible in the provenance instead of
# silently looking like "CPC found nothing".
pq_cpc_smooth_win_info <- function(y, apex, min_w = 5L, max_w = 21L) {
  n <- length(y)
  fwhm_pts <- NA_real_
  if (n >= 5 && !is.na(apex) && apex >= 1 && apex <= n) {
    base <- min(y)
    half <- base + (y[apex] - base) / 2
    left <- NA_integer_
    for (i in seq.int(apex, 1L)) {
      if (y[i] <= half) { left <- i; break }
    }
    right <- NA_integer_
    for (i in seq.int(apex, n)) {
      if (y[i] <= half) { right <- i; break }
    }
    if (!is.na(left) && !is.na(right) && right > left + 1) {
      # linear interpolation between the two points that straddle half height
      interp <- function(a, b) {
        if (y[b] == y[a]) return(as.numeric(b))
        a + (half - y[a]) / (y[b] - y[a])
      }
      lx <- if (left < apex) interp(left, left + 1L) else as.numeric(left)
      rx <- if (right > apex) interp(right - 1L, right) else as.numeric(right)
      fwhm_pts <- rx - lx
    }
  }

  from_fwhm <- is.finite(fwhm_pts) && fwhm_pts > 0
  w <- if (from_fwhm) {
    as.integer(round(2.354 * (fwhm_pts / 2.355)))
  } else {
    as.integer(round(n / 3))
  }
  if (w %% 2L == 0L) w <- w + 1L
  w <- max(as.integer(min_w), min(as.integer(max_w), w))
  if (w > n) w <- if (n %% 2L == 1L) as.integer(n) else as.integer(n - 1L)
  list(win = as.integer(w),
       source = if (from_fwhm) "fwhm" else "one_third_fallback",
       fwhm_points = fwhm_pts)
}

pq_cpc_auto_smooth_win <- function(y, apex, min_w = 5L, max_w = 21L) {
  pq_cpc_smooth_win_info(y, apex, min_w, max_w)$win
}

# Everything that ends up in the traceability record.
pq_cpc_settings <- function(n, params = list(), y = NULL, apex = NULL) {
  d <- pq_cpc_defaults()
  pick <- function(name) {
    v <- params[[name]]
    if (is.null(v) || (length(v) == 1 && is.na(v))) d[[name]] else v
  }
  smooth_win <- pick("smooth_win")
  if (is.null(smooth_win) || is.na(smooth_win) || !is.numeric(smooth_win)) {
    info <- pq_cpc_smooth_win_info(y, apex, pick("min_w"), pick("max_w"))
    smooth_win <- info$win
    smooth_win_source <- info$source
  } else {
    smooth_win_source <- "user"
  }
  smooth_win <- as.integer(smooth_win)
  # sgolayfilt needs win <= n; clamp instead of failing the whole row
  if (smooth_win > n) {
    smooth_win <- if (n %% 2L == 1L) as.integer(n) else as.integer(n - 1L)
    smooth_win_source <- paste0(smooth_win_source, "+clamped_to_trace")
  }
  list(
    smooth_method = as.character(pick("smooth_method")),
    smooth_times = as.integer(pick("smooth_times")),
    smooth_win = smooth_win,
    smooth_win_source = smooth_win_source,
    min_pts = as.integer(pick("min_pts")),
    min_inf_width = as.numeric(pick("min_inf_width")),
    min_sn_author_default = as.numeric(pick("min_sn_author_default")),
    # min_w / max_w must be passed explicitly: an S4 slot assigned NULL
    # silently empties it, and processChromatogram() then evaluates
    # `smooth_win < NULL`, which is logical(0) and raises
    # "argument is of length zero".
    min_w = as.integer(pick("min_w")),
    max_w = as.integer(pick("max_w")),
    # `s` is only used by CPC to set a plot range (p +- 20*s) and to derive a
    # default smoothing window. It is set so the plot range covers the whole
    # trace; it never enters the metric arithmetic.
    sigma_for_plotrange = max(3, n / 10),
    filters_applied = FALSE
  )
}

# ------------------------------------------------------------
# Boundary codes
# ------------------------------------------------------------
# The C++ code returns 0..3, classes.R maps them to "B", "V", "S", "R".
#   0 B = returned to baseline
#   1 V = bounded at a valley (another peak continues)
#   2 S = bounded at a shoulder
#   3 R = bounded at a rounded peak
PQ_CPC_CODE_LABELS <- c(
  B = "returned to baseline",
  V = "bounded at a valley (co-eluting neighbour)",
  S = "bounded at a shoulder",
  R = "bounded at a rounded peak"
)

# Map the two author codes onto the module-wide boundary vocabulary so the
# two methods can be compared without inventing a third vocabulary.
pq_cpc_boundary_status <- function(front, tail) {
  codes <- c(front, tail)
  codes <- codes[!is.na(codes)]
  if (length(codes) == 0) return("ok")
  if (any(codes == "V")) return("ambiguous")
  if (any(codes %in% c("S", "R"))) return("boundary_unclear")
  "ok"
}

# ------------------------------------------------------------
# Run CPC on one trace
# ------------------------------------------------------------
# xic        : data.frame with rt + intensity (the WHOLE RT search window,
#              not the Kumler peak slice: CPC must be free to find its own
#              boundaries, otherwise "boundary differences between methods"
#              would be an artefact of the input)
# apex_index : row of `xic` that the caller believes is the apex (the apex of
#              the selected candidate peak); CPC returns the peak nearest it
pq_cpc_run <- function(xic, apex_index, params = list()) {
  ld <- pq_cpc_load()
  if (!isTRUE(ld$ok)) {
    # "not_installed" is its own state. It is NOT a bad peak and must never be
    # reported as one: the sample was never characterised at all.
    return(list(ok = FALSE, status = "not_installed", reason = ld$reason,
                values = NULL, settings = NULL, elapsed_ms = NA_real_))
  }
  if (is.null(xic) || nrow(xic) < 3) {
    return(list(ok = FALSE, status = "too_few_points",
                reason = "fewer than 3 scans in the RT window",
                values = NULL, settings = NULL, elapsed_ms = NA_real_))
  }

  prep <- pq_prepare_scoring_input(xic$rt, xic$intensity)
  n <- length(prep$rt)
  if (n < 7) {
    return(list(ok = FALSE, status = "too_few_points",
                reason = sprintf("CPC needs at least 7 points, got %d", n),
                values = NULL, settings = NULL, elapsed_ms = NA_real_))
  }

  apex_index <- suppressWarnings(as.integer(apex_index)[1])
  if (length(apex_index) == 0 || is.na(apex_index) ||
      apex_index < 1 || apex_index > n) {
    apex_index <- which.max(prep$intensity)
  }

  settings <- pq_cpc_settings(n, params, y = prep$intensity, apex = apex_index)
  if (settings$smooth_win < 5) {
    return(list(ok = FALSE, status = "too_few_points",
                reason = "trace too short for the smallest CPC smoothing window (5 points)",
                values = NULL, settings = settings, elapsed_ms = NA_real_))
  }

  prm <- cpc::cpcChromParam(
    p = apex_index,
    s = settings$sigma_for_plotrange,
    min_pts = settings$min_pts,
    min_inf_width = settings$min_inf_width,
    min_sn = settings$min_sn_author_default,
    min_w = settings$min_w,
    max_w = settings$max_w,
    smooth_method = settings$smooth_method,
    smooth_times = settings$smooth_times,
    smooth_win = settings$smooth_win,
    verbose_output = FALSE,
    save_all = FALSE,
    plot = FALSE
  )

  t0 <- Sys.time()
  ch <- tryCatch(
    suppressWarnings(cpc::processChromatogram(
      cpc::chromFromTrace(st = prep$rt, trace = prep$intensity, param = prm))),
    error = function(e) structure(list(message = conditionMessage(e)),
                                  class = "pq_cpc_error")
  )
  elapsed_ms <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000

  if (inherits(ch, "pq_cpc_error")) {
    return(list(ok = FALSE, status = "failed",
                reason = paste0("cpc error: ", ch$message),
                values = NULL, settings = settings, elapsed_ms = elapsed_ms))
  }

  res <- tryCatch(ch@results, error = function(e) NULL)
  if (is.null(res) || !is.list(res)) {
    return(list(ok = FALSE, status = "failed",
                reason = "cpc returned no results slot",
                values = NULL, settings = settings, elapsed_ms = elapsed_ms))
  }

  note <- if (is.null(res$note)) NA_character_ else as.character(res$note)[1]
  if (!identical(note, "detected")) {
    return(list(ok = FALSE, status = "not_detected",
                reason = paste0("CPC did not detect a peak at the supplied apex (note = ",
                                ifelse(is.na(note), "NA", note), ")"),
                values = NULL, settings = settings, elapsed_ms = elapsed_ms))
  }

  num <- function(name) {
    v <- res[[name]]
    if (is.null(v) || length(v) == 0) return(NA_real_)
    v <- suppressWarnings(as.numeric(v)[1])
    if (is.na(v) || v == -1) NA_real_ else v
  }
  code <- function(name) {
    v <- res[[name]]
    if (is.null(v) || length(v) == 0) return(NA_character_)
    v <- as.character(v)[1]
    if (is.na(v) || !v %in% names(PQ_CPC_CODE_LABELS)) NA_character_ else v
  }

  values <- list(
    rt = num("rt"), rtmin = num("rtmin"), rtmax = num("rtmax"),
    fwhm = num("fwhm"), wb = num("wb"),
    a = num("a"), b = num("b"), tf = num("tf"),
    height = num("height"), area = num("area"), sn = num("sn"),
    front_code = code("fcode"), tail_code = code("tcode"),
    apex_index = num("apex"), front_index = num("fpkb"), tail_index = num("tpkb")
  )

  if (is.na(values$rt) || is.na(values$rtmin) || is.na(values$rtmax)) {
    return(list(ok = FALSE, status = "not_detected",
                reason = "cpc reported a peak but the apex/boundaries are missing",
                values = values, settings = settings, elapsed_ms = elapsed_ms))
  }

  list(ok = TRUE, status = "ok", reason = NA_character_, values = values,
       settings = settings, elapsed_ms = elapsed_ms, note = note)
}

# ------------------------------------------------------------
# One flat row per input row
# ------------------------------------------------------------
PQ_CPC_COLUMNS <- c(
  "cpc_status", "cpc_reason", "cpc_rt", "cpc_rtmin", "cpc_rtmax",
  "cpc_fwhm", "cpc_wb", "cpc_a", "cpc_b", "cpc_tf",
  "cpc_height", "cpc_area", "cpc_sn",
  "cpc_front_code", "cpc_tail_code",
  "cpc_n_points", "cpc_boundary_status",
  "cpc_smooth_win", "cpc_elapsed_ms"
)

pq_cpc_empty_row <- function() {
  num <- c("cpc_rt", "cpc_rtmin", "cpc_rtmax", "cpc_fwhm", "cpc_wb",
           "cpc_a", "cpc_b", "cpc_tf", "cpc_height", "cpc_area", "cpc_sn",
           "cpc_elapsed_ms")
  row <- as.data.frame(
    stats::setNames(lapply(PQ_CPC_COLUMNS, function(x) NA_real_),
                    PQ_CPC_COLUMNS),
    stringsAsFactors = FALSE)
  for (cc in setdiff(PQ_CPC_COLUMNS, num)) row[[cc]] <- NA_character_
  for (cc in c("cpc_n_points", "cpc_smooth_win")) row[[cc]] <- NA_integer_
  row
}

pq_cpc_score <- function(xic, apex_index, params = list()) {
  row <- pq_cpc_empty_row()
  run <- pq_cpc_run(xic, apex_index, params)
  row$cpc_status <- run$status
  row$cpc_reason <- run$reason
  row$cpc_elapsed_ms <- run$elapsed_ms
  if (!is.null(run$settings)) row$cpc_smooth_win <- run$settings$smooth_win
  # Recorded before the early return on purpose: a rejected trace is exactly
  # the case where an over-wide window matters most, so the source has to be
  # counted for failures too.
  if (!is.null(run$settings) && !is.null(run$settings$smooth_win_source)) {
    attr(row, "cpc_smooth_win_source") <- run$settings$smooth_win_source
  }
  if (!isTRUE(run$ok)) return(row)

  v <- run$values
  row$cpc_rt <- v$rt
  row$cpc_rtmin <- v$rtmin
  row$cpc_rtmax <- v$rtmax
  row$cpc_fwhm <- v$fwhm
  row$cpc_wb <- v$wb
  row$cpc_a <- v$a
  row$cpc_b <- v$b
  row$cpc_tf <- v$tf
  row$cpc_height <- v$height
  row$cpc_area <- v$area
  row$cpc_sn <- v$sn
  row$cpc_front_code <- v$front_code
  row$cpc_tail_code <- v$tail_code
  if (!is.na(v$front_index) && !is.na(v$tail_index)) {
    row$cpc_n_points <- as.integer(v$tail_index - v$front_index + 1L)
  }
  row$cpc_boundary_status <- pq_cpc_boundary_status(v$front_code, v$tail_code)
  row
}

# The adapter reports fine-grained statuses because they are actionable
# (a trace with 4 points is a different problem from a package that is not
# installed). This maps them onto the four words the module publishes, so a
# consumer that only wants "can I use this value?" does not have to know the
# details.
pq_cpc_status_family <- function(status) {
  s <- as.character(status)
  out <- rep(NA_character_, length(s))
  out[s %in% "ok"] <- "ok"
  out[s %in% c("not_installed", "unavailable")] <- "not_installed"
  out[s %in% c("too_few_points", "invalid_input")] <- "invalid_input"
  out[s %in% c("failed", "error")] <- "error"
  out[s %in% c("not_detected")] <- "not_detected"
  out[s %in% c("absent")] <- "absent"
  out[s %in% c("not_run", "skipped")] <- "not_run"
  out
}

# The CPC run settings of one job, for the parameter sheet.
pq_cpc_param_table <- function(settings) {
  data.frame(
    parameter = paste0("cpc.", names(settings)),
    value = vapply(settings, function(v) paste(as.character(v), collapse = ","),
                   character(1)),
    stringsAsFactors = FALSE
  )
}

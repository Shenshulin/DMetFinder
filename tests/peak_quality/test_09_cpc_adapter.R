# ============================================================
# Stage-2 tests: method registry + CPC adapter
# ============================================================
# The CPC section runs the real package when it is reachable (set
# DMETFINDER_CPC_LIB to an isolated library) and skips cleanly otherwise.
# Nothing here asserts that CPC is "correct" - it asserts that we reproduce
# the author values, including the two documented defects.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))
root <- pq_source_project()
# The suite runs with --vanilla, which does NOT read .Renviron, so the pointer
# to the isolated library is picked up by hand. Keeping it in .Renviron means
# the install location is written down exactly once.
if (!nzchar(Sys.getenv("DMETFINDER_CPC_LIB"))) {
  renv <- file.path(root, ".Renviron")
  if (file.exists(renv)) readRenviron(renv)
}
# last resort: the scratch library the audit left behind
if (!nzchar(Sys.getenv("DMETFINDER_CPC_LIB"))) {
  ref <- file.path(root, ".workbuddy/reference/rlib")
  if (dir.exists(ref)) Sys.setenv(DMETFINDER_CPC_LIB = ref)
}

# ------------------------------------------------------------
pq_section("method registry")
# ------------------------------------------------------------
tab <- pq_methods_table()
pq_assert_equal(nrow(tab), 3L, "registry lists exactly three methods")
pq_assert_equal(sort(tab$method), c("cpc", "dnn", "kumler"),
                "registry ids are kumler / cpc / dnn")
pq_assert(isTRUE(tab$available[tab$method == "kumler"]),
          "kumler is always available (vendored, no dependency)")

# The DNN is no longer hard-coded as unavailable. Its availability follows a
# *verified* model - weights whose SHA-256 matches the training log - because
# the authors publish no weights and ours are trained locally. Availability must
# therefore track the file, not a constant, and its absence must say
# model_not_available rather than quietly leaving NAs.
dnn_row <- tab[tab$method == "dnn", , drop = FALSE]
dnn_model <- pq_dnn_find_model(pq_dnn_paths(pq_proj_root()))
pq_assert(identical(isTRUE(dnn_row$available), isTRUE(dnn_model$available)),
          "dnn availability follows the verified model, not a hard-coded value")
pq_assert(identical(pq_method_info("dnn")$probability, FALSE),
          "the dnn output is declared a score, not a probability")
if (!isTRUE(dnn_model$available)) {
  pq_assert_contains(dnn_row$reason, "model_not_available",
                     "without weights the reason says model_not_available")
} else {
  pq_assert_contains(dnn_row$version, substr(dnn_model$sha256, 1, 12),
                     "an available model is identified by its weight hash")
}

info <- pq_method_info("kumler")
pq_assert_equal(info$kind, "single_xic", "kumler works on a single XIC")
pq_assert_equal(pq_method_info("dnn")$kind, "peak_group",
                "dnn works on cross-sample peak groups")
pq_assert_contains(pq_method_info("cpc")$provenance$license, "GPL",
                   "CPC licence is recorded as GPL")
pq_assert_contains(pq_method_info("kumler")$provenance$license, "MIT",
                   "Kumler licence is recorded as MIT")

sel <- pq_selectable_methods()
pq_assert("kumler" %in% sel, "kumler is selectable for a single-XIC run")
pq_assert(!"dnn" %in% unname(sel), "dnn is not offered as a single-XIC method")

err <- tryCatch(pq_method_info("nope"), error = function(e) conditionMessage(e))
pq_assert(grepl("unknown method", err), "unknown method id is rejected")

d <- pq_metric_def("cpc", "area")
pq_assert_contains(d$unit, "scan count",
                   "cpc area unit is documented as intensity x scan count")
pq_assert_contains(d$note, "INDICES",
                   "cpc area note points at the index-integration defect")
pq_assert_contains(pq_metric_def("kumler", "peak_cor")$note, "NOT a probability",
                   "peak_cor is explicitly not a probability")

# ------------------------------------------------------------
pq_section("CPC parameter handling (no package needed)")
# ------------------------------------------------------------
y <- pq_synth_xic(4.5, amp = 2e5, sigma = 0.06, noise = 1500, n = 121)$intensity
apex <- which.max(y)
w <- pq_cpc_auto_smooth_win(y, apex)
pq_assert(w %% 2L == 1L, "auto smoothing window is odd")
pq_assert(w >= 5L && w <= 21L, "auto smoothing window stays inside the author bounds")

yn <- pq_synth_xic(4.5, amp = 2e5, sigma = 0.005, noise = 1500, n = 121)$intensity
pq_assert(pq_cpc_auto_smooth_win(yn, which.max(yn)) <= w,
          "a narrower peak gets a smaller smoothing window")

yw <- pq_synth_xic(4.5, amp = 2e5, sigma = 0.20, noise = 1500, n = 121)$intensity
pq_assert(pq_cpc_auto_smooth_win(yw, which.max(yw)) >= w,
          "a wider peak gets a larger smoothing window")

st <- pq_cpc_settings(121, list(), y = y, apex = apex)
pq_assert(!isTRUE(st$filters_applied), "CPC filters are recorded as not applied")
pq_assert(pq_cpc_settings(121, list(min_w = 7L), y = y, apex = apex)$min_w == 7L,
          "min_w can be overridden through the parameter list")
pq_assert(pq_cpc_settings(6, list(), y = y[1:6], apex = 3)$smooth_win <= 5,
          "very short traces clamp the smoothing window")

# not passing min_w / max_w leaves the S4 slots NULL and makes
# processChromatogram() fail with 'argument is of length zero' - the settings
# must therefore always carry them
pq_assert(!is.null(st$min_w) && !is.null(st$max_w),
          "settings always carry min_w and max_w (S4 slots must not be NULL)")

# The window is the single most consequential CPC setting on real data: an
# over-wide window flattens a narrow peak and processChromatogram() then
# answers not_detected. Whether the window came from the peak width or from
# the coarse n/3 fallback must therefore be recorded, not inferred.
pq_assert_equal(st$smooth_win_source, "fwhm",
                "a window measured from the peak width is recorded as fwhm")
rising <- seq_len(121) * 10                # monotone trace: no half height crossings
st_fb <- pq_cpc_settings(121, list(), y = rising, apex = 60L)
pq_assert_equal(st_fb$smooth_win_source, "one_third_fallback",
                "the n/3 fallback is recorded as one_third_fallback")
pq_assert_equal(st_fb$smooth_win, 21L,
                paste("the fallback window is one third of the trace clamped to",
                      "the author's max_w (21)"))
pq_assert_equal(pq_cpc_settings(121, list(smooth_win = 9L), y = y, apex = apex)$smooth_win_source,
                "user",
                "an explicitly supplied window is recorded as user")

# ------------------------------------------------------------
pq_section("boundary code mapping")
# ------------------------------------------------------------
pq_assert_equal(pq_cpc_boundary_status("B", "B"), "ok",
                "baseline on both sides maps to ok")
pq_assert_equal(pq_cpc_boundary_status("V", "B"), "ambiguous",
                "a valley on one side maps to ambiguous")
pq_assert_equal(pq_cpc_boundary_status("S", "B"), "boundary_unclear",
                "a shoulder maps to boundary_unclear")
pq_assert_equal(pq_cpc_boundary_status("R", "R"), "boundary_unclear",
                "a rounded boundary maps to boundary_unclear")
pq_assert_equal(pq_cpc_boundary_status(NA_character_, NA_character_), "ok",
                "missing codes do not create a failure")

# ------------------------------------------------------------
pq_section("CPC executed from the installed package")
# ------------------------------------------------------------
av <- pq_cpc_available()
cat(sprintf("  cpc available: %s (version %s)\n", av$ok, av$version))

if (!isTRUE(av$ok)) {
  pq_skip(paste("cpc is not installed in this R library:", av$reason))
} else {
  xic <- pq_synth_xic(4.5, amp = 2e5, sigma = 0.06, noise = 1500, n = 121, seed = 42)
  row <- pq_cpc_score(xic, which.max(xic$intensity))
  pq_assert_equal(row$cpc_status, "ok", "CPC returns a peak for a clean gaussian")
  pq_assert(abs(row$cpc_rt - 4.5) < 0.02,
            sprintf("CPC apex RT is within 0.02 min of the truth (%.4f)", row$cpc_rt))
  fwhm_true <- 2.355 * 0.06
  pq_assert(abs(row$cpc_fwhm - fwhm_true) / fwhm_true < 0.10,
            sprintf("CPC FWHM within 10%% of 2.355*sigma (%.4f vs %.4f)",
                    row$cpc_fwhm, fwhm_true))
  pq_assert(abs(row$cpc_height - 2e5) / 2e5 < 0.10,
            sprintf("CPC height within 10%% of the truth (%.0f)", row$cpc_height))
  pq_assert(abs(row$cpc_tf - 1) < 0.05,
            sprintf("CPC tailing factor ~1 for a symmetric peak (%.4f)", row$cpc_tf))
  pq_assert_equal(row$cpc_front_code, "B", "CPC front boundary returns to baseline")
  pq_assert_equal(row$cpc_tail_code, "B", "CPC tail boundary returns to baseline")
  pq_assert(row$cpc_rtmin < row$cpc_rt && row$cpc_rt < row$cpc_rtmax,
            "CPC boundaries bracket the CPC apex")
  pq_assert(row$cpc_n_points >= 7, "CPC peak spans at least min_pts scans")

  # ---- documented defect 1: area is integrated over scan indices -------
  idx <- which(xic$rt >= row$cpc_rtmin & xic$rt <= row$cpc_rtmax)
  area_rt <- sum(diff(xic$rt[idx]) *
                   (head(xic$intensity[idx], -1) + tail(xic$intensity[idx], -1)) / 2)
  pq_assert(row$cpc_area / area_rt > 20,
            sprintf(paste("CPC area is NOT an RT integral (ratio to the RT",
                          "trapezoid = %.1f, i.e. index units)"),
                    row$cpc_area / area_rt))

  # doubling the sampling density: the RT integral is invariant, the CPC
  # area is not - that is the fingerprint of integrating over indices.
  # Low-noise traces are used so the comparison measures the integration
  # rule and not the noise realisation.
  xa <- pq_synth_xic(4.5, amp = 2e5, sigma = 0.06, noise = 100, n = 121, seed = 42)
  xb <- pq_synth_xic(4.5, amp = 2e5, sigma = 0.06, noise = 100, n = 241, seed = 42)
  r1 <- pq_cpc_score(xa, which.max(xa$intensity), list(smooth_win = 11L))
  r2 <- pq_cpc_score(xb, which.max(xb$intensity), list(smooth_win = 11L))
  rt_ratio <- {
    i1 <- which(xa$rt >= r1$cpc_rtmin & xa$rt <= r1$cpc_rtmax)
    i2 <- which(xb$rt >= r2$cpc_rtmin & xb$rt <= r2$cpc_rtmax)
    a1 <- sum(diff(xa$rt[i1]) *
                (head(xa$intensity[i1], -1) + tail(xa$intensity[i1], -1)) / 2)
    a2 <- sum(diff(xb$rt[i2]) *
                (head(xb$intensity[i2], -1) + tail(xb$intensity[i2], -1)) / 2)
    a2 / a1
  }
  pq_assert(abs(rt_ratio - 1) < 0.10,
            sprintf("the RT trapezoid is sampling-invariant (ratio %.3f)", rt_ratio))
  area_ratio <- r2$cpc_area / r1$cpc_area
  pq_assert(area_ratio > 1.5,
            sprintf(paste("CPC area grows with the scan count (ratio %.3f) -",
                          "the audit's index-integration defect is reproduced"),
                    area_ratio))

  # ---- documented defect 2: sn, and it is never used as a filter -------
  weak <- pq_synth_xic(4.5, amp = 1500, sigma = 0.05, noise = 300, n = 121, seed = 7)
  rw <- pq_cpc_score(weak, which.max(weak$intensity))
  pq_assert_equal(rw$cpc_status, "ok",
                  "a low-S/N peak is still reported (min_sn is NOT applied)")
  pq_assert(is.finite(rw$cpc_sn) && rw$cpc_sn < 10,
            sprintf("its CPC sn (%.2f) is below the author default min_sn = 10 and still returned",
                    rw$cpc_sn))

  # ---- guards ----------------------------------------------------------
  r3 <- pq_cpc_score(xic[1:5, ], 3)
  pq_assert_equal(r3$cpc_status, "too_few_points",
                  "fewer than 7 points is reported, not silently scored")
  pq_assert(is.na(r3$cpc_rt), "a skipped row carries no metric values")

  flat <- data.frame(rt = seq(1, 2, length.out = 40), intensity = rep(1000, 40))
  r4 <- pq_cpc_score(flat, 20)
  pq_assert(r4$cpc_status %in% c("not_detected", "failed", "ok"),
            "a flat trace never crashes the adapter")

  # ---- the whole table path -------------------------------------------
  run <- pq_make_synthetic_run(n_samples = 3L, features = c("F1", "F2"))
  tbl <- pq_run_cpc(run$detail, run$rows, run$params)
  pq_assert_equal(nrow(tbl$table), nrow(run$rows),
                  "CPC table is row-aligned with the result table")
  pq_assert(all(c("cpc_status", "cpc_rt", "cpc_area") %in% names(tbl$table)),
            "CPC table carries the documented columns")
  present <- run$rows$presence %in% "present"
  pq_assert(all(tbl$table$cpc_status[present] %in% "ok"),
            "every present peak is scored by CPC")
  pq_assert(all(tbl$table$cpc_status[!present] %in% "absent"),
            "absent samples are reported absent, not scored")
  pq_assert(!is.null(tbl$settings), "the CPC run records the settings it used")

  limited <- pq_run_cpc(run$detail, run$rows, run$params, max_rows = 2L)
  pq_assert_equal(sum(limited$table$cpc_status %in% "not_run", na.rm = TRUE),
                  nrow(run$rows) - 2L,
                  "CPC row limit marks the remaining rows not_run (never drops them)")

  # ---- the run summary must not call a valid answer a failure ---------
  # On real data CPC answers not_detected for a large share of traces while
  # nothing is broken; lumping that into "failed" made a healthy run look like
  # "ok=127, failed=32" next to a summary saying "not detected=32, failed=0".
  logged <- character(0)
  invisible(pq_run_cpc(run$detail, run$rows, run$params,
                       log_fun = function(...) logged <<- c(logged, paste0(...))))
  summary_line <- grep("^CPC finished", logged, value = TRUE)
  pq_assert_equal(length(summary_line), 1L,
                  "the CPC run logs exactly one summary line")
  pq_assert(!grepl("failed=", summary_line),
            "not_detected is not reported as 'failed' (it is a valid answer)")
  pq_assert(grepl("not_detected=", summary_line),
            "the summary names not_detected explicitly")
  pq_assert(grepl("invalid_or_error=", summary_line),
            "real breakage is counted separately from not_detected")
}

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

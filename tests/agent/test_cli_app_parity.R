#!/usr/bin/env Rscript
# ============================================================
# tests/agent/test_cli_app_parity.R
# ------------------------------------------------------------
# Answers one question: are the agent CLI and the Shiny app the SAME analysis?
#
# They must be, because both call dmetfinder_run() in R/dmetfinder_functions.R.
# Sharing a function is easy to claim and easy to break in three ways, so each
# one is checked mechanically here:
#
#   A. same defaults       -- the config the web panel assembles, once merged,
#                             must be identical to default_config
#   B. full parameter face -- every result-changing key in default_config must
#                             be reachable from the web panel (or be mirrored
#                             from a key that is)
#   C. same numbers        -- the same input through both entry points must give
#                             the same 19 sheets
#
# The web side is not simulated: the `parse_num` helper and the `config <- list()`
# block are lifted out of server/dmetfinder_server.R by parsing it, and
# dmf_numlist() is lifted out of ui/dmetfinder_ui.R the same way. If the panel
# gains a widget that the server never forwards, B fails; if the server forwards
# a value the panel cannot produce, A fails.
#
# Usage: Rscript tests/agent/test_cli_app_parity.R [project_root]
# ============================================================

args <- commandArgs(trailingOnly = TRUE)
root <- if (length(args) >= 1L) args[[1L]] else "."
root <- normalizePath(root, winslash = "/", mustWork = TRUE)

fail <- 0L
say <- function(...) cat(sprintf(...), "\n", sep = "")
ok <- function(cond, label, detail = "") {
  if (isTRUE(cond)) {
    say("[ OK ] %s", label)
  } else {
    say("[FAIL] %s%s", label, if (nzchar(detail)) paste0("  <- ", detail) else "")
    fail <<- fail + 1L
  }
  invisible(isTRUE(cond))
}

# ---- load the shared core, exactly the way cli/lib/core_load.R does --------
# Read with an explicit encoding: Rscript started from Git Bash lands in the C
# locale, where parse() on a UTF-8 file with non-ASCII comments fails with
# "invalid input found on input connection". Same code either way.
load_utf8 <- function(path, envir) {
  txt <- readLines(path, encoding = "UTF-8", warn = FALSE)
  eval(parse(text = txt, encoding = "UTF-8"), envir = envir)
}
core <- new.env(parent = globalenv())
for (rel in c("R/config.R", "R/dmetfinder_functions.R")) {
  load_utf8(file.path(root, rel), core)
}
default_config <- core$default_config

# ---- lift definitions out of the UI / server without running them ---------
find_assign <- function(file, name) {
  txt <- readLines(file.path(root, file), encoding = "UTF-8", warn = FALSE)
  pd <- parse(text = txt, encoding = "UTF-8")
  hits <- list()
  walk <- function(x) {
    if (is.expression(x) || (is.list(x) && !is.call(x))) {
      for (i in seq_along(x)) walk(x[[i]])
      return(invisible(NULL))
    }
    if (!is.call(x)) return(invisible(NULL))
    if (identical(x[[1L]], as.name("<-")) || identical(x[[1L]], as.name("="))) {
      if (is.name(x[[2L]]) && identical(as.character(x[[2L]]), name)) {
        hits[[length(hits) + 1L]] <<- x[[3L]]
      }
    }
    for (i in seq_along(x)) if (!is.null(x[[i]])) try(walk(x[[i]]), silent = TRUE)
    invisible(NULL)
  }
  walk(pd)
  if (length(hits) == 0L) stop(sprintf("%s: no assignment to `%s` found", file, name))
  hits[[1L]]
}

ui_env <- new.env(parent = globalenv())
dmf_numlist <- eval(find_assign("ui/dmetfinder_ui.R", "dmf_numlist"), envir = ui_env)

srv_env <- new.env(parent = globalenv())
parse_num <- eval(find_assign("server/dmetfinder_server.R", "parse_num"), envir = srv_env)
cfg_expr <- find_assign("server/dmetfinder_server.R", "config")

# ---- the panel's own defaults: value = default_config$X, or dmf_numlist() --
panel <- list(
  ErrorRangeUnit        = default_config$ErrorRangeUnit,
  ErrorRange            = default_config$ErrorRange,
  ErrorRangeInGroups    = default_config$ErrorRangeInGroups,
  FloatCount            = default_config$FloatCount,
  mergeRows             = default_config$mergeRows,
  MatrixPick            = default_config$MatrixPick,
  ClusterRtTol          = default_config$ClusterRtTol,
  m1                    = default_config$m1,
  m2                    = default_config$m2,
  m3                    = default_config$m3,
  p50IonPercent         = default_config$p50IonPercent,
  p80IonPercent         = default_config$p80IonPercent,
  intensityRange        = dmf_numlist(default_config$intensityRange),
  intensityValue        = dmf_numlist(default_config$intensityValue),
  countRange            = dmf_numlist(default_config$countRange),
  countValue            = dmf_numlist(default_config$countValue),
  relIntensityRange1    = dmf_numlist(default_config$relativeIntensityRange1),
  relIntensityValue1    = dmf_numlist(default_config$relativeIntensityValue1),
  relIntensitySplit     = default_config$relativeIntensitySplit,
  relIntensityRange2    = dmf_numlist(default_config$relativeIntensityRange2),
  relIntensityValue2    = dmf_numlist(default_config$relativeIntensityValue2),
  FoldChangeThreshold   = default_config$FoldChangeThreshold,
  PValueThreshold       = default_config$PValueThreshold
)

env2 <- new.env(parent = globalenv())
env2$input <- panel
env2$parse_num <- parse_num
web_cfg <- eval(cfg_expr, envir = env2)

say("== A. same defaults ==")
merged <- core$dmf_merge_config(web_cfg)

same <- function(a, b) isTRUE(all.equal(a, b, check.attributes = FALSE))
for (nm in names(default_config)) {
  if (!nm %in% names(merged)) {
    say("[FAIL] %-26s missing after merge", nm)
    fail <- fail + 1L
  } else if (!same(merged[[nm]], default_config[[nm]])) {
    say("[FAIL] %-26s web=%s default=%s", nm,
        paste(format(merged[[nm]]), collapse = ","),
        paste(format(default_config[[nm]]), collapse = ","))
    fail <- fail + 1L
  }
}
ok(fail == 0L, "the web panel's defaults merge back to default_config")

# ---- B. can the panel reach every result-changing key? --------------------
say("")
say("== B. parameter coverage ==")

# Mirrored inside dmf_merge_config(): setting the left key also sets the right.
mirrored <- c("p50IntensityRange", "p50IntensityValue", "p50CountRange",
              "p50CountValue", "p50RelativeIntensitySplit",
              "p50RelativeIntensityRange1", "p50RelativeIntensityValue1",
              "p50RelativeIntensityRange2", "p50RelativeIntensityValue2")
# Deliberately not on the panel: it only changes how empty cells are written
# out, never which ions are found or how they score.
fixed <- c("NullCellValue")

passed <- names(web_cfg)
missing <- setdiff(names(default_config), c(passed, mirrored, fixed))
fwd <- vapply(names(web_cfg), function(k) {
  v <- web_cfg[[k]]
  if (is.null(v)) "not forwarded" else paste(format(v), collapse = ",")
}, character(1L))
say("panel forwards %d keys: %s", length(passed), paste(passed, collapse = ", "))
say("mirrored from the all-ion table: %d keys", length(mirrored))
say("fixed at default on purpose: %s", paste(fixed, collapse = ", "))
ok(length(missing) == 0L, "every result-changing key is reachable from the web panel",
   paste(missing, collapse = ", "))

# ---- C. the exposed switches reach the matrix builder ---------------------
say("")
say("== C. MatrixPick / ClusterRtTol are wired ==")
# Counting ions is not enough to prove the switch is wired: the demo data has no
# duplicated centroid inside a window, so both settings legitimately give the
# same matrix there. Record what actually arrives at dmf_create_matrix() instead.
demo_a <- file.path(root, "demo_data", "groupA.xlsx")
base_cfg <- core$dmf_merge_config(NULL)

seen <- new.env()
orig_create <- core$dmf_create_matrix
core$dmf_create_matrix <- function(ions, n_samples, error_range, digits = 7L,
                                   pick = c("first", "max"), rt_tol = 0, unit = "Da") {
  seen$pick <- as.character(pick)
  seen$rt_tol <- rt_tol
  seen$unit <- unit
  orig_create(ions, n_samples, error_range, digits, pick, rt_tol, unit)
}

probe <- function(cfg) {
  core$dmf_process_group(demo_a, "Group A", core$dmf_merge_config(cfg),
                         verbose = FALSE, progress = NULL)
  list(pick = seen$pick, rt_tol = seen$rt_tol)
}

p_default <- probe(c(list(MatrixPick = "max", ClusterRtTol = 0.3)))
p_first <- probe(c(list(MatrixPick = "first", ClusterRtTol = 0)))
say("sent max / 0.30  ->  matrix built with %s / %.2f", p_default$pick, p_default$rt_tol)
say("sent first / 0    ->  matrix built with %s / %.2f", p_first$pick, p_first$rt_tol)
ok(identical(p_default$pick, "max") && isTRUE(all.equal(p_default$rt_tol, 0.3)),
   "the panel's MatrixPick and ClusterRtTol arrive unchanged")
ok(identical(p_first$pick, "first") && isTRUE(all.equal(p_first$rt_tol, 0)),
   "the original-Java pair (first / 0) is reachable and does not snap back")

# bad values must not slide through
bad_pick <- tryCatch({ core$dmf_merge_config(list(MatrixPick = "maximum")); FALSE },
                     error = function(e) TRUE)
ok(bad_pick, "an invalid MatrixPick is rejected instead of silently defaulting")
bad_unit <- tryCatch({ core$dmf_merge_config(list(ErrorRangeUnit = "ppm ")); FALSE },
                     error = function(e) TRUE)
ok(bad_unit, "an invalid ErrorRangeUnit is rejected instead of silently defaulting")

# ---- D. same input + same config -> same 19 sheets ------------------------
say("")
say("== D. same numbers through both entry points ==")
run <- function(cfg) {
  d <- file.path(tempdir(), paste0("parity_", paste(sample(letters, 6), collapse = "")))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  core$dmf_write_sheets <- function(sheets, path) invisible(path)
  core$dmetfinder_run(file.path(root, "demo_data", "groupA.xlsx"),
                      file.path(root, "demo_data", "groupB.xlsx"),
                      d, config = cfg, verbose = FALSE)
}
r_default <- run(NULL)                       # what the CLI sends with no --params
r_web <- run(web_cfg)                        # what the app sends

sheets_flat <- function(res) {
  s <- res$sheets
  c(s$A, list(s$compare_ab), list(s$diff_ab), list(s$diff_ba),
    if (is.null(s$diff_union)) list() else list(s$diff_union),
    s$B, list(s$compare_ba))
}
fa <- sheets_flat(r_default)
fb <- sheets_flat(r_web)
ok(length(fa) == length(fb) && identical(vapply(fa, `[[`, "", "name"),
                                         vapply(fb, `[[`, "", "name")),
   sprintf("%d sheets on both sides, same names and order", length(fa)))

if (length(fa) == length(fb)) {
  bad_sheets <- character(0)
  for (i in seq_along(fa)) {
    ca <- fa[[i]]$cols; cb <- fb[[i]]$cols
    same_cols <- length(ca) == length(cb) &&
      all(vapply(seq_along(ca), function(j) identical(ca[[j]], cb[[j]]), logical(1L)))
    same_hdr <- identical(fa[[i]]$header, fb[[i]]$header)
    if (!same_cols || !same_hdr) bad_sheets <- c(bad_sheets, fa[[i]]$name)
  }
  ok(length(bad_sheets) == 0L, "every cell of every sheet is identical",
     paste(bad_sheets, collapse = " | "))
}

# ---- verdict -------------------------------------------------------------
say("")
if (fail == 0L) {
  say("RESULT: CLI and web app are the same analysis.")
  quit(save = "no", status = 0L)
} else {
  say("RESULT: %d check(s) failed.", fail)
  quit(save = "no", status = 1L)
}

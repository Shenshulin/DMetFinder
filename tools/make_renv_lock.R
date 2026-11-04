#!/usr/bin/env Rscript
# ============================================================
# tools/make_renv_lock.R -- regenerate renv.lock without taking over
# the project
# ------------------------------------------------------------
# Why this exists: `renv::init()` at the project root writes .Rprofile,
# creates renv/library and changes how R starts up. For a project that
# is still driven by plain `Rscript cli/dmf.R`, that is a hostile
# takeover. But reviewers do like a lockfile.
#
# So: build the lock inside a throwaway bare project, point snapshot()
# at the real library, write the result to the project root, delete the
# throwaway. The project keeps no .Rprofile and no renv/ directory --
# `renv.lock` is a record, not a runtime switch.
#
#   Rscript tools/make_renv_lock.R
# ============================================================

`%||%` <- function(a, b) if (is.null(a)) b else a

root <- local({
  self <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(self) == 1L) {
    normalizePath(dirname(dirname(sub("^--file=", "", self))), winslash = "/")
  } else {
    normalizePath(getwd(), winslash = "/")
  }
})

if (!requireNamespace("renv", quietly = TRUE)) {
  cat("renv is not installed. Either install it:\n")
  cat("  install.packages('renv')\n")
  cat("or skip this step -- deps.csv already lists every required package.\n")
  quit(save = "no", status = 3L)
}

deps <- utils::read.csv(file.path(root, "deps.csv"), stringsAsFactors = FALSE,
                        colClasses = "character", strip.white = TRUE)
pkgs <- deps$package[tolower(trimws(deps$required)) == "yes"]

cat(sprintf("Building renv.lock for %d package(s): %s\n",
            length(pkgs), paste(pkgs, collapse = ", ")))

# Throwaway project. bare = TRUE keeps it empty; load = FALSE avoids
# restarting or attaching anything.
tmp <- tempfile("renvlock_")
dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE, force = TRUE), add = TRUE)

suppressMessages(
  renv::init(project = tmp, bare = TRUE, restart = FALSE, load = FALSE)
)

lock <- file.path(root, "renv.lock")

res <- tryCatch(
  renv::snapshot(
    project  = tmp,
    library  = .libPaths(),
    packages = pkgs,
    lockfile = lock,
    type     = "all",
    prompt   = FALSE,
    force    = TRUE
  ),
  error = function(e) {
    cat(sprintf("snapshot failed: %s\n", conditionMessage(e)))
    NULL
  }
)

if (!file.exists(lock)) {
  cat("renv.lock was not created.\n")
  quit(save = "no", status = 3L)
}

# Read it back so a malformed or empty lock is caught here, not by a
# collaborator three weeks later.
info <- tryCatch(jsonlite::fromJSON(lock, simplifyVector = FALSE),
                 error = function(e) NULL)
n <- if (!is.null(info$Packages)) length(info$Packages) else 0L
cat(sprintf("Wrote %s\n", lock))
cat(sprintf("  R version in lock : %s\n", info$R$Version %||% "?"))
cat(sprintf("  packages recorded : %d\n", n))

recorded <- names(info$Packages)
absent <- setdiff(pkgs, recorded)
if (length(absent) > 0L) {
  cat(sprintf("  WARNING: not recorded: %s\n", paste(absent, collapse = ", ")))
}

# Confirm we did not leave a project-level takeover behind.
for (p in c(".Rprofile", "renv")) {
  if (file.exists(file.path(root, p))) {
    cat(sprintf("  WARNING: %s exists at the project root -- renv may be active.\n", p))
  }
}

quit(save = "no", status = 0L)

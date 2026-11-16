#!/usr/bin/env Rscript
# ============================================================
# setup.R -- install the R packages DMetFinder's agent CLI needs
# ------------------------------------------------------------
# Design constraint: this file uses base R + utils ONLY, because it
# runs in an environment that may have none of the packages it is
# about to install. No jsonlite, no optparse, no data.table here.
#
#   Rscript setup.R                 install what is missing
#   Rscript setup.R --check-only    report only, change nothing
#   Rscript setup.R --with-optional also mzR / rawrr (MSGeter, P1)
#   Rscript setup.R --repos <url>   use another CRAN mirror
#
# After a successful run it invokes `cli/dmf.R doctor` so the user
# gets a single verdict rather than a list of package names.
# ============================================================

options(warn = 1)

# ------------------------------------------------------------
# Library path repair.
#
# Real failure seen on this machine: when Rscript is launched from Git
# Bash, LOCALAPPDATA arrives as a POSIX path (/c/Users/...). R then
# derives a user library that does not exist, .libPaths() silently
# drops it, and install.packages() tries to write into Program Files
# and fails with "permission denied". Rebuilding the path from
# USERPROFILE fixes it. Harmless when LOCALAPPDATA is already correct.
# ------------------------------------------------------------
fix_libpaths <- function(verbose = TRUE) {
  if (.Platform$OS.type != "windows") return(invisible(NULL))

  la <- Sys.getenv("LOCALAPPDATA", unset = "")
  if (!nzchar(la) || grepl("^/[a-zA-Z]/", la)) {
    up <- Sys.getenv("USERPROFILE", unset = "")
    if (!nzchar(up)) return(invisible(NULL))
    la <- file.path(up, "AppData", "Local")
    Sys.setenv(LOCALAPPDATA = la)
    if (verbose) cat("  [fix] LOCALAPPDATA rebuilt as a Windows path\n")
  }

  ver <- paste(R.version$major, strsplit(R.version$minor, ".", fixed = TRUE)[[1]][1],
               sep = ".")
  user_lib <- file.path(la, "R", "win-library", ver)
  if (!dir.exists(user_lib)) {
    dir.create(user_lib, recursive = TRUE, showWarnings = FALSE)
  }
  if (!dir.exists(user_lib)) return(invisible(NULL))

  if (!norm_path(user_lib) %in% norm_path(.libPaths())) {
    .libPaths(c(user_lib, .libPaths()))
    if (verbose) cat(sprintf("  [fix] user library added: %s\n", user_lib))
  }
  invisible(user_lib)
}

norm_path <- function(x) {
  tryCatch(normalizePath(x, winslash = "/", mustWork = FALSE), error = function(e) x)
}

# ------------------------------------------------------------
# Argument parsing (hand-rolled: cannot depend on optparse)
# ------------------------------------------------------------
parse_args <- function(argv) {
  opt <- list(
    repos         = "https://cloud.r-project.org",
    check_only    = FALSE,
    with_optional = FALSE,
    no_doctor     = FALSE
  )
  i <- 1L
  while (i <= length(argv)) {
    a <- argv[[i]]
    if (a %in% c("-h", "--help")) {
      cat(usage_text())
      quit(save = "no", status = 0L)
    } else if (a %in% c("-r", "--repos")) {
      if (i == length(argv)) stop("--repos needs a URL", call. = FALSE)
      i <- i + 1L
      opt$repos <- argv[[i]]
    } else if (a == "--check-only") {
      opt$check_only <- TRUE
    } else if (a == "--with-optional") {
      opt$with_optional <- TRUE
    } else if (a == "--no-doctor") {
      opt$no_doctor <- TRUE
    } else {
      stop(sprintf("unknown argument: %s\n(run with --help for usage)", a),
           call. = FALSE)
    }
    i <- i + 1L
  }
  opt
}

usage_text <- function() {
  paste(
    "Usage: Rscript setup.R [options]",
    "",
    "Options:",
    "  -r, --repos <url>   CRAN mirror (default: https://cloud.r-project.org)",
    "      --check-only    report what is missing, install nothing",
    "      --with-optional also install mzR / rawrr (only needed for MSGeter)",
    "      --no-doctor     skip the final `dmf.R doctor` run",
    "  -h, --help          show this help",
    "",
    "China mirror that usually works well:",
    "  Rscript setup.R --repos https://mirrors.tuna.tsinghua.edu.cn/CRAN/",
    sep = "\n"
  )
}

# ------------------------------------------------------------
# deps.csv is the single source of truth for what to install.
# Keeping it in a file (rather than inline) means the same list can be
# cited in the supplement and checked by the packaging script.
# ------------------------------------------------------------
read_deps <- function(path) {
  if (!file.exists(path)) {
    stop(sprintf("deps.csv not found at %s\nRun this script from the DMetFinder folder.",
                 path), call. = FALSE)
  }
  # fileEncoding="UTF-8-BOM": deps.csv carries a UTF-8 BOM, so under a non-UTF-8
  # locale the first column is read as "X...package" and the code reports a
  # missing column. Declaring it explicitly makes the read work under any locale,
  # including when the file has no BOM at all.
  d <- utils::read.csv(path, stringsAsFactors = FALSE,
                       colClasses = "character", strip.white = TRUE,
                       fileEncoding = "UTF-8-BOM")
  need <- c("package", "min_version", "required", "install_from", "purpose")
  miss <- setdiff(need, names(d))
  if (length(miss) > 0L) {
    stop(sprintf("deps.csv is missing column(s): %s", paste(miss, collapse = ", ")),
         call. = FALSE)
  }
  d[!is.na(d$package) & nzchar(d$package), , drop = FALSE]
}

# ------------------------------------------------------------
# Package state
# ------------------------------------------------------------
pkg_table <- function() {
  ip <- tryCatch(utils::installed.packages()[, c("Package", "Version"), drop = FALSE],
                 error = function(e) matrix(character(0), 0L, 2L,
                                            dimnames = list(NULL, c("Package", "Version"))))
  list(
    has = ip[, "Package"],
    ver = stats::setNames(ip[, "Version"], ip[, "Package"])
  )
}

pkg_state <- function(tab, p, minv) {
  if (!p %in% tab$has) return("missing")
  if (utils::compareVersion(tab$ver[[p]], minv) < 0) return("old")
  "ok"
}

install_one <- function(p, from, repos) {
  if (identical(from, "Bioconductor")) {
    if (!requireNamespace("BiocManager", quietly = TRUE)) {
      utils::install.packages("BiocManager", repos = repos)
    }
    if (!requireNamespace("BiocManager", quietly = TRUE)) {
      return(FALSE)
    }
    tryCatch({
      BiocManager::install(p, update = FALSE, ask = FALSE, quiet = TRUE)
      TRUE
    }, error = function(e) {
      cat(sprintf("\n       BiocManager failed: %s\n", conditionMessage(e)))
      FALSE
    })
  } else {
    tryCatch({
      utils::install.packages(p, repos = repos, dependencies = TRUE)
      TRUE
    }, error = function(e) {
      cat(sprintf("\n       install.packages failed: %s\n", conditionMessage(e)))
      FALSE
    })
  }
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
main <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  opt <- tryCatch(parse_args(argv), error = function(e) {
    cat(sprintf("Error: %s\n", conditionMessage(e)))
    quit(save = "no", status = 1L)
  })

  # Locate the project root from --file=, so the script works no matter
  # which directory it is called from.
  self <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  root <- if (length(self) == 1L) {
    norm_path(dirname(norm_path(sub("^--file=", "", self))))
  } else {
    norm_path(getwd())
  }

  cat("\nDMetFinder setup\n")
  cat(sprintf("  project : %s\n", root))
  cat(sprintf("  R       : %s (%s)\n", R.version.string,
              paste(R.version$platform)))

  fix_libpaths()

  cat(sprintf("  library : %s\n", paste(norm_path(.libPaths()), collapse = "\n            ")))

  # ---- R version gate: data.table / openxlsx need >= 4.3 in practice ----
  rnum <- as.numeric(R.version$major) +
    as.numeric(strsplit(R.version$minor, ".", fixed = TRUE)[[1]][1]) / 100
  if (rnum < 4.03) {
    cat(sprintf("\n[FAIL] R %s is too old; 4.3 or newer is required.\n", R.version$major))
    cat("       https://cloud.r-project.org/\n")
    return(3L)
  }

  all_deps <- read_deps(file.path(root, "deps.csv"))
  is_req <- tolower(trimws(all_deps$required)) == "yes"
  deps <- if (isTRUE(opt$with_optional)) all_deps else all_deps[is_req, , drop = FALSE]

  cat(sprintf("\nChecking %d package(s) from deps.csv\n\n", nrow(deps)))

  tab <- pkg_table()
  failed <- character(0)
  changed <- 0L

  for (k in seq_len(nrow(deps))) {
    p   <- deps$package[[k]]
    minv <- deps$min_version[[k]]
    from <- deps$install_from[[k]]
    st  <- pkg_state(tab, p, minv)

    if (st == "ok") {
      cat(sprintf("  [ok]      %-12s %s\n", p, tab$ver[[p]]))
      next
    }

    if (st == "old") {
      cat(sprintf("  [old]     %-12s %s  (need >= %s)\n", p, tab$ver[[p]], minv))
    } else {
      cat(sprintf("  [missing] %-12s %s\n", p, "-"))
    }

    if (isTRUE(opt$check_only)) {
      failed <- c(failed, p)
      next
    }

    cat(sprintf("            installing from %s ...\n", from))
    install_one(p, from, opt$repos)
    changed <- changed + 1L

    # Re-check rather than trusting install.packages' warning stream.
    tab <- pkg_table()
    if (pkg_state(tab, p, minv) == "ok") {
      cat(sprintf("  [ok]      %-12s %s\n", p, tab$ver[[p]]))
    } else {
      cat(sprintf("  [FAIL]    %-12s still not usable\n", p))
      failed <- c(failed, p)
    }
  }

  # ---- optional extras are reported, never counted as failures ----
  optional <- all_deps[!is_req, , drop = FALSE]
  if (nrow(optional) > 0L) {
    cat("\nOptional (needed only for MSGeter, which is not wired yet):\n")
    tab <- pkg_table()
    for (k in seq_len(nrow(optional))) {
      p <- optional$package[[k]]
      st <- pkg_state(tab, p, optional$min_version[[k]])
      cat(sprintf("  %-12s %s\n", p, if (st == "ok") "installed" else "not installed"))
    }
  }

  # ---- verdict ----
  cat("\n")
  if (length(failed) > 0L) {
    cat(sprintf("RESULT: %d package(s) still missing: %s\n",
                length(failed), paste(failed, collapse = ", ")))
    cat("\nThings worth trying, in order:\n")
    cat("  1. Re-run with a mirror closer to you:\n")
    cat("       Rscript setup.R --repos https://mirrors.tuna.tsinghua.edu.cn/CRAN/\n")
    cat("  2. Packages that need compilation require Rtools on Windows:\n")
    cat("       https://cran.r-project.org/bin/windows/Rtools/\n")
    cat("  3. If the error says 'permission denied', the library is not writable.\n")
    cat("     Create a personal library folder and point R at it:\n")
    cat("       dir.create(Sys.getenv('R_LIBS_USER'), recursive = TRUE, showWarnings = FALSE)\n")
    return(3L)
  }

  cat("RESULT: all required packages are present.\n")
  if (changed > 0L) cat(sprintf("        (%d installed just now)\n", changed))

  # ---- hand over to the CLI's own self-check ----
  runner <- file.path(root, "cli", "dmf.R")
  if (!isTRUE(opt$no_doctor) && file.exists(runner)) {
    cat("\n--- dmf.R doctor ---\n")
    rscript <- file.path(R.home("bin"), "Rscript")
    st <- tryCatch(
      system2(rscript, c(shQuote(runner, type = "cmd"), "doctor")),
      error = function(e) 1L
    )
    if (!identical(as.integer(st), 0L)) {
      cat("\n(dmf.R doctor did not exit cleanly; see its output above)\n")
    }
  }

  cat("\nNext step:\n")
  cat("  cli\\run-dmf.bat inspect --input demo_data\\groupA.xlsx --out out\\inspect\n")
  cat("  cli\\run-dmf.bat diff --a demo_data\\groupA.xlsx --b demo_data\\groupB.xlsx --out out\\run1\n")
  0L
}

status <- tryCatch(main(), error = function(e) {
  cat(sprintf("\nUnexpected error: %s\n", conditionMessage(e)))
  3L
})
quit(save = "no", status = status)

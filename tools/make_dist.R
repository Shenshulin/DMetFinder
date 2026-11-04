#!/usr/bin/env Rscript
# ============================================================
# tools/make_dist.R -- build the folder we send to collaborators
# ------------------------------------------------------------
# The project root is not shippable: it carries www/, figures/, tests/,
# shiny_app/, out/ and a 60 MB manuscript trail. What a collaborator
# needs is a much smaller and, more importantly, *closed* set: the CLI,
# the two core files it loads, demo data, the docs, and the install
# script. A whitelist -- never a blacklist -- so that adding a file to
# the project can't accidentally ship it.
#
#   Rscript tools/make_dist.R                  -> dist/DMetFinder-CLI-1.0.3/
#   Rscript tools/make_dist.R --zip            -> ... plus a .zip
#   Rscript tools/make_dist.R --no-demo        -> skip the 24 MB demo data
#
# Every file's size and sha256 land in MANIFEST.txt, so a collaborator
# can prove they are running the same bytes we tested.
# ============================================================

root <- local({
  self <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(self) == 1L) {
    normalizePath(dirname(dirname(sub("^--file=", "", self))), winslash = "/")
  } else {
    normalizePath(getwd(), winslash = "/")
  }
})

# ---- args ----
argv <- commandArgs(trailingOnly = TRUE)
make_zip  <- "--zip" %in% argv
no_demo   <- "--no-demo" %in% argv
out_root  <- local({
  i <- which(argv == "--out")
  if (length(i) == 1L && i < length(argv)) argv[[i + 1L]] else file.path(root, "dist")
})
if ("--help" %in% argv || "-h" %in% argv) {
  cat("Usage: Rscript tools/make_dist.R [--zip] [--no-demo] [--out <dir>]\n")
  quit(save = "no", status = 0L)
}

# ---- version comes from the CLI itself, so the folder name cannot drift ----
cli_src <- readLines(file.path(root, "cli", "dmf.R"), warn = FALSE)
ver_line <- grep("^DMF_VERSION\\s*<-", cli_src, value = TRUE)
if (length(ver_line) != 1L) {
  stop("cannot find DMF_VERSION in cli/dmf.R", call. = FALSE)
}
version <- trimws(gsub('"', "", sub("^DMF_VERSION\\s*<-", "", ver_line)))
if (!nzchar(version)) stop("DMF_VERSION parsed as empty", call. = FALSE)

# ---- whitelist ----
lib_r <- list.files(file.path(root, "cli", "lib"), pattern = "\\.R$", full.names = FALSE)
if (length(lib_r) == 0L) stop("cli/lib is empty -- nothing to ship", call. = FALSE)

manifest <- c(
  "cli/dmf.R",
  "cli/run-dmf.bat",
  file.path("cli/lib", sort(lib_r)),
  "R/config.R",
  "R/dmetfinder_functions.R",
  # P1（msg-extract / msg-match / rt-apex）不复制 MSGeter 的计算函数，而是
  # source 这三个文件的顶层定义。少了它们，msg-* 会在运行时报
  # "缺少 MSGeter 源文件"。注意只需 *_server.R，ui/ 与 shiny_app/app.R 不必带。
  "shiny_app/server/FeatureGeter_server.R",
  "shiny_app/server/Ms2Geter_server.R",
  "shiny_app/server/RtGeter_server.R",
  "setup.R",
  "deps.csv",
  "renv.lock",
  "README_FIRST.txt",
  "docs/agent/QUICKSTART.md",
  "docs/agent/CLI_CONTRACT.md"
)
if (!no_demo) {
  manifest <- c(manifest, "demo_data/groupA.xlsx", "demo_data/groupB.xlsx")
}

# ---- every listed file must exist: a missing file is an error, not a skip ----
missing <- manifest[!file.exists(file.path(root, manifest))]
if (length(missing) > 0L) {
  cat("ERROR: these files are listed but do not exist:\n")
  cat(paste0("  ", missing, collapse = "\n"), "\n")
  cat("\nRun this after writing the docs, or drop them from the manifest.\n")
  quit(save = "no", status = 2L)
}

# ---- stage ----
name <- sprintf("DMetFinder-CLI-%s", version)
stage <- file.path(out_root, name)
if (dir.exists(stage)) unlink(stage, recursive = TRUE)
dir.create(stage, recursive = TRUE, showWarnings = FALSE)

for (rel in manifest) {
  dst <- file.path(stage, rel)
  dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)
  # copy in binary mode: run-dmf.bat must keep its exact bytes
  if (!file.copy(file.path(root, rel), dst, overwrite = TRUE)) {
    stop(sprintf("copy failed: %s", rel), call. = FALSE)
  }
}

# ---- MANIFEST.txt: the integrity chain ----
rows <- vapply(manifest, function(rel) {
  p <- file.path(stage, rel)
  sha <- tryCatch(digest::digest(file = p, algo = "sha256"),
                  error = function(e) "unavailable")
  sprintf("%-40s %10d  %s", rel, file.info(p)$size, sha)
}, character(1L))

total_bytes <- sum(file.info(file.path(stage, manifest))$size)

writeLines(c(
  sprintf("DMetFinder agent CLI %s", version),
  sprintf("built     : %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
  sprintf("R version : %s", R.version.string),
  sprintf("files     : %d", length(manifest)),
  sprintf("bytes     : %d (%.1f MB)", total_bytes, total_bytes / 1024^2),
  "",
  "Verify on receipt:",
  "  Windows PowerShell:",
  "    Get-FileHash <file> -Algorithm SHA256",
  "  R:",
  "    digest::digest(file = \"<file>\", algo = \"sha256\")",
  "",
  sprintf("%-40s %10s  %s", "FILE", "BYTES", "SHA256"),
  strrep("-", 110),
  rows
), file.path(stage, "MANIFEST.txt"))

# ---- zip ----
# zip::zipr() stores only basenames, so a 19-file archive comes out flat and
# the CLI cannot find R/config.R after unpacking. zipfile lets us set the
# entry name explicitly, so use Python when it is around. No Python is fine
# too: the staged folder is complete and we say how to compress it by hand.
zip_path <- NA_character_

zip_via_python <- function(zip_path, stage, name, rels) {
  py <- Sys.which("python")
  if (!nzchar(py)) py <- Sys.which("python3")
  if (!nzchar(py)) return(FALSE)

  script <- tempfile(fileext = ".py")
  list_file <- tempfile(fileext = ".txt")
  on.exit(unlink(c(script, list_file)), add = TRUE)

  writeLines(c(
    "import io, os, sys, zipfile",
    "zip_path, stage, name, list_file = sys.argv[1:5]",
    "rels = [l.strip() for l in io.open(list_file, encoding='utf-8') if l.strip()]",
    "missing = [r for r in rels if not os.path.isfile(os.path.join(stage, r))]",
    "if missing:",
    "    sys.exit('missing: ' + ', '.join(missing))",
    "with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:",
    "    for r in rels:",
    "        arc = os.path.join(name, r).replace(os.sep, '/')",
    "        z.write(os.path.join(stage, r), arc)",
    "print('entries=%d' % len(rels))"
  ), script, useBytes = TRUE)

  writeLines(rels, list_file, useBytes = TRUE)

  st <- suppressWarnings(tryCatch(
    system2(py, c(shQuote(script), shQuote(zip_path), shQuote(stage),
                  shQuote(name), shQuote(list_file)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) "error"
  ))
  file.exists(zip_path) && file.info(zip_path)$size > 0
}

if (make_zip) {
  zip_path <- file.path(out_root, sprintf("%s.zip", name))
  if (file.exists(zip_path)) unlink(zip_path)

  # MANIFEST.txt is written after the copy loop, so it is not in `manifest`
  # (a file cannot list its own hash). Add it explicitly, otherwise the one
  # file a collaborator needs for verification is the one file missing from
  # the archive.
  zip_entries <- c(manifest, "MANIFEST.txt")

  if (!zip_via_python(zip_path, stage, name, zip_entries)) {
    cat("\n[note] could not create the zip automatically.\n")
    cat("       The folder is complete; compress it yourself, keeping the top folder:\n")
    cat(sprintf('       powershell Compress-Archive -Path "%s" -DestinationPath "%s"\n',
                stage, zip_path))
    zip_path <- NA_character_
  }
}

# ---- summary ----
cat(sprintf("\nDMetFinder CLI %s\n", version))
cat(sprintf("  staged : %s\n", stage))
cat(sprintf("  files  : %d\n", length(manifest)))
cat(sprintf("  size   : %.1f MB\n", total_bytes / 1024^2))
cat(sprintf("  manifest: %s\n", file.path(stage, "MANIFEST.txt")))
if (!is.na(zip_path)) {
  cat(sprintf("  zip    : %s (%.1f MB)\n", zip_path,
              file.info(zip_path)$size / 1024^2))
}
if (no_demo) cat("  demo data excluded (--no-demo)\n")

cat("\nContents:\n")
for (rel in manifest) cat(sprintf("  %s\n", rel))

cat("\nNext: unpack the archive somewhere unrelated and run\n")
cat("  Rscript setup.R --check-only\n")
cat("  cli\\run-dmf.bat diff --a demo_data\\groupA.xlsx --b demo_data\\groupB.xlsx --out out\\run1\n")

quit(save = "no", status = 0L)

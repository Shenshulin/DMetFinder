# RtGeter_server.R
# ============================================================
# RtGeter -- batch-resolve a "minute window" into an "exact retention time"
#
# Input
#   1) Peak table: four columns (peak id / sample / MZ / RT_min),
#      supports xlsx, xls, csv, tsv, txt
#   2) Raw data folder: holds .raw / .mzML / .mzXML
#
# Output
#   All original peak-table columns + one appended RT column (five in total)
#
# RT_min is the **right endpoint** of the minute window:
#   RT_min = 2  ->  (1, 2]
#   RT_min = 3  ->  (2, 3]
#   RT_min = 4  ->  (3, 4]
# Left-open, right-closed, so adjacent one-minute bins neither overlap nor leave gaps.
#
# Only MS1 spectra are scanned inside a window: for each spectrum take the most
# intense peak within the m/z tolerance, then take the most intense spectrum over
# the window and return its retention time (ties keep the earlier scan).
#
# Performance notes:
#   1. Read only the index to get the retention time of every scan, filter the
#      MS1 scans inside the window in memory, then read spectra by scan number
#      -- without loading the whole file (.raw files are often hundreds of MB).
#   2. Group by (sample, RT_min) so each group reads spectra once and every m/z
#      in that group reuses them.
#   3. The index is cached by (path, mtime), so re-runs do not re-parse.
# ============================================================


# ------------------------------------------------------------
# List the mass-spec files available in the working directory
# Returns data.frame(name, path, ext); 0 rows when there is no file
# ------------------------------------------------------------
rtg_list_ms_files <- function(workdir) {
  empty <- data.frame(name = character(0), path = character(0),
                      ext = character(0), stringsAsFactors = FALSE)
  if (is.null(workdir) || !nzchar(workdir) || !dir.exists(workdir)) return(empty)

  files <- list.files(path = workdir,
                      pattern = "\\.(raw|mzml|mzxml)$",
                      full.names = TRUE, ignore.case = TRUE)
  if (length(files) == 0) return(empty)

  out <- data.frame(
    name = tools::file_path_sans_ext(basename(files)),
    path = files,
    ext  = tolower(tools::file_ext(files)),
    stringsAsFactors = FALSE
  )
  # When one sample exists in several formats keep the first one (same as Ms1Geter)
  out[!duplicated(out$name), , drop = FALSE]
}


# ------------------------------------------------------------
# Sample-name normalisation: lowercase + strip extension / path / whitespace and common separators
# So "P173", "p173 ", "P173.raw", "G:/data/P173.mzML" all resolve to the same file
# ------------------------------------------------------------
rtg_norm_name <- function(x) {
  x <- as.character(x)
  x <- tolower(trimws(x))
  x <- basename(gsub("\\\\", "/", x))
  x <- sub("\\.(raw|mzml|mzxml)$", "", x)
  x <- gsub("[[:space:]_.-]+", "", x)
  x
}


# ------------------------------------------------------------
# Read the MS1 scan index of one mass-spec file
#
# Returns data.frame(scan, read_key, StartTime, scanType):
#   scan     : scan number reported to the user
#   read_key : key used when reading spectra (.raw uses the scan number; mzML uses the row number in the file)
#   StartTime: retention time in minutes
# ------------------------------------------------------------
rtg_ms1_index <- function(path) {

  ext <- tolower(tools::file_ext(path))

  if (identical(ext, "raw")) {

    idx <- rawrr::readIndex(path)

    # MSOrder is the most reliable criterion; older rawrr versions lack this column,
    # so fall back to the scan-type string
    if ("MSOrder" %in% names(idx) && any(!is.na(idx$MSOrder))) {
      is_ms1 <- !is.na(idx$MSOrder) & idx$MSOrder == "Ms"
    } else {
      is_ms1 <- !is.na(idx$scanType) & idx$scanType == MS1_SCAN_TYPE
    }
    # One more fallback: when MSOrder is absent and the scan type is not the
    # expected constant, decide on "Full ms"
    if (!any(is_ms1)) {
      is_ms1 <- !is.na(idx$scanType) &
        grepl("Full ms", idx$scanType, fixed = TRUE) &
        !grepl(" ms2 ", paste0(" ", idx$scanType), fixed = TRUE)
    }

    out <- data.frame(
      scan      = as.numeric(idx$scan),
      read_key  = as.numeric(idx$scan),
      StartTime = as.numeric(idx$StartTime),
      scanType  = as.character(idx$scanType),
      stringsAsFactors = FALSE
    )
    return(out[is_ms1 & !is.na(out$StartTime), , drop = FALSE])
  }

  if (ext %in% c("mzml", "mzxml")) {

    if (!requireNamespace("mzR", quietly = TRUE)) {
      stop("Handling .mzML/.mzXML files requires the mzR package, please run in R: BiocManager::install(\"mzR\")")
    }

    ms <- mzR::openMSfile(path)
    on.exit(mzR::close(ms), add = TRUE)

    hdr <- mzR::header(ms)
    lv  <- as.integer(hdr$msLevel)

    keep <- !is.na(lv) & lv == 1L & !is.na(hdr$retentionTime)

    # An explicit return() is required: the fallback at the end of the body is stop(),
    # so a bare expression here would fall through to stop() and report "unsupported format".
    return(data.frame(
      scan      = as.numeric(hdr$seqNum)[keep],
      # mzR::peaks() takes the row number inside the file, not seqNum
      read_key  = which(keep),
      StartTime = as.numeric(hdr$retentionTime)[keep] / 60,
      scanType  = "ms1",
      stringsAsFactors = FALSE
    ))
  }

  stop("Unsupported mass-spec file format: .", ext, " (supported: .raw / .mzML / .mzXML)")
}


# ------------------------------------------------------------
# Read spectra for the specified scans only
# Returns a list, each element is list(mz, intensity)
# ------------------------------------------------------------
rtg_read_scans <- function(path, read_keys) {

  ext <- tolower(tools::file_ext(path))

  if (identical(ext, "raw")) {
    S <- rawrr::readSpectrum(rawfile = path, scan = read_keys, mode = "profile")
    return(lapply(S, function(x) {
      list(mz = as.numeric(x[["centroid.mZ"]]),
           intensity = as.numeric(x[["centroid.intensity"]]))
    }))
  }

  if (!requireNamespace("mzR", quietly = TRUE)) {
    stop("Handling .mzML/.mzXML files requires the mzR package, please run in R: BiocManager::install(\"mzR\")")
  }

  ms <- mzR::openMSfile(path)
  on.exit(mzR::close(ms), add = TRUE)

  lapply(read_keys, function(k) {
    p <- mzR::peaks(ms, k)
    m <- as.numeric(p[, 1])
    v <- as.numeric(p[, 2])
    # Centroid profile data first, otherwise the whole profile of one ion counts as several peaks
    if (length(m) > 2 && looks_like_profile(m)) {
      cp <- centroid_profile_peaks(m, v)
      m  <- cp$mz
      v  <- cp$intensity
    }
    list(mz = m, intensity = v)
  })
}


# ------------------------------------------------------------
# Pick a peak from a set of already-read spectra: the most intense spectrum for this m/z inside the window
#
# Arguments:
#   spectra : result of rtg_read_scans(), same order as win
#   win     : scan index inside the window (with StartTime / scan)
#   mz / tol / unit : target mass and tolerance
#
# Returns list(ok, status, rt, scan, mz_found, intensity, err_ppm, n_hit)
# ------------------------------------------------------------
rtg_pick_apex <- function(spectra, win, mz, tol, unit = "ppm") {

  best <- NULL
  n_hit <- 0L

  for (i in seq_along(spectra)) {

    sp <- spectra[[i]]
    if (is.null(sp) || length(sp$mz) == 0) next

    if (identical(unit, "Da")) {
      dist <- abs(sp$mz - mz)
    } else {
      dist <- abs(sp$mz - mz) / mz * 1e6
    }

    hit <- which(!is.na(dist) & dist <= tol)
    if (length(hit) == 0) next

    n_hit <- n_hit + 1L

    # One spectrum may hold more than one peak inside the tolerance; take the most intense one
    j <- hit[which.max(sp$intensity[hit])]
    inten <- sp$intensity[j]

    # Replace only on a strictly greater intensity -> on an exact tie keep the earlier scan
    if (is.null(best) || inten > best$intensity) {
      best <- list(
        rt        = win$StartTime[i],
        scan      = win$scan[i],
        mz_found  = sp$mz[j],
        intensity = inten
      )
    }
  }

  if (is.null(best)) {
    return(list(ok = FALSE, status = "no_peak", n_hit = 0L))
  }

  best$ok      <- TRUE
  best$status  <- "ok"
  best$err_ppm <- (best$mz_found - mz) / mz * 1e6
  best$n_hit   <- n_hit
  best
}


# ------------------------------------------------------------
# Single query (kept for scripts / unit tests)
# ------------------------------------------------------------
rtg_query_apex <- function(path, index, mz, rt_min, tol, unit = "ppm") {

  lo <- rt_min - 1
  hi <- rt_min

  if (is.null(index) || nrow(index) == 0) {
    return(list(ok = FALSE, status = "no_index",
                message = "No MS1 scans could be read from this file."))
  }

  win <- index[index$StartTime > lo & index$StartTime <= hi, , drop = FALSE]

  if (nrow(win) == 0) {
    return(list(ok = FALSE, status = "empty_window",
                message = sprintf("No MS1 scans inside the window (%.3f, %.3f] minutes.", lo, hi),
                n_scan = 0))
  }

  win <- win[order(win$StartTime), , drop = FALSE]
  spectra <- rtg_read_scans(path, win$read_key)

  res <- rtg_pick_apex(spectra, win, mz, tol, unit)
  res$n_scan <- nrow(win)

  if (isTRUE(res$ok)) {
    res$message <- "ok"
  } else {
    res$message <- sprintf(
      "In the window (%.3f, %.3f], none of the %d MS1 spectra has a peak within %.4f ± %s %s.",
      lo, hi, nrow(win), mz,
      format(tol, trim = TRUE, scientific = FALSE), unit)
  }
  res
}


# ============================================================
# Table reading and column detection
# ============================================================

# Tell whether a chunk of text is valid UTF-8 (used to distinguish UTF-8 from GB18030 tables)
rtg_is_utf8 <- function(path, n_lines = 200L) {
  ln <- tryCatch(readLines(path, n = n_lines, warn = FALSE),
                 error = function(e) character(0))
  if (length(ln) == 0) return(TRUE)
  isTRUE(validUTF8(paste(ln, collapse = "\n")))
}

# Read the peak table -> data.frame (everything comes in as character and is converted later,
# so peak ids are not turned by Excel into inconsistent forms such as 1 and 1.0)
rtg_read_table <- function(path) {

  ext <- tolower(tools::file_ext(path))

  if (ext %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop("Reading Excel files requires the readxl package.")
    }
    df <- readxl::read_excel(path, sheet = 1, col_types = "text")
    df <- as.data.frame(df, stringsAsFactors = FALSE, check.names = FALSE)
    names(df) <- trimws(names(df))
    return(df)
  }

  if (!ext %in% c("csv", "tsv", "txt")) {
    stop("Unsupported table format: .", ext,
         " (supported: .xlsx / .xls / .csv / .tsv / .txt)")
  }

  # Separator: the extension wins; for .txt decide from tabs and commas in the first line
  sep <- if (ext == "tsv") {
    "\t"
  } else if (ext == "csv") {
    ","
  } else {
    l1 <- tryCatch(readLines(path, n = 1L, warn = FALSE),
                   error = function(e) "")
    if (length(l1) && grepl("\t", l1[1], fixed = TRUE) &&
        !grepl(",", l1[1], fixed = TRUE)) "\t" else ","
  }

  enc <- if (rtg_is_utf8(path)) "UTF-8-BOM" else "GB18030"

  df <- suppressWarnings(tryCatch(
    utils::read.table(path, sep = sep, header = TRUE, quote = "\"",
                      comment.char = "", colClasses = "character",
                      check.names = FALSE, stringsAsFactors = FALSE,
                      fileEncoding = enc, na.strings = character(0)),
    error = function(e) NULL))

  if (is.null(df) || ncol(df) == 0) {
    stop("Failed to read the table (separator or encoding not recognised): ", basename(path))
  }

  names(df) <- trimws(names(df))
  df
}

# Column-name normalisation: lowercase + strip whitespace and punctuation
# (e.g. "RT_min" -> "rtmin", "peak id" -> "peakid", "m/z" -> "mz")
rtg_norm_colname <- function(x) {
  x <- tolower(as.character(x))
  x <- gsub("[[:space:][:punct:]]", "", x)
  gsub("\uff1a", "", x, fixed = TRUE)   # full-width colon is not covered by [:punct:]
}

# Candidate column names per field, **in priority order** (earlier entries win).
# The Chinese aliases below are kept on purpose so Chinese peak tables still parse.
.rtg_col_alias <- list(
  id     = c("峰id", "峰编号", "峰序号", "峰号", "peakid", "featureid",
             "peakno", "id", "编号", "序号"),
  sample = c("样品名称", "样本名称", "样品名", "样本名", "samplename",
             "sampleid", "sample", "样品", "样本", "name", "filename", "文件名称"),
  mz     = c("mz", "mz值", "目标mz", "母离子mz", "母离子", "质荷比",
             "precursormz", "mass"),
  rt_min = c("rtmin", "rt分钟", "保留时间分钟", "rtmin值", "rtmin整数", "分钟")
)

# Find a column by alias priority; returns the column index, NA when not found
rtg_find_col <- function(nm_norm, aliases) {
  for (a in aliases) {
    h <- which(nm_norm == a)
    if (length(h)) return(h[1])
  }
  # Nothing matched exactly: fall back to substring matching (short aliases misfire easily,
  # so require >= 3 characters and a unique hit)
  for (a in aliases[nchar(aliases) >= 3]) {
    h <- which(grepl(a, nm_norm, fixed = TRUE))
    if (length(h) == 1L) return(h[1])
  }
  NA_integer_
}

# Auto-detect the four columns; when detection is incomplete fall back to positions (first four)
rtg_detect_cols <- function(df) {

  if (is.null(df) || ncol(df) < 4) return(NULL)

  nn <- rtg_norm_colname(names(df))
  idx <- c(id     = rtg_find_col(nn, .rtg_col_alias$id),
           sample = rtg_find_col(nn, .rtg_col_alias$sample),
           mz     = rtg_find_col(nn, .rtg_col_alias$mz),
           rt_min = rtg_find_col(nn, .rtg_col_alias$rt_min))

  auto <- !anyNA(idx) && !anyDuplicated(idx)
  if (!auto) idx <- c(id = 1L, sample = 2L, mz = 3L, rt_min = 4L)

  list(id = unname(idx[["id"]]), sample = unname(idx[["sample"]]),
       mz = unname(idx[["mz"]]), rt_min = unname(idx[["rt_min"]]),
       names = c(id = names(df)[idx[["id"]]],
                 sample = names(df)[idx[["sample"]]],
                 mz = names(df)[idx[["mz"]]],
                 rt_min = names(df)[idx[["rt_min"]]]),
       auto = auto)
}

# Character -> numeric (tolerates surrounding whitespace and thousands-separator commas)
rtg_num <- function(x) {
  x <- gsub("[[:space:],]", "", as.character(x))
  suppressWarnings(as.numeric(x))
}


# ============================================================
# Batch main flow
#
# df    : peak table (original data.frame)
# cols  : result of rtg_detect_cols() (or an isomorphic list after manual selection)
# files : result of rtg_list_ms_files()
#
# Returns list(result = input + RT column, diag = diagnostics table, log = log lines)
# ============================================================
rtg_run_batch <- function(df, cols, files, tol, unit = "ppm", progress = NULL) {

  n <- nrow(df)
  logs <- character(0)
  say <- function(...) logs <<- c(logs, sprintf(...))

  diag <- data.frame(
    Peak_ID   = as.character(df[[cols$id]]),
    Sample    = as.character(df[[cols$sample]]),
    MZ        = rtg_num(df[[cols$mz]]),
    RT_min    = rtg_num(df[[cols$rt_min]]),
    Window    = NA_character_,
    Status    = NA_character_,
    RT        = NA_real_,
    Intensity = NA_real_,
    Scan      = NA_real_,
    MZ_found  = NA_real_,
    Error_ppm = NA_real_,
    MS1_scans = NA_integer_,
    Scans_hit = NA_integer_,
    File      = NA_character_,
    stringsAsFactors = FALSE
  )

  # ---- Pre-checks: sample name, RT_min, MZ ----
  skey <- rtg_norm_name(diag$Sample)
  bad_sample <- is.na(skey) | !nzchar(skey)
  if (any(bad_sample)) {
    diag$Status[bad_sample] <- "bad_sample"
    say("⚠️ %d rows have an empty sample name and were skipped.", sum(bad_sample))
  }

  bad_rt <- !bad_sample & (is.na(diag$RT_min) | !is.finite(diag$RT_min) | diag$RT_min <= 0)
  if (any(bad_rt)) {
    diag$Status[bad_rt] <- "bad_rt_min"
    say("⚠️ %d rows have a non-positive RT_min and were skipped.", sum(bad_rt))
  }

  bad_mz <- !bad_sample & !bad_rt & (is.na(diag$MZ) | !is.finite(diag$MZ) | diag$MZ <= 0)
  if (any(bad_mz)) {
    diag$Status[bad_mz] <- "bad_mz"
    say("⚠️ %d rows have a non-positive MZ and were skipped.", sum(bad_mz))
  }

  todo <- !bad_sample & !bad_rt & !bad_mz

  # ---- Sample name -> file path ----
  fkeys <- rtg_norm_name(files$name)
  fmap  <- stats::setNames(files$path, fkeys)

  resolve_file <- function(k) {
    if (is.na(k) || !nzchar(k)) return(NA_character_)
    if (k %in% fkeys) return(fmap[[k]])
    # Unique prefix / suffix / substring match ("P173" matches "P173_rep1")
    h <- fkeys[startsWith(fkeys, k) | endsWith(fkeys, k) |
                 grepl(k, fkeys, fixed = TRUE)]
    if (length(h) == 1L) return(fmap[[h]])
    NA_character_
  }

  total_steps <- max(1L, sum(todo))
  done_steps  <- 0L
  tick <- function(k, detail = NULL) {
    done_steps <<- done_steps + k
    if (is.function(progress)) progress(done_steps, total_steps, detail)
  }

  samples <- unique(skey[todo])

  for (s in samples) {

    rows_s <- which(skey == s & todo)
    path <- resolve_file(s)

    if (is.na(path)) {
      diag$Status[rows_s] <- "sample_not_found"
      say("❌ Sample %s: no matching file found in the folder.", diag$Sample[rows_s[1]])
      tick(length(rows_s))
      next
    }

    diag$File[rows_s] <- basename(path)
    n_samples_done <- length(rows_s)

    idx <- tryCatch(rtg_ms1_index(path), error = function(e) {
      say("❌ %s: failed to read the index -- %s", basename(path), conditionMessage(e))
      NULL
    })

    if (is.null(idx) || nrow(idx) == 0) {
      diag$Status[rows_s] <- "no_index"
      tick(n_samples_done)
      next
    }

    diag$MS1_scans[rows_s] <- nrow(idx)

    # Group by RT_min inside one sample so each window reads spectra only once
    rtv <- diag$RT_min[rows_s]
    gkey <- format(rtv, trim = TRUE, scientific = FALSE)
    for (g in unique(gkey)) {

      rows_g <- rows_s[gkey == g]
      rt_min <- rtv[gkey == g][1]
      lo <- rt_min - 1
      hi <- rt_min

      diag$Window[rows_g] <- sprintf("(%.3f, %.3f]", lo, hi)

      win <- idx[idx$StartTime > lo & idx$StartTime <= hi, , drop = FALSE]

      if (nrow(win) == 0) {
        diag$Status[rows_g] <- "empty_window"
        diag$MS1_scans[rows_g] <- 0L
        say("⚠️ %s: no MS1 scans in window %s.", basename(path),
            diag$Window[rows_g[1]])
        tick(length(rows_g))
        next
      }

      win <- win[order(win$StartTime), , drop = FALSE]
      diag$MS1_scans[rows_g] <- nrow(win)

      spectra <- tryCatch(rtg_read_scans(path, win$read_key), error = function(e) {
        say("❌ %s: failed to read spectra -- %s", basename(path), conditionMessage(e))
        NULL
      })

      if (is.null(spectra)) {
        diag$Status[rows_g] <- "read_error"
        tick(length(rows_g))
        next
      }

      for (r in rows_g) {
        a <- rtg_pick_apex(spectra, win, diag$MZ[r], tol, unit)
        diag$Status[r]   <- a$status
        diag$Scans_hit[r] <- as.integer(a$n_hit)
        if (isTRUE(a$ok)) {
          diag$RT[r]        <- a$rt
          diag$Intensity[r] <- a$intensity
          diag$Scan[r]      <- a$scan
          diag$MZ_found[r]  <- a$mz_found
          diag$Error_ppm[r] <- a$err_ppm
        }
      }

      tick(length(rows_g), detail = sprintf("%s · %s", basename(path),
                                            diag$Window[rows_g[1]]))
    }

    say("✅ %s: %d MS1 scans, %d rows queried.", basename(path), nrow(idx),
        n_samples_done)
  }

  # ---- Assemble output: all original columns + RT ----
  out <- df
  rt_col <- "RT"
  if (rt_col %in% names(out)) rt_col <- "RT_RtGeter"
  out[[rt_col]] <- diag$RT

  n_ok <- sum(!is.na(diag$RT))
  say("Done: %d rows, %d resolved, %d without a hit.", n, n_ok, n - n_ok)

  list(result = out, diag = diag, log = logs)
}


# ============================================================
# Persist the RtGeter run log to disk
#
# Previously the log only went into a reactiveVal (the "run log" box on the page),
# so refreshing the page or restarting the app lost it and any later review meant
# a re-run. Here we also write a copy under .workbuddy/logs/rgeter/ and mirror it
# to the console (shiny startup log). Any disk-write error is swallowed by tryCatch
# and never affects the main flow.
# ============================================================
RTG_LOG_DIR <- file.path(".workbuddy", "logs", "rgeter")

rtg_file_logger <- function() {
  path <- NULL
  function(lines) {
    if (length(lines) == 0L) return(invisible(NULL))
    tryCatch({
      if (is.null(path)) {
        dir.create(RTG_LOG_DIR, recursive = TRUE, showWarnings = FALSE)
        path <<- file.path(RTG_LOG_DIR, sprintf(
          "rgeter_%s_pid%d.log",
          format(Sys.time(), "%Y%m%d_%H%M%S"), Sys.getpid()))
        writeLines(enc2utf8(sprintf("# RtGeter session @ %s",
                                    format(Sys.time(), "%Y-%m-%d %H:%M:%S"))),
                   path, useBytes = TRUE)
      }
      cat(enc2utf8(lines), file = path, sep = "\n", append = TRUE)
      cat(enc2utf8(lines), sep = "\n", file = stderr())
    }, error = function(e) invisible(NULL))
    invisible(path)
  }
}


# ============================================================
# RtGeter module
# ============================================================
RtGeter_server <- function(id) {

  moduleServer(id, function(input, output, session) {

    log_text <- reactiveVal("")
    write_log_file <- rtg_file_logger()
    append_log <- function(msg) {
      if (length(msg) == 0) return(invisible(NULL))
      stamp <- format(Sys.time(), "[%H:%M:%S] ")
      log_text(paste0(log_text(), paste0(stamp, msg, "\n", collapse = "")))
      write_log_file(paste0(stamp, msg))
    }
    output$log <- renderText(log_text())

    output$dl_log <- downloadHandler(
      filename = function() sprintf("RtGeter_log_%s.txt",
                                    format(Sys.time(), "%Y%m%d_%H%M%S")),
      content = function(file) writeLines(enc2utf8(log_text()), file, useBytes = TRUE)
    )

    # ---------------- Mass-spec files in the folder ----------------
    files <- reactive({
      rtg_list_ms_files(input$workdir)
    })

    observeEvent(files(), {
      f <- files()
      if (nrow(f) == 0) {
        append_log("⚠️ No .raw / .mzML / .mzXML found in the raw data folder.")
      } else {
        append_log(sprintf("Found %d mass-spec files: %s%s", nrow(f),
                           paste(utils::head(f$name, 6), collapse = ", "),
                           if (nrow(f) > 6) " …" else ""))
      }
    }, ignoreNULL = FALSE)

    # ---------------- Peak table ----------------
    tbl <- reactive({
      up <- input$peak_table
      if (is.null(up) || nrow(up) == 0) return(NULL)
      tryCatch(rtg_read_table(up$datapath[1]), error = function(e) {
        append_log(paste("❌ Failed to read the table: ", conditionMessage(e)))
        NULL
      })
    })

    observeEvent(tbl(), {
      df <- tbl()
      if (is.null(df)) return(invisible(NULL))
      if (ncol(df) < 4) {
        append_log(sprintf("❌ The peak table has only %d columns; at least four are required (peak id / sample / MZ / RT_min).",
                           ncol(df)))
        return(invisible(NULL))
      }
      append_log(sprintf("Peak table: %d rows x %d columns -- %s", nrow(df), ncol(df),
                         paste(names(df), collapse = " | ")))
    }, ignoreNULL = TRUE)

    # Auto-detected column mapping, used as the initial value of the selects below
    auto_cols <- reactive({
      df <- tbl()
      if (is.null(df)) return(NULL)
      rtg_detect_cols(df)
    })

    output$file_info <- renderUI({
      up <- input$peak_table
      if (is.null(up) || nrow(up) == 0) return(NULL)
      df <- tbl()
      n <- if (is.null(df)) "read failed" else sprintf("%d rows x %d columns", nrow(df), ncol(df))
      div(class = "rtg-meta", sprintf("%s · %s", up$name[1], n))
    })

    # ---------------- Column mapping ----------------
    output$col_map <- renderUI({
      df <- tbl()
      if (is.null(df)) {
        return(div(class = "hint-neutral",
                   icon("circle-info"),
                   span("The four columns are detected automatically once a peak table is uploaded; correct them here.")))
      }
      ac <- auto_cols()
      nm <- names(df)
      pick <- function(id, label, sel) {
        selectInput(session$ns(id), label, choices = nm, selected = sel,
                    width = "100%")
      }
      tagList(
        fluidRow(
          column(6, pick("col_id",     "Peak ID",   ac$names[["id"]])),
          column(6, pick("col_sample", "Sample",    ac$names[["sample"]]))
        ),
        fluidRow(
          column(6, pick("col_mz",     "MZ",        ac$names[["mz"]])),
          column(6, pick("col_rtmin",  "RT_min",    ac$names[["rt_min"]]))
        ),
        if (!isTRUE(ac$auto)) {
          format_hint("Not all column names were recognised automatically; the first four columns are pre-filled, please verify.",
                      "triangle-exclamation", "warning")
        }
      )
    })

    # Column indices after the user has confirmed them
    user_cols <- reactive({
      df <- tbl()
      if (is.null(df)) return(NULL)
      p <- function(x) {
        i <- match(as.character(x), names(df))
        if (is.na(i)) NA_integer_ else i
      }
      idx <- c(id = p(input$col_id), sample = p(input$col_sample),
               mz = p(input$col_mz), rt_min = p(input$col_rtmin))
      if (anyNA(idx)) return(NULL)
      # names must be built item by item by name: subsetting names(df)[idx] drops the names,
      # and the later cols$names[["id"]] lookup would go out of bounds.
      list(id = unname(idx[["id"]]), sample = unname(idx[["sample"]]),
           mz = unname(idx[["mz"]]), rt_min = unname(idx[["rt_min"]]),
           names = c(id     = names(df)[idx[["id"]]],
                     sample = names(df)[idx[["sample"]]],
                     mz     = names(df)[idx[["mz"]]],
                     rt_min = names(df)[idx[["rt_min"]]]),
           auto = TRUE)
    })

    # ---------------- MS1 index cache ----------------
    idx_store <- reactiveVal(list())

    get_index <- function(path) {
      key <- paste0(normalizePath(path, winslash = "/", mustWork = FALSE),
                    "|", as.numeric(file.info(path)$mtime))
      store <- idx_store()
      if (!is.null(store[[key]])) return(store[[key]])

      idx <- rtg_ms1_index(path)

      # Keep the index of only the 4 most recent files so the cache cannot grow without bound
      store[[key]] <- idx
      if (length(store) > 4) store <- store[tail(seq_along(store), 4)]
      idx_store(store)
      idx
    }

    # ---------------- Run results ----------------
    result <- reactiveVal(NULL)
    running <- reactiveVal(FALSE)

    observeEvent(input$run, {

      df <- tbl()
      if (is.null(df)) {
        append_log("❌ Please upload a peak table first.")
        return(invisible(NULL))
      }

      f <- files()
      if (nrow(f) == 0) {
        append_log("❌ The raw data folder is invalid or holds no .raw / .mzML / .mzXML.")
        return(invisible(NULL))
      }

      cols <- user_cols()
      if (is.null(cols)) {
        append_log("❌ The column mapping is incomplete; pick one column for each of the four fields above.")
        return(invisible(NULL))
      }

      tol <- input$tol
      if (is.null(tol) || is.na(tol) || !is.finite(tol) || tol <= 0) {
        append_log("❌ The mass tolerance must be greater than 0.")
        return(invisible(NULL))
      }
      unit <- if (identical(input$tol_unit, "Da")) "Da" else "ppm"

      append_log(sprintf("Start: %d rows | four columns = %s / %s / %s / %s | tolerance %s %s",
                         nrow(df), cols$names[["id"]], cols$names[["sample"]],
                         cols$names[["mz"]], cols$names[["rt_min"]],
                         format(tol, trim = TRUE, scientific = FALSE), unit))

      running(TRUE)
      on.exit(running(FALSE), add = TRUE)

      out <- NULL
      withProgress(message = "RtGeter", detail = "Preparing...", value = 0, {
        pg <- function(done, total, detail = NULL) {
          setProgress(
            value  = if (isTRUE(total > 0)) min(1, done / total) else 0,
            detail = if (is.null(detail)) "" else detail
          )
        }
        # Note: the withProgress expression is evaluated in the **caller's environment**,
        # so a plain assignment is correct here; using <<- would write to a global instead.
        out <- tryCatch(
          rtg_run_batch(df, cols, f, tol, unit, progress = pg),
          error = function(e) {
            append_log(paste("❌ Run failed: ", conditionMessage(e)))
            NULL
          })
      })

      if (is.null(out)) return(invisible(NULL))

      append_log(out$log)
      result(out)
    })

    observeEvent(input$clear, {
      result(NULL)
      log_text("")
    })

    # ---------------- Summary ----------------
    output$summary_box <- renderUI({

      r <- result()
      if (is.null(r)) {
        return(div(class = "status-box status-info",
                   icon("circle-info"),
                   span("Upload a peak table, point to the raw data folder, then click Run.")))
      }

      d <- r$diag
      n <- nrow(d)
      n_ok <- sum(!is.na(d$RT))
      n_win <- sum(d$Status == "empty_window", na.rm = TRUE)
      n_peak <- sum(d$Status == "no_peak", na.rm = TRUE)
      n_smp <- sum(d$Status == "sample_not_found", na.rm = TRUE)
      n_bad <- sum(d$Status %in% c("bad_sample", "bad_mz", "bad_rt_min",
                                   "no_index", "read_error"), na.rm = TRUE)

      pct <- if (n > 0) sprintf("%.1f%%", 100 * n_ok / n) else "—"

      div(class = "rtg-result",
        div(class = "rtg-hero",
          span(class = "rtg-hero__label", "Resolved"),
          span(class = "rtg-hero__value", n_ok),
          span(class = "rtg-hero__unit", sprintf("/ %d rows · %s", n, pct))
        ),
        div(class = "kv-grid",
          div(class = "kv", span(class = "kv__k", "No peak in window"),
              span(class = "kv__v", n_peak)),
          div(class = "kv", span(class = "kv__k", "Empty window"),
              span(class = "kv__v", n_win)),
          div(class = "kv", span(class = "kv__k", "Sample not found"),
              span(class = "kv__v", n_smp)),
          div(class = "kv", span(class = "kv__k", "Bad / unreadable"),
              span(class = "kv__v", n_bad))
        )
      )
    })

    # ---------------- Preview table ----------------
    # The preview carries one extra status column, which makes it easy to locate unresolved rows;
    # the exported file is strictly 'all input columns + RT'.
    preview <- reactive({
      r <- result()
      if (is.null(r)) return(NULL)
      df <- r$result
      chk <- "Status"
      while (chk %in% names(df)) chk <- paste0(chk, "_")
      df[[chk]] <- r$diag$Status
      utils::head(df, 2000)
    })

    output$preview_empty <- renderUI({
      if (!is.null(result())) return(NULL)
      p(class = "text-muted",
        "Results are previewed here after a run. The exported file is 'all input columns + RT', with no diagnostic columns.")
    })

    output$preview <- DT::renderDataTable({
      df <- preview()
      if (is.null(df)) return(NULL)
      rt_col <- if ("RT" %in% names(df)) "RT" else "RT_RtGeter"
      # preview() appends the status column as the last column
      chk <- names(df)[ncol(df)]

      dt <- DT::datatable(
        df,
        rownames = FALSE,
        options = list(pageLength = 15, dom = "tip", scrollX = TRUE),
        class = "compact stripe"
      )
      if (rt_col %in% names(df)) dt <- DT::formatRound(dt, rt_col, 4)
      if (nzchar(chk) && chk %in% names(df)) {
        dt <- DT::formatStyle(
          dt, chk,
          backgroundColor = DT::styleEqual(
            c("ok", "no_peak", "empty_window", "sample_not_found",
              "bad_sample", "bad_mz", "bad_rt_min", "no_index", "read_error"),
            c("#ecfdf5", "#fef2f2", "#fffbeb", "#fef2f2",
              "#fef2f2", "#fef2f2", "#fef2f2", "#fef2f2", "#fef2f2")
          ),
          color = DT::styleEqual(
            c("ok", "no_peak", "empty_window", "sample_not_found",
              "bad_sample", "bad_mz", "bad_rt_min", "no_index", "read_error"),
            c("#0b6b45", "#991b1b", "#92400e", "#991b1b",
              "#991b1b", "#991b1b", "#991b1b", "#991b1b", "#991b1b")
          )
        )
      }
      dt
    })

    # ---------------- Downloads ----------------
    stamp <- function() format(Sys.time(), "%Y%m%d_%H%M%S")

    output$dl_csv <- downloadHandler(
      filename = function() paste0("RtGeter_", stamp(), ".csv"),
      content  = function(file) {
        r <- result(); req(r)
        # Write a temp file first, then prepend the UTF-8 BOM:
        # Excel on Chinese Windows garbles a BOM-less UTF-8 CSV opened by double-click.
        tmp <- tempfile(fileext = ".csv")
        on.exit(unlink(tmp), add = TRUE)
        utils::write.csv(r$result, tmp, row.names = FALSE, na = "",
                         fileEncoding = "UTF-8")
        raw <- readBin(tmp, what = "raw", n = file.size(tmp))
        con <- file(file, open = "wb")
        on.exit(close(con), add = TRUE)
        writeBin(c(as.raw(c(0xEF, 0xBB, 0xBF)), raw), con)
      }
    )

    output$dl_xlsx <- downloadHandler(
      filename = function() paste0("RtGeter_", stamp(), ".xlsx"),
      content  = function(file) {
        r <- result(); req(r)
        writexl::write_xlsx(
          list(Results = r$result, Diagnostics = r$diag), file)
      }
    )
  })
}

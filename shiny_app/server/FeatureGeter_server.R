#FeatureGeter_server.R
# ============================================================
# Unified MS raw-file reading layer
# Supported formats:
#   - Thermo .raw   (via rawrr, requires Thermo RawFileReader .NET library)
#   - .mzML / .mzXML (via mzR; install with BiocManager::install("mzR"))
# All formats are converted into the same internal structure, so the
# downstream analysis pipeline (MS1 cleaning / MS2 export) is identical.
# ============================================================

# Thermo MS1 scan type string (only used for .raw files)
MS1_SCAN_TYPE <- "FTMS - p ESI Full ms [100.0000-1500.0000]"

# ------------------------------------------------------------
# Memory / timing probe (diagnostic only, does not affect results)
# 2026-10-26: one run pushed R to a 16 GB working set, leaving only
# 0.46 GB of free memory; httpuv could no longer send heartbeats and
# the page stayed grey forever. No error shows in the log, because the
# process was only paging, not throwing. This prints gc usage and stage
# timings per sample, so the next run reveals which step blew up.
# ------------------------------------------------------------
mem_probe <- function(tag) {
  g <- tryCatch(gc(verbose = FALSE), error = function(e) NULL)
  used_mb <- if (is.null(g)) NA_real_ else round(sum(g[, 2]), 1)
  message(sprintf("[MEM] %-28s R_heap~%s MB | %s",
                  tag,
                  ifelse(is.na(used_mb), "?", format(used_mb, big.mark = ",")),
                  format(Sys.time(), "%H:%M:%S")))
  invisible(used_mb)
}

# ------------------------------------------------------------
# Spectrum cleaning: keep the highest intensity peak within
# ppm/Da windows (deconvolution), optional noise/topN filtering
# ------------------------------------------------------------
clean_spectrum_keep_max <- function(
    peaks,
    min_mz = -1,
    max_mz = -1,
    noise_threshold = -1,
    min_ms2_difference_in_da = -1,
    min_ms2_difference_in_ppm = -1,
    max_peak_num = -1,
    normalize_intensity = TRUE
){

  peaks <- as.matrix(peaks)

  if(nrow(peaks) == 0){
    return(peaks)
  }

  colnames(peaks) <- c("mz", "intensity")

  #--------------------------------------------------
  # 1. remove invalid peaks
  #--------------------------------------------------
  peaks <- peaks[
    peaks[, "mz"] > 0 &
    peaks[, "intensity"] > 0,
    ,
    drop = FALSE
  ]

  if(nrow(peaks) == 0){
    return(peaks)
  }

  #--------------------------------------------------
  # 2. mz filtering
  #--------------------------------------------------
  if(min_mz > 0){

    peaks <- peaks[
      peaks[, "mz"] >= min_mz,
      ,
      drop = FALSE
    ]
  }

  if(max_mz > 0){

    peaks <- peaks[
      peaks[, "mz"] <= max_mz,
      ,
      drop = FALSE
    ]
  }

  if(nrow(peaks) == 0){
    return(peaks)
  }

  #--------------------------------------------------
  # 3. centroiding
  # keep only highest intensity peak
  #--------------------------------------------------
  if(min_ms2_difference_in_da > 0 &&
     min_ms2_difference_in_ppm > 0){

    stop("Only one of min_ms2_difference_in_da and min_ms2_difference_in_ppm can be positive.")
  }

  if(min_ms2_difference_in_da > 0 ||
     min_ms2_difference_in_ppm > 0){

    # sort by mz
    peaks <- peaks[
      order(peaks[, "mz"]),
      ,
      drop = FALSE
    ]

    keep_idx <- c()

    i <- 1

    while(i <= nrow(peaks)){

      group <- i

      j <- i + 1

      while(j <= nrow(peaks)){

        #--------------------------------------------------
        # IMPORTANT:
        # use group anchor mz instead of chain comparison
        #--------------------------------------------------
        mz1 <- peaks[group[1], "mz"]

        mz2 <- peaks[j, "mz"]

        diff_ok <- FALSE

        #---------------------------
        # Da mode
        #---------------------------
        if(min_ms2_difference_in_da > 0){

          diff_ok <- abs(mz2 - mz1) <
            min_ms2_difference_in_da
        }

        #---------------------------
        # ppm mode
        #---------------------------
        if(min_ms2_difference_in_ppm > 0){

          ppm_diff <- abs(mz2 - mz1) /
            mz1 * 1e6

          diff_ok <- ppm_diff <
            min_ms2_difference_in_ppm
        }

        if(diff_ok){

          group <- c(group, j)

          j <- j + 1

        } else {

          break
        }
      }

      #--------------------------------------------------
      # keep highest intensity peak
      #--------------------------------------------------
      max_idx <- group[
        which.max(peaks[group, "intensity"])
      ]

      keep_idx <- c(keep_idx, max_idx)

      i <- j
    }

    peaks <- peaks[
      keep_idx,
      ,
      drop = FALSE
    ]
  }

  if(nrow(peaks) == 0){
    return(peaks)
  }

  #--------------------------------------------------
  # 4. noise filtering
  #--------------------------------------------------
  if(noise_threshold > 0){

    max_int <- max(peaks[, "intensity"])

    peaks <- peaks[
      peaks[, "intensity"] >=
        noise_threshold * max_int,
      ,
      drop = FALSE
    ]
  }

  if(nrow(peaks) == 0){
    return(peaks)
  }

  #--------------------------------------------------
  # 5. keep top N peaks
  #--------------------------------------------------
  if(max_peak_num > 0 &&
     nrow(peaks) > max_peak_num){

    ord <- order(
      peaks[, "intensity"],
      decreasing = TRUE
    )

    peaks <- peaks[
      ord[1:max_peak_num],
      ,
      drop = FALSE
    ]
  }

  #--------------------------------------------------
  # 6. normalize intensity
  #--------------------------------------------------
  if(normalize_intensity){

    s <- sum(peaks[, "intensity"])

    if(s > 0){

      peaks[, "intensity"] <-
        peaks[, "intensity"] / s
    }
  }

  #--------------------------------------------------
  # 7. sort by mz
  #--------------------------------------------------
  peaks <- peaks[
    order(peaks[, "mz"]),
    ,
    drop = FALSE
  ]

  rownames(peaks) <- NULL

  return(peaks)
}

# ------------------------------------------------------------
# Heuristic: does a peak list look like profile data?
# Centroided spectra have few, widely spaced peaks;
# profile spectra have many, densely spaced points.
# ------------------------------------------------------------
looks_like_profile <- function(mz) {

  if (length(mz) < 20) return(FALSE)

  d <- diff(sort(mz))
  d <- d[d > 0]

  if (length(d) < 5) return(FALSE)

  stats::median(d) < 0.005
}

# ------------------------------------------------------------
# Collapse profile peak list into centroid-like peaks:
# keep the apex point of each profile peak cluster
# (anchor window = the ppm setting chosen in the UI)
# ------------------------------------------------------------
centroid_profile_peaks <- function(mz, intensity, ppm = 10) {

  if (length(mz) == 0) {
    return(list(mz = numeric(), intensity = numeric()))
  }

  res <- clean_spectrum_keep_max(
    cbind(mz, intensity),
    min_mz = 0,
    max_mz = 1500,
    noise_threshold = 0,
    min_ms2_difference_in_da = -1,
    min_ms2_difference_in_ppm = ppm,
    max_peak_num = -1,
    normalize_intensity = FALSE
  )

  if (nrow(res) == 0) {
    return(list(mz = numeric(), intensity = numeric()))
  }

  list(
    mz = as.numeric(res[, "mz"]),
    intensity = as.numeric(res[, "intensity"])
  )
}

# ------------------------------------------------------------
# Infer IONMODE string from mzR polarity values
# (1 = positive, -1 = negative; NA / unknown -> "Negative",
#  which matches the original hardcoded behaviour)
# ------------------------------------------------------------
infer_ion_mode <- function(polarity_vec) {

  if (is.null(polarity_vec) || length(polarity_vec) == 0) return("Negative")

  if (is.character(polarity_vec)) {
    p <- tolower(polarity_vec)
    if (all(p %in% c("negative", "neg", "-"))) return("Negative")
    if (all(p %in% c("positive", "pos", "+"))) return("Positive")
    return("Negative")
  }

  p <- suppressWarnings(as.numeric(polarity_vec))
  p <- p[!is.na(p)]

  if (length(p) == 0) return("Negative")
  if (all(p < 0)) return("Negative")
  if (all(p > 0)) return("Positive")

  "Negative"
}

# ------------------------------------------------------------
# Read one MS file (.raw / .mzML / .mzXML) into a unified structure:
#   $scan_table : data.frame(scan, StartTime [minutes], scanType,
#                            msLevel, ms2_value [precursor m/z])
#   $spectra    : named list, names = scan numbers,
#                 each element = list(mz, intensity) [centroided peaks]
#   $ion_mode   : "Negative" / "Positive"
# ------------------------------------------------------------
read_ms_file <- function(filepath, ppm = 10) {

  ext <- tolower(tools::file_ext(filepath))

  if (identical(ext, "raw")) {

    # ---------------- Thermo .raw (rawrr) ----------------
    # 2026-10-26: the original code used rawrr::readSpectrum(scan = 1:N, mode="profile")
    # and read every scan in one go. Each rawrr scan object carries both the profile
    # array (mZ, ~28,112 points for SA1.raw) and the centroid stream (centroid.mZ,
    # ~1,809 points): 444 KB per scan; 12,470 scans = 5.4 GB, then copied into the
    # spectra list and converted to data.frame. Measured: R grew to 22 GB, system
    # memory ran out and the page stayed grey forever.
    # Now reads in chunks of 200 scans, keeping only the centroid array:
    # ~0.3 GB resident per file, with identical results (the original only ever
    # took the centroid array as well).
    # 2026-10-26: msLevel used to be decided by strict equality between scanType and
    # the constant MS1_SCAN_TYPE ("FTMS - p ESI ...", negative mode); positive-mode
    # files read "FTMS + p ESI ...", so every comparison failed -> all 12,470 scans of
    # SA1.raw were taken as MS2, the MS1 branch got nothing, and
    # "argument is of length zero" was triggered.
    # Now the MSOrder from the index is authoritative ("Ms" = MS1), true for both
    # ion modes.
    idx <- rawrr::readIndex(filepath)
    n_scans <- nrow(idx)
    if (is.null(n_scans) || n_scans < 1L) {
      stop("Cannot read the scan index (file may be corrupt or not a valid .raw): ", basename(filepath))
    }

    chunk <- 200L
    starts <- seq.int(1L, n_scans, by = chunk)
    scan_vec <- as.numeric(idx$scan)
    # rawrr versions differ in index column names: the newer one gives StartTime
    # (already in minutes), the older one gives RT (seconds). Adapt by column name
    # so the whole table does not end up with 0 rows.
    st_vec <- if ("StartTime" %in% names(idx)) {
      as.numeric(idx$StartTime)
    } else {
      as.numeric(idx$RT) / 60
    }
    type_vec <- if ("scanType" %in% names(idx)) {
      as.character(idx$scanType)
    } else {
      rep(NA_character_, n_scans)
    }
    ms_order <- if ("MSOrder" %in% names(idx)) as.character(idx$MSOrder) else NULL
    prec_idx <- if ("precursorMass" %in% names(idx)) as.numeric(idx$precursorMass) else NULL
    spectra  <- vector("list", n_scans)
    pos <- 0L

    for (s0 in starts) {
      ids <- scan_vec[s0:min(s0 + chunk - 1L, n_scans)]
      S <- rawrr::readSpectrum(rawfile = filepath, scan = ids, mode = "centroid")
      for (x in S) {
        pos <- pos + 1L
        mz <- x[["centroid.mZ"]]
        it <- x[["centroid.intensity"]]
        # a few scans have no centroid stream: fall back to the profile array so
        # the whole spectrum is not lost
        if (is.null(mz) || length(mz) == 0L) {
          mz <- x[["mZ"]]
          it <- x[["intensity"]]
        }
        spectra[[pos]] <- list(mz = as.numeric(mz), intensity = as.numeric(it))
      }
      rm(S)
      invisible(gc(verbose = FALSE))
    }

    if (pos < n_scans) {
      scan_vec <- scan_vec[seq_len(pos)]
      st_vec   <- st_vec[seq_len(pos)]
      type_vec <- type_vec[seq_len(pos)]
      spectra  <- spectra[seq_len(pos)]
    }

    # MS1 / MS2 decided by the index MSOrder (holds for both ion modes)
    ms_level <- if (is.null(ms_order)) {
      ifelse(type_vec == MS1_SCAN_TYPE, 1L, 2L)
    } else {
      ifelse(ms_order[seq_len(pos)] == "Ms", 1L, 2L)
    }

    # precursor m/z: prefer precursorMass from the index, fall back to the
    # scan-type string when it is missing
    ms2_value <- if (!is.null(prec_idx)) {
      v <- prec_idx[seq_len(pos)]
      v[!is.na(v) & v <= 0] <- NA_real_
      v
    } else {
      as.numeric(stringr::str_extract(type_vec, "(?<=ms2\\s)[^@]+"))
    }

    scan_table <- data.frame(
      scan = scan_vec,
      StartTime = st_vec,
      scanType = type_vec,
      msLevel = ms_level,
      ms2_value = ms2_value,
      stringsAsFactors = FALSE
    )

    names(spectra) <- as.character(scan_vec)

    # original behaviour: Thermo files were always written as Negative
    return(list(scan_table = scan_table, spectra = spectra, ion_mode = "Negative"))
  }

  if (ext %in% c("mzml", "mzxml")) {

    # ---------------- mzML / mzXML (mzR) ----------------
    if (!requireNamespace("mzR", quietly = TRUE)) {
      stop(
        "Reading .mzML/.mzXML files requires the mzR package; ",
        "please run in R: BiocManager::install(\"mzR\")"
      )
    }

    ms <- mzR::openMSfile(filepath)
    on.exit(mzR::close(ms), add = TRUE)

    hdr <- mzR::header(ms)
    n <- nrow(hdr)

    scan_vec <- as.numeric(hdr$seqNum)
    st_vec   <- as.numeric(hdr$retentionTime) / 60  # seconds -> minutes
    ms_level <- as.integer(hdr$msLevel)
    prec_mz  <- as.numeric(hdr$precursorMZ)

    ms2_value <- ifelse(!is.na(prec_mz) & prec_mz > 0, prec_mz, NA_real_)

    type_vec <- ifelse(
      ms_level >= 2,
      paste0("ms2 ", round(ms2_value, 4)),
      "ms1"
    )

    scan_table <- data.frame(
      scan = scan_vec,
      StartTime = st_vec,
      scanType = type_vec,
      msLevel = ms_level,
      ms2_value = ms2_value,
      stringsAsFactors = FALSE
    )

    ion_mode <- infer_ion_mode(hdr$polarity)

    # read peak lists; centroid profile data on the fly
    spectra <- vector("list", n)
    names(spectra) <- as.character(scan_vec)

    for (i in seq_len(n)) {

      p <- mzR::peaks(ms, i)

      mz_i  <- as.numeric(p[, 1])
      int_i <- as.numeric(p[, 2])

      if (looks_like_profile(mz_i)) {
        cp <- centroid_profile_peaks(mz_i, int_i, ppm = ppm)
        mz_i  <- cp$mz
        int_i <- cp$intensity
      }

      spectra[[i]] <- list(mz = mz_i, intensity = int_i)
    }

    return(list(scan_table = scan_table, spectra = spectra, ion_mode = ion_mode))
  }

  stop("Unsupported mass-spec file format: .", ext, " (supported: .raw / .mzML / .mzXML)")
}

# ============================================================
# FeatureGeter module (Ms1Geter)
# ============================================================
FeatureGeter_server <- function(id){

  moduleServer(id, function(input, output, session){

  log_text <- reactiveVal("")
  append_log <- function(msg) {
    new_log <- paste0(log_text(), format(Sys.time(), "[%H:%M:%S] "), msg, "\n")
    log_text(new_log)
  }

  output$log <- renderText(log_text())

  observeEvent(input$run, {
    req(input$workdir)
    workdir <- input$workdir
    setwd(workdir)
    append_log(paste("Working directory set to: ", workdir))

    # ----------------------------------------------------------
    # Effective retention-time range (minutes) -- the UI value is
    # "acquisition time", not the output RT.
    #
    # Output RT is defined as the right edge of a one-minute bin: RT = bin + 1,
    # and a bin covers (bin, bin+1]. So a user entry of 1-10 min lands on bins
    # 1..10 and the output RT is 2-11. The default 1-18 -> RT 2-19, equivalent to
    # the previous hardcoded keep_rt <- 1:18.
    rt_min_v <- suppressWarnings(as.numeric(input$rt_min))
    rt_max_v <- suppressWarnings(as.numeric(input$rt_max))
    if (is.na(rt_min_v)) rt_min_v <- 1
    if (is.na(rt_max_v)) rt_max_v <- 18
    if (rt_max_v < rt_min_v) {
      append_log(paste0("Invalid RT range (max < min); swapped to: ",
                        rt_min_v, " - ", rt_max_v))
      tmp <- rt_min_v; rt_min_v <- rt_max_v; rt_max_v <- tmp
    }
    # bin = the integer minute clipped from the range; only bin + 1 is written
    # into the RT column.
    bin_from <- as.integer(ceiling(rt_min_v))
    bin_to   <- as.integer(floor(rt_max_v))
    append_log(sprintf("Effective RT %.1f - %.1f min -> output RT recorded as %d - %d min",
                       rt_min_v, rt_max_v, bin_from + 1L, bin_to + 1L))

    # ----------------------------------------------------------
    # Minimum peak intensity. Applied after deconvolution (take the strongest
    # peak per ppm window) and before binning by RT; peaks below it are dropped.
    # Default 10000, exactly matching the previous hardcoded
    # cleaned_df$intensity > 10000; lowering it buys more low-abundance ions
    # (higher detection rate, but quantitative noise comes in with them).
    min_int_v <- suppressWarnings(as.numeric(input$min_intensity))
    if (is.na(min_int_v) || min_int_v < 0) min_int_v <- 10000
    append_log(sprintf("Minimum peak intensity: %.0f (peaks not above this intensity are dropped after deconvolution)", min_int_v))

    # ----------------------------------------------------------
    # Deconvolution window (relative mass tolerance, ppm). All peaks piled up in
    # the same one-minute bin are clustered by this window and only the strongest
    # one per cluster is kept. The default 10 ppm matches the previous hardcoded
    # min_ms2_difference_in_ppm = 10; a wider window merges more aggressively, so
    # it removes near-duplicate rows of the same ion but may also merge two ions
    # that are genuinely separate. The UI limits it to 5-30 ppm in steps of 5;
    # this adds one more fallback that clamps out-of-range values and rounds
    # non-multiples to the nearest, so the effective window is only 5/10/15/20/25/30.
    ppm_v <- suppressWarnings(as.numeric(input$ppm_tol))
    if (is.na(ppm_v)) ppm_v <- 10
    ppm_eff <- min(max(round(ppm_v / 5) * 5, 5), 30)
    if (!isTRUE(all.equal(ppm_eff, ppm_v))) {
      append_log(sprintf("Deconvolution window %.1f ppm is not 5-30 / step 5; using %.0f ppm",
                         ppm_v, ppm_eff))
    }
    ppm_v <- ppm_eff
    append_log(sprintf("Deconvolution window: %.0f ppm (cluster within a bin at this relative mass tolerance, keep the strongest per cluster)", ppm_v))

    # ----------------------------------------------------------
    # Progress bar (not decoration -- it is the keep-alive mechanism)
    # The whole pipeline lives in one observeEvent, i.e. a single synchronous
    # call running for tens of seconds up to minutes. Every prog$set() hands
    # control back to the event loop once, which is the only chance for httpuv
    # to send a SockJS heartbeat (the client greys out after 25 s without one).
    # Without Progress the page inevitably greys out after ~25 s, and R never
    # notices.
    # ----------------------------------------------------------
    prog <- shiny::Progress$new(session, min = 0, max = 1)
    on.exit(prog$close(), add = TRUE)
    prog$set(value = 0, message = "MSGeter", detail = "Reading sample groups...")

    #-----------------------------------------------------------
    # 1. Read the sample group file
    #-----------------------------------------------------------
    req(input$sample_file)
    file_path <- input$sample_file$datapath

    if (grepl("\\.csv$", input$sample_file$name, ignore.case = TRUE)) {
      sample_info <- read.csv(file_path, stringsAsFactors = FALSE)
    } else if (grepl("\\.xlsx$", input$sample_file$name, ignore.case = TRUE)) {
      sample_info <- read_excel(file_path)
    } else {
      append_log("❌ Unsupported file format (only .csv or .xlsx)")
      return(NULL)
    }

    if (!all(c("Sample", "Group") %in% names(sample_info))) {
      append_log("❌ The file must contain the columns: Sample and Group")
      return(NULL)
    }

    append_log("✅ Sample group file loaded")
    append_log(paste("Groups detected: ", paste(unique(sample_info$Group), collapse = ", ")))

    #-----------------------------------------------------------
    # 2. Process the mass-spec files (.raw / .mzML / .mzXML)
    #-----------------------------------------------------------
    ms_files <- list.files(
      path = workdir,
      pattern = "\\.(raw|mzml|mzxml)$",
      full.names = TRUE,
      ignore.case = TRUE
    )
    if (length(ms_files) == 0) {
      append_log("No .raw / .mzML / .mzXML files found.")
      return(NULL)
    }

    append_log(paste("Detected", length(ms_files), "mass-spec files (.raw/.mzML/.mzXML)."))
    all_samples_data <- list()
    all_ms2_data <- list()
    ion_modes <- list()

    # MGF is no longer written only after all 20 samples have been read. Each
    # file is flushed to disk as soon as it is processed, and the full spectra
    # of that sample are released right after. The old all_S kept every
    # spectrum of every raw file resident (measured peak 6.2 GB for 20
    # samples), while its only use was writing MGF at the very end, so there
    # was no reason to hold on to it.
    msp_dir <- "MS2_MGF"
    dir.create(msp_dir, showWarnings = FALSE)
    n_files <- length(ms_files)

    for (k in seq_along(ms_files)) {
      msfile <- ms_files[k]
      append_log(paste0("Processing (", k, "/", n_files, "): ", basename(msfile)))
      sample_id <- file_path_sans_ext(basename(msfile))
      prog$set(
        value  = 0.80 * (k - 1) / n_files,
        detail = sprintf("Reading %d/%d: %s", k, n_files, sample_id)
      )

      # guard: same sample name present in more than one format
      # (e.g. both P173.raw and P173.mzML) -> keep the first, skip the rest
      if (sample_id %in% names(all_ms2_data)) {
        append_log(paste("⚠️ Sample", sample_id,
                         "was already processed from a file in another format; skipping:", basename(msfile)))
        next
      }

      ms <- read_ms_file(msfile, ppm = ppm_v)
      st <- ms$scan_table
      spectra <- ms$spectra
      ion_modes[[sample_id]] <- ms$ion_mode
      mem_probe(sprintf("%d/%d %s read (%d scans, %.1f MB file)", k, n_files,
                        sample_id, nrow(st),
                        file.size(msfile) / 1024^2))
      prog$set(detail = sprintf("Parsing %d/%d: %s", k, n_files, sample_id))

      # ---------------- MS2 scan info table ----------------
      i_ms2 <- st %>%
        filter(msLevel == 2) %>%
        arrange(ms2_value) %>%
        mutate(
          group = {
            ms2_value_vec <- ms2_value
            groups <- numeric(length(ms2_value_vec))
            current_group <- 1
            # guard: precursor m/z can be NA (missing precursor in mzML/MSE
            # scans). NA breaks `if (v > threshold)` -> whole observer dies
            # and the browser shows the gray disconnected overlay.
            # Skip NA scans (keep them in the current group); seed the
            # threshold from the first non-NA precursor.
            first_valid <- which(!is.na(ms2_value_vec))
            threshold <- if (length(first_valid)) {
              ms2_value_vec[first_valid[1]] + 0.9
            } else {
              Inf
            }
            for (i in seq_along(ms2_value_vec)) {
              v <- ms2_value_vec[i]
              if (!is.na(v) && v > threshold) {
                current_group <- current_group + 1
                threshold <- v + 0.9
              }
              groups[i] <- current_group
            }
            groups
          },
          Sample = sample_id
        ) %>%
        select(scan, StartTime, scanType, ms2_value, group, Sample)

      all_ms2_data[[sample_id]] <- i_ms2

      # ---------------- MS1 data extraction and cleaning ----------------
      # The original code called bind_rows once per scan, i.e. copied the table
      # already accumulated for that minute in full; 40,000 scans meant O(n^2)
      # copying and GC pressure (measured: one sample pushed R to 16 GB and
      # burned 54 minutes of CPU). Now: "one list per minute, a single
      # bind_rows at the end" -- identical results, copying down to O(n).
      merged_chunks <- list()
      for (i in seq_len(nrow(st))) {
        if (st$msLevel[i] != 1) next
        spec <- spectra[[as.character(st$scan[i])]]
        if (is.null(spec) || is.null(spec$mz) || length(spec$mz) == 0) next
        minute_label <- floor(as.numeric(st$StartTime[i]))
        label <- as.character(minute_label)
        # rt_scan: which scan this centroid came from (minutes, sub-minute
        # precision). Deconvolution only subsets rows, so the peak it keeps
        # naturally carries the RT of the scan it belongs to -- that is where
        # RT_apex comes from, with no second read of the spectra (same
        # convention as msg-extract in the CLI).
        df <- data.frame(mz = spec$mz, intensity = spec$intensity,
                         rt_scan = as.numeric(st$StartTime[i]))
        merged_chunks[[label]][[length(merged_chunks[[label]]) + 1L]] <- df
      }
      merged_centroids <- lapply(merged_chunks, function(lst) dplyr::bind_rows(lst))
      rm(merged_chunks)

      cleaned_centroids <- list()
      for (label in names(merged_centroids)) {
        peaks <- merged_centroids[[label]]
        if (nrow(peaks) >= 2) {
          # Deconvolution only understands the mz / intensity columns (the
          # function overwrites the column names), so feed it just those two and
          # then join rt_scan back by (mz, intensity).
          cleaned_mat <- clean_spectrum_keep_max(
            as.matrix(peaks[, c("mz", "intensity")]),
            min_mz = 0,
            max_mz = 1500,
            noise_threshold = 0,
            min_ms2_difference_in_da = -1,
            min_ms2_difference_in_ppm = ppm_v,
            max_peak_num = -1,
            normalize_intensity = FALSE
          )
          cleaned_df <- as.data.frame(cleaned_mat)
          colnames(cleaned_df) <- c("mz", "intensity")
          cleaned_df <- cleaned_df[cleaned_df$intensity > min_int_v, ]
          # RT_apex: retention time of the scan that owns the strongest peak in
          # the cluster (minutes, sub-minute precision). If rows with an identical
          # (mz, intensity) repeat within the same one-minute bin, the first scan
          # wins -- they are all in the same bin anyway, so the worst case falls
          # back to whole-minute resolution.
          if (nrow(cleaned_df) > 0L) {
            key_out <- paste(cleaned_df$mz, cleaned_df$intensity, sep = "|")
            key_in  <- paste(peaks$mz, peaks$intensity, sep = "|")
            idx <- match(key_out, key_in)
            cleaned_df$RT_apex <- peaks$rt_scan[idx]
          } else {
            cleaned_df$RT_apex <- numeric(0)
          }
          cleaned_df$RT <- as.numeric(label) + 1
          cleaned_centroids[[label]] <- cleaned_df
        }
      }

      # Keep only the one-minute bins whose bin number lies in [bin_from, bin_to].
      # Bin n writes n+1 into the RT column, so an acquisition range of 1-10 min
      # outputs RT 2-11.
      keep_bins <- if (bin_to < bin_from) integer(0) else {
        intersect(bin_from:bin_to, as.integer(names(cleaned_centroids)))
      }
      keep_rt <- as.character(sort(keep_bins))
      subset_cleaned <- do.call(rbind, cleaned_centroids[keep_rt])
      mem_probe(sprintf("%d/%d %s deconvolved (%d minute bins, %d peaks)",
                        k, n_files, sample_id,
                        length(merged_centroids),
                        if (is.null(subset_cleaned)) 0L else nrow(subset_cleaned)))

      # When the selected RT range contains no bin at all, do.call(rbind, list(NULL,...))
      # returns NULL, so the old `if (nrow(subset_cleaned) > 0)` received logical(0)
      # and threw "argument is of length zero", crashing the whole observer.
      if (!is.null(subset_cleaned) && nrow(subset_cleaned) > 0) {
        subset_cleaned$mz <- round(subset_cleaned$mz, 4)
        subset_cleaned$intensity <- round(subset_cleaned$intensity, 0)
        subset_cleaned$RT_mz <- as.numeric(paste0(subset_cleaned$RT, sprintf("%.4f", subset_cleaned$mz)))
        subset_cleaned$Sample <- sample_id
        if (!"RT_apex" %in% colnames(subset_cleaned)) {
          subset_cleaned$RT_apex <- NA_real_
        }
        subset_cleaned$RT_apex <- round(subset_cleaned$RT_apex, 4)
        # Column order = msg-extract output of the CLI (6 columns including
        # RT_apex). In the xlsx each block is 6 columns + 1 empty column = block
        # width 7, which dmf_read_samples detects automatically.
        subset_cleaned <- subset_cleaned %>% select(Sample, RT, RT_mz, mz, intensity, RT_apex)
      } else {
        subset_cleaned <- data.frame(Sample = sample_id, RT = numeric(),
                                     RT_mz = character(), mz = numeric(),
                                     intensity = numeric(), RT_apex = numeric())
      }

      all_samples_data[[sample_id]] <- subset_cleaned

      # ---------------- Write MGF immediately, then release the spectra ----------------
      sample_ion_mode <- ion_modes[[sample_id]]
      ms2_df <- all_ms2_data[[sample_id]]
      mgf_chunks <- vector("list", nrow(ms2_df))

      for (i in seq_len(nrow(ms2_df))) {
        scan_num <- ms2_df$scan[i]
        spec <- spectra[[as.character(scan_num)]]
        if (is.null(spec) || is.null(spec$mz) || is.null(spec$intensity)) next

        mgf_chunks[[i]] <- c(
          paste0("NAME:", sample_id, "_scan", scan_num),
          paste0("PRECURSORMZ:", round(ms2_df$ms2_value[i], 4)),
          paste0("IONMODE: ", sample_ion_mode),
          paste0("RETENTIONTIME:", round(ms2_df$StartTime[i], 2)),
          paste0("Num Peaks: ", length(spec$mz)),
          paste(apply(cbind(spec$mz, spec$intensity), 1, paste, collapse = " "),
                collapse = "\n"),
          ""
        )
      }

      # With no MS2 spectrum unlist yields NULL and writeLines(NULL) errors out,
      # so degrade explicitly to an empty character vector (an empty .msp is
      # written, matching the original behaviour)
      mgf_text <- unlist(mgf_chunks, use.names = FALSE)
      if (is.null(mgf_text)) mgf_text <- character(0)
      writeLines(mgf_text, file.path(msp_dir, paste0(sample_id, ".msp")))

      # Spectra and deconvolution intermediates are the largest objects of each
      # round, so release them right after the MGF is written; otherwise the
      # peaks of 20 samples stack up to several GB in the final phase.
      rm(ms, st, spectra, merged_centroids, cleaned_centroids,
         mgf_chunks, ms2_df)
      gc(verbose = FALSE)
      mem_probe(sprintf("%d/%d %s released", k, n_files, sample_id))

      prog$set(value = 0.80 * k / n_files)
    }

    #-----------------------------------------------------------
    # 3. Export results
    #-----------------------------------------------------------
    prog$set(value = 0.82, detail = "Exporting MS2_Group_Info.csv")
    if (length(all_ms2_data) > 0) {
      combined_ms2 <- do.call(rbind, all_ms2_data)
      write.csv(combined_ms2, "MS2_Group_Info.csv", row.names = FALSE)
      append_log("✅ Exported MS2_Group_Info.csv")
      rm(combined_ms2)
    } else {
      append_log("⚠️ No MS2 scan info to export; skipping MS2_Group_Info.csv")
    }
    append_log(paste0("✅ Wrote ", length(ion_modes), " MGF files to ", msp_dir, "/"))



    # (MGF is already written per sample inside the main loop, no second pass here)




    # ----------------------------------------------------------
    # The Sample column of Clean_MS1_Data_Group*.xlsx must be pure digits.
    # Downstream dmf_read_samples() runs as.numeric() on the first row of each
    # sample block (6 data columns + 1 empty column = block width 7) and gets NA
    # for "P173"; the column then looks empty and it reports "no sample numbers in
    # the first row". Only the output value of this column changes: the keys of
    # all_samples_data (= file names) stay as they are, and the NAME field in
    # MS2_Group_Info.csv and MGF is still the original file name for traceability.
    # Take the "first run of digits": P173 -> 173, Sample_07 -> 07 (leading zero kept).
    # ----------------------------------------------------------
    num_from_id <- function(id) {
      m <- regmatches(id, regexpr("[0-9]+", id))
      if (length(m) == 0L) NA_character_ else m[1]
    }
    sample_num <- vapply(names(all_samples_data), num_from_id,
                         character(1), USE.NAMES = TRUE)

    no_digit <- names(sample_num)[is.na(sample_num)]
    if (length(no_digit) > 0L) {
      append_log(paste("⚠️ No digits found in these sample names, the blocks keep the original name:",
                       paste(no_digit, collapse = ", ")))
    }
    good_num <- sample_num[!is.na(sample_num)]
    dup_num <- unique(good_num[duplicated(good_num)])
    if (length(dup_num) > 0L) {
      append_log(paste("⚠️ Duplicate numbers after conversion to digits, downstream will be confused:",
                       paste(dup_num, collapse = ", ")))
    }

    # Export the cleaned MS1 data, written group by group
    groups <- unique(sample_info$Group)
    for (gi in seq_along(groups)) {
      grp <- groups[gi]
      prog$set(
        value  = 0.85 + 0.14 * (gi - 1) / length(groups),
        detail = sprintf("Writing Excel %d/%d: Group %s", gi, length(groups), grp)
      )
      grp_samples <- sample_info %>% filter(Group == grp) %>% pull(Sample)
      wb <- createWorkbook()
      addWorksheet(wb, paste0("Group_", grp, "_MS1"))
      col_start <- 1
      written <- character(0)
      for (sample_id in grp_samples) {
        if (!sample_id %in% names(all_samples_data)) next
        df <- all_samples_data[[sample_id]]
        nid <- sample_num[[sample_id]]
        if (!is.na(nid) && nrow(df) > 0L) df$Sample <- rep(nid, nrow(df))
        written <- c(written, if (is.na(nid)) sample_id else nid)
        writeData(wb, 1, df, startCol = col_start, startRow = 1)
        col_start <- col_start + ncol(df) + 1
      }
      out_file <- paste0("Clean_MS1_Data_Group", grp, ".xlsx")
      saveWorkbook(wb, out_file, overwrite = TRUE)
      append_log(paste0("✅ Saved ", out_file, " (sample numbers: ",
                        paste(written, collapse = ", "), ")"))
      # the openxlsx workbook still holds the whole sheet after saving, so drop it per group
      rm(wb); gc(verbose = FALSE)
    }

    prog$set(value = 1, detail = "Done")
    output_files <- list.files(workdir, full.names = TRUE, recursive = TRUE)
    output$output_files <- renderTable({
      data.frame(
        File = basename(output_files),
        Path = normalizePath(output_files)
      )
    })

    append_log("🎉 All steps complete!")
  })
})
}

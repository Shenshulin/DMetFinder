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
# (20 ppm anchor window)
# ------------------------------------------------------------
centroid_profile_peaks <- function(mz, intensity) {

  if (length(mz) == 0) {
    return(list(mz = numeric(), intensity = numeric()))
  }

  res <- clean_spectrum_keep_max(
    cbind(mz, intensity),
    min_mz = 0,
    max_mz = 1500,
    noise_threshold = 0,
    min_ms2_difference_in_da = -1,
    min_ms2_difference_in_ppm = 20,
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
read_ms_file <- function(filepath) {

  ext <- tolower(tools::file_ext(filepath))

  if (identical(ext, "raw")) {

    # ---------------- Thermo .raw (rawrr) ----------------
    H <- rawrr::readFileHeader(rawfile = filepath)
    S <- rawrr::readSpectrum(
      rawfile = filepath,
      scan = 1:H[["Number of scans"]],
      mode = "profile"
    )

    n <- length(S)

    # rawrr returns scan numbers as doubles; keep them as-is so that
    # downstream output formatting matches the original implementation
    scan_vec   <- vapply(S, function(x) as.numeric(x[["scan"]]), numeric(1))
    st_vec     <- vapply(S, function(x) x[["StartTime"]], numeric(1))  # minutes
    type_vec   <- vapply(S, function(x) x[["scanType"]], character(1))

    # MS1 = the specific Thermo MS1 scan type, everything else = MS2
    # (identical to the original scanType != MS1_SCAN_TYPE logic)
    ms_level <- ifelse(type_vec == MS1_SCAN_TYPE, 1L, 2L)

    # precursor m/z parsed from the Thermo scan type string
    ms2_value <- as.numeric(
      stringr::str_extract(type_vec, "(?<=ms2\\s)[^@]+")
    )

    scan_table <- data.frame(
      scan = scan_vec,
      StartTime = st_vec,
      scanType = type_vec,
      msLevel = ms_level,
      ms2_value = ms2_value,
      stringsAsFactors = FALSE
    )

    spectra <- lapply(S, function(x) {
      list(
        mz = x[["centroid.mZ"]],
        intensity = x[["centroid.intensity"]]
      )
    })
    names(spectra) <- as.character(scan_vec)

    # original behaviour: Thermo files were always written as Negative
    return(list(scan_table = scan_table, spectra = spectra, ion_mode = "Negative"))
  }

  if (ext %in% c("mzml", "mzxml")) {

    # ---------------- mzML / mzXML (mzR) ----------------
    if (!requireNamespace("mzR", quietly = TRUE)) {
      stop(
        "处理 .mzML/.mzXML 文件需要 mzR 包，",
        "请在 R 中运行: BiocManager::install(\"mzR\")"
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
        cp <- centroid_profile_peaks(mz_i, int_i)
        mz_i  <- cp$mz
        int_i <- cp$intensity
      }

      spectra[[i]] <- list(mz = mz_i, intensity = int_i)
    }

    return(list(scan_table = scan_table, spectra = spectra, ion_mode = ion_mode))
  }

  stop("不支持的质谱文件格式: .", ext, "（支持 .raw / .mzML / .mzXML）")
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
    append_log(paste("工作目录设置为：", workdir))

    #-----------------------------------------------------------
    # 1. 读取样本分组文件
    #-----------------------------------------------------------
    req(input$sample_file)
    file_path <- input$sample_file$datapath

    if (grepl("\\.csv$", input$sample_file$name, ignore.case = TRUE)) {
      sample_info <- read.csv(file_path, stringsAsFactors = FALSE)
    } else if (grepl("\\.xlsx$", input$sample_file$name, ignore.case = TRUE)) {
      sample_info <- read_excel(file_path)
    } else {
      append_log("❌ 不支持的文件格式（仅支持 .csv 或 .xlsx）")
      return(NULL)
    }

    if (!all(c("Sample", "Group") %in% names(sample_info))) {
      append_log("❌ 文件必须包含列名：Sample 和 Group")
      return(NULL)
    }

    append_log("✅ 样本分组文件已读取")
    append_log(paste("检测到分组：", paste(unique(sample_info$Group), collapse = ", ")))

    #-----------------------------------------------------------
    # 2. 处理质谱文件（.raw / .mzML / .mzXML）
    #-----------------------------------------------------------
    ms_files <- list.files(
      path = workdir,
      pattern = "\\.(raw|mzml|mzxml)$",
      full.names = TRUE,
      ignore.case = TRUE
    )
    if (length(ms_files) == 0) {
      append_log("未找到任何 .raw / .mzML / .mzXML 文件。")
      return(NULL)
    }

    append_log(paste("检测到", length(ms_files), "个质谱文件（.raw/.mzML/.mzXML）。"))
    all_samples_data <- list()
    all_ms2_data <- list()
    all_S <- list()
    ion_modes <- list()

    for (msfile in ms_files) {
      append_log(paste("正在处理：", basename(msfile)))
      sample_id <- file_path_sans_ext(basename(msfile))

      # guard: same sample name present in more than one format
      # (e.g. both P173.raw and P173.mzML) -> keep the first, skip the rest
      if (sample_id %in% names(all_ms2_data)) {
        append_log(paste("⚠️ 样本", sample_id,
                         "已由其他格式的文件处理过，跳过：", basename(msfile)))
        next
      }

      ms <- read_ms_file(msfile)
      st <- ms$scan_table
      spectra <- ms$spectra
      all_S[[sample_id]] <- spectra
      ion_modes[[sample_id]] <- ms$ion_mode

      # ---------------- MS2 扫描信息表 ----------------
      i_ms2 <- st %>%
        filter(msLevel == 2) %>%
        arrange(ms2_value) %>%
        mutate(
          group = {
            ms2_value_vec <- ms2_value
            groups <- numeric(length(ms2_value_vec))
            current_group <- 1
            threshold <- dplyr::first(ms2_value_vec) + 0.9
            for (i in seq_along(ms2_value_vec)) {
              if (ms2_value_vec[i] > threshold) {
                current_group <- current_group + 1
                threshold <- ms2_value_vec[i] + 0.9
              }
              groups[i] <- current_group
            }
            groups
          },
          Sample = sample_id
        ) %>%
        select(scan, StartTime, scanType, ms2_value, group, Sample)

      all_ms2_data[[sample_id]] <- i_ms2

      # ---------------- MS1 数据提取与清洗 ----------------
      merged_centroids <- list()
      for (i in seq_len(nrow(st))) {
        if (st$msLevel[i] != 1) next
        spec <- spectra[[as.character(st$scan[i])]]
        if (is.null(spec) || is.null(spec$mz) || length(spec$mz) == 0) next
        minute_label <- floor(as.numeric(st$StartTime[i]))
        label <- as.character(minute_label)
        df <- data.frame(mz = spec$mz, intensity = spec$intensity)
        merged_centroids[[label]] <- dplyr::bind_rows(merged_centroids[[label]], df)
      }

      cleaned_centroids <- list()
      for (label in names(merged_centroids)) {
        peaks <- merged_centroids[[label]]
        if (nrow(peaks) >= 2) {
          cleaned_mat <- clean_spectrum_keep_max(
            as.matrix(peaks),
            min_mz = 0,
            max_mz = 1500,
            noise_threshold = 0,
            min_ms2_difference_in_da = -1,
            min_ms2_difference_in_ppm = 10,
            max_peak_num = -1,
            normalize_intensity = FALSE
          )
          cleaned_df <- as.data.frame(cleaned_mat)
          colnames(cleaned_df) <- c("mz", "intensity")
          cleaned_df <- cleaned_df[cleaned_df$intensity > (10000), ]
          cleaned_df$RT <- as.numeric(label) + 1
          cleaned_centroids[[label]] <- cleaned_df
        }
      }

      keep_rt <- as.character(1:18)
      subset_cleaned <- do.call(rbind, cleaned_centroids[keep_rt])

      if (nrow(subset_cleaned) > 0) {
        subset_cleaned$mz <- round(subset_cleaned$mz, 4)
        subset_cleaned$intensity <- round(subset_cleaned$intensity, 0)
        subset_cleaned$RT_mz <- as.numeric(paste0(subset_cleaned$RT, sprintf("%.4f", subset_cleaned$mz)))
        subset_cleaned$Sample <- sample_id
        subset_cleaned <- subset_cleaned %>% select(Sample, RT, RT_mz, mz, intensity)
      } else {
        subset_cleaned <- data.frame(Sample = sample_id, RT = numeric(),
                                     RT_mz = character(), mz = numeric(),
                                     intensity = numeric())
      }

      all_samples_data[[sample_id]] <- subset_cleaned
    }

    #-----------------------------------------------------------
    # 3. 导出结果
    #-----------------------------------------------------------
    combined_ms2 <- do.call(rbind, all_ms2_data)
    write.csv(combined_ms2, "MS2_Group_Info.csv", row.names = FALSE)
    append_log("✅ 已导出 MS2_Group_Info.csv")



    output_dir <- "MS2_MGF"
    dir.create(output_dir, showWarnings = FALSE)

    for (sample_name in names(all_ms2_data)) {
      message("Writing MGF for: ", sample_name)

      ms2_df <- all_ms2_data[[sample_name]]
      spectra_list <- all_S[[sample_name]]
      sample_ion_mode <- ion_modes[[sample_name]]
      mgf_lines <- c()

      for (i in seq_len(nrow(ms2_df))) {
        scan_num <- ms2_df$scan[i]
        precursor_mz <- ms2_df$ms2_value[i]
        rt <- ms2_df$StartTime[i] # 单位：分钟

        spec <- spectra_list[[as.character(scan_num)]]
        if (is.null(spec)) next
        mz <- spec$mz
        intensity <- spec$intensity
        if (is.null(mz) || is.null(intensity)) next

        block <- c(
          paste0("NAME:", sample_name, "_scan", scan_num),
          paste0("PRECURSORMZ:", round(precursor_mz, 4)),
          paste0("IONMODE: ", sample_ion_mode),
          paste0("RETENTIONTIME:", round(rt, 2)),
          paste0("Num Peaks: ", length(mz)),
          paste(apply(cbind(mz, intensity), 1, paste, collapse=" "), collapse = "\n"),
          ""
        )

        mgf_lines <- c(mgf_lines, block)
      }

      writeLines(mgf_lines, file.path(output_dir, paste0(sample_name, ".msp")))
    }




    # 导出清洗后的 MS1 数据：按分组写入
    groups <- unique(sample_info$Group)
    for (grp in groups) {
      grp_samples <- sample_info %>% filter(Group == grp) %>% pull(Sample)
      wb <- createWorkbook()
      addWorksheet(wb, paste0("Group_", grp, "_MS1"))
      col_start <- 1
      for (sample_id in grp_samples) {
        if (!sample_id %in% names(all_samples_data)) next
        df <- all_samples_data[[sample_id]]
        writeData(wb, 1, df, startCol = col_start, startRow = 1)
        col_start <- col_start + ncol(df) + 1
      }
      out_file <- paste0("Clean_MS1_Data_Group", grp, ".xlsx")
      saveWorkbook(wb, out_file, overwrite = TRUE)
      append_log(paste("✅ 已保存", out_file))
    }

    output_files <- list.files(workdir, full.names = TRUE, recursive = TRUE)
    output$output_files <- renderTable({
      data.frame(
        文件名 = basename(output_files),
        路径 = normalizePath(output_files)
      )
    })

    append_log("🎉 全部流程完成！")
  })
})
}

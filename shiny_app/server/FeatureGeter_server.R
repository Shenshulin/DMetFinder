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

    # ----------------------------------------------------------
    # 进度条（不是装饰，是保活机制）
    # 整个流程写在同一个 observeEvent 里，是一次几十秒到几分钟的
    # 同步调用。每次 prog$set() 都会把控制权交还事件循环一次，
    # httpuv 才有机会发出 SockJS 心跳（客户端 25 s 收不到就盖灰罩）。
    # 不加 Progress 时，页面必然在约 25 s 后变灰，而 R 毫无察觉。
    # ----------------------------------------------------------
    prog <- shiny::Progress$new(session, min = 0, max = 1)
    on.exit(prog$close(), add = TRUE)
    prog$set(value = 0, message = "MSGeter", detail = "读取样本分组…")

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
    ion_modes <- list()

    # MGF 不再等 20 个样品全读完再统一写。每处理完一个文件立即落盘，
    # 然后释放该样品的完整谱图。原先的 all_S 会把所有 raw 的全部
    # 谱图常驻内存（实测 20 个样品峰值 6.2 GB），而它唯一的用途
    # 就是最后写 MGF，完全没必要攒着。
    msp_dir <- "MS2_MGF"
    dir.create(msp_dir, showWarnings = FALSE)
    n_files <- length(ms_files)

    for (k in seq_along(ms_files)) {
      msfile <- ms_files[k]
      append_log(paste0("正在处理（", k, "/", n_files, "）：", basename(msfile)))
      sample_id <- file_path_sans_ext(basename(msfile))
      prog$set(
        value  = 0.80 * (k - 1) / n_files,
        detail = sprintf("读取 %d/%d：%s", k, n_files, sample_id)
      )

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
      ion_modes[[sample_id]] <- ms$ion_mode
      prog$set(detail = sprintf("解析 %d/%d：%s", k, n_files, sample_id))

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

      # ---------------- 立即写 MGF，随后释放谱图 ----------------
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

      # 无 MS2 谱时 unlist 得到 NULL，writeLines(NULL) 会直接报错，
      # 这里显式退化成空字符向量（生成空 .msp，与原行为一致）
      mgf_text <- unlist(mgf_chunks, use.names = FALSE)
      if (is.null(mgf_text)) mgf_text <- character(0)
      writeLines(mgf_text, file.path(msp_dir, paste0(sample_id, ".msp")))

      # 谱图与去卷积中间态是每轮最大的对象，写完 MGF 立刻放掉；
      # 否则 20 个样品的峰值会在收尾阶段叠到数 GB。
      rm(ms, st, spectra, merged_centroids, cleaned_centroids,
         mgf_chunks, ms2_df)
      gc(verbose = FALSE)

      prog$set(value = 0.80 * k / n_files)
    }

    #-----------------------------------------------------------
    # 3. 导出结果
    #-----------------------------------------------------------
    prog$set(value = 0.82, detail = "导出 MS2_Group_Info.csv")
    if (length(all_ms2_data) > 0) {
      combined_ms2 <- do.call(rbind, all_ms2_data)
      write.csv(combined_ms2, "MS2_Group_Info.csv", row.names = FALSE)
      append_log("✅ 已导出 MS2_Group_Info.csv")
      rm(combined_ms2)
    } else {
      append_log("⚠️ 没有可导出的 MS2 扫描信息，跳过 MS2_Group_Info.csv")
    }
    append_log(paste0("✅ 已写出 ", length(ion_modes), " 个 MGF 文件到 ", msp_dir, "/"))



    # （MGF 已在主循环内逐样品写出，此处不再二次遍历）




    # ----------------------------------------------------------
    # Clean_MS1_Data_Group*.xlsx 的 Sample 列必须写纯数字。
    # 下游 dmf_read_samples() 会对每个 6 列块的首行做 as.numeric()，
    # 遇到 "P173" 得到 NA，整列判空后直接报"首行没有任何样品编号"。
    # 只改这一列的输出值：all_samples_data 的 key（= 文件名）保持不变，
    # MS2_Group_Info.csv 与 MGF 的 NAME 仍是原始文件名，便于追溯。
    # 取"第一个连续数字串"：P173 -> 173，Sample_07 -> 07（保留前导零）。
    # ----------------------------------------------------------
    num_from_id <- function(id) {
      m <- regmatches(id, regexpr("[0-9]+", id))
      if (length(m) == 0L) NA_character_ else m[1]
    }
    sample_num <- vapply(names(all_samples_data), num_from_id,
                         character(1), USE.NAMES = TRUE)

    no_digit <- names(sample_num)[is.na(sample_num)]
    if (length(no_digit) > 0L) {
      append_log(paste("⚠️ 样品名里取不到数字，这些块将保留原名：",
                       paste(no_digit, collapse = ", ")))
    }
    good_num <- sample_num[!is.na(sample_num)]
    dup_num <- unique(good_num[duplicated(good_num)])
    if (length(dup_num) > 0L) {
      append_log(paste("⚠️ 转成纯数字后编号重复，下游会混淆：",
                       paste(dup_num, collapse = ", ")))
    }

    # 导出清洗后的 MS1 数据：按分组写入
    groups <- unique(sample_info$Group)
    for (gi in seq_along(groups)) {
      grp <- groups[gi]
      prog$set(
        value  = 0.85 + 0.14 * (gi - 1) / length(groups),
        detail = sprintf("写 Excel %d/%d：Group %s", gi, length(groups), grp)
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
      append_log(paste0("✅ 已保存 ", out_file, "（样品编号：",
                        paste(written, collapse = ", "), "）"))
      # openxlsx 的 workbook 在写出后仍持有整张表，逐组放掉
      rm(wb); gc(verbose = FALSE)
    }

    prog$set(value = 1, detail = "完成")
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

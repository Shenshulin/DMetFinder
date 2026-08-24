#FeatureGeter_server.R
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
    # 2. 处理 raw 文件
    #-----------------------------------------------------------
    raw_files <- list.files(path = workdir, pattern = "\\.raw$", full.names = TRUE)
    if (length(raw_files) == 0) {
      append_log("未找到任何 .raw 文件。")
      return(NULL)
    }
    
    append_log(paste("检测到", length(raw_files), "个 .raw 文件。"))
    all_samples_data <- list()
    all_ms2_data <- list()
    all_S <- list()
    
    for (rawfile in raw_files) {
      append_log(paste("正在处理：", basename(rawfile)))
      sample_id <- file_path_sans_ext(basename(rawfile))
      
      H <- rawrr::readFileHeader(rawfile = rawfile)
      S <- rawrr::readSpectrum(rawfile = rawfile, scan = 1:H[["Number of scans"]],mode = "profile")
      all_S[[sample_id]] <- S
      
      all_scan_data <- do.call(rbind, lapply(1:H[["Number of scans"]], function(i) {
        data.frame(
          scan = S[[i]][["scan"]],
          StartTime = S[[i]][["StartTime"]],
          scanType = S[[i]][["scanType"]],
          stringsAsFactors = FALSE
        )
      }))
      
      i_ms2 <- all_scan_data %>%
        filter(scanType != "FTMS - p ESI Full ms [100.0000-1500.0000]") %>%
        mutate(
          ms2_value = as.numeric(str_extract(scanType, "(?<=ms2\\s)[^@]+"))
        ) %>%
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
        )
      
      
      all_ms2_data[[sample_id]] <- i_ms2
      
      # 提取并清洗 MS1 数据
      merged_centroids <- list()
      for (i in seq_along(S)) {
        scan <- S[[i]]
        if (scan$scanType != "FTMS - p ESI Full ms [100.0000-1500.0000]") next
        if (is.null(scan$centroid.mZ) || is.null(scan$centroid.intensity)) next
        minute_label <- floor(as.numeric(scan$StartTime))
        label <- as.character(minute_label)
        df <- data.frame(mz = scan$centroid.mZ, intensity = scan$centroid.intensity)
        merged_centroids[[label]] <- dplyr::bind_rows(merged_centroids[[label]], df)
      }
      
      #########先写一个清洗函数
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
      mgf_lines <- c()
      
      for (i in seq_len(nrow(ms2_df))) {
        scan_num <- ms2_df$scan[i]
        precursor_mz <- ms2_df$ms2_value[i]
        rt <- ms2_df$StartTime[i] # 转为秒
        
        spec <- spectra_list[[scan_num]]
        mz <- spec$centroid.mZ
        intensity <- spec$centroid.intensity
        
        # block <- c(
        #   "BEGIN IONS",
        #   paste0("TITLE=", sample_name, "_scan", scan_num),
        #   paste0("PEPMASS=", round(precursor_mz, 4)),
        #   paste0("RTINSECONDS=", round(rt, 2)),
        #   paste(apply(cbind(mz, intensity), 1, paste, collapse = " "), collapse = "\n"),
        #   "END IONS",
        #   ""
        # )

        block <- c(
          paste0("NAME:", sample_name, "_scan", scan_num),
          paste0("PRECURSORMZ:", round(precursor_mz, 4)),
          paste0("IONMODE: Negative"),
          paste0("RETENTIONTIME:", round(rt, 2)),
          paste0("Num Peaks: ", length(mz)),
          paste(apply(cbind(mz, intensity), 1, paste, collapse = " "), collapse = "\n"),
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
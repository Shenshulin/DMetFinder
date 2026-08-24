readMSP <- function(file){

  txt <- readLines(file, warn = FALSE)

  idx <- grep("^NAME:", txt)

  res <- vector("list", length(idx))

  for(i in seq_along(idx)){

    start <- idx[i]

    end <- if(i < length(idx)){
      idx[i + 1] - 1
    } else {
      length(txt)
    }

    block <- txt[start:end]

    name <- sub("^NAME:", "", block[1])

    precursor_mz <- as.numeric(
      sub(
        "^PRECURSORMZ:",
        "",
        grep(
          "^PRECURSORMZ:",
          block,
          value = TRUE
        )
      )
    )

    ionmode <- sub(
      "^IONMODE:",
      "",
      grep(
        "^IONMODE:",
        block,
        value = TRUE
      )
    )

    rt <- as.numeric(
      sub(
        "^RETENTIONTIME:",
        "",
        grep(
          "^RETENTIONTIME:",
          block,
          value = TRUE
        )
      )
    )

    peak_start <- grep(
      "^Num Peaks:",
      block
    ) + 1

    peak_lines <- block[
      peak_start:length(block)
    ]

    peak_lines <- peak_lines[
      nzchar(trimws(peak_lines))
    ]

    peak_mat <- do.call(
      rbind,
      strsplit(
        trimws(peak_lines),
        "\\s+"
      )
    )

    scan <- as.numeric(
      stringr::str_extract(
        name,
        "(?<=scan)\\d+"
      )
    )

    res[[i]] <- list(
      scan = scan,
      precursorMz = precursor_mz,
      ionmode = ionmode,
      rtime = rt,
      mz = as.numeric(peak_mat[,1]),
      intensity = as.numeric(peak_mat[,2])
    )
  }

  names(res) <- sapply(
    res,
    function(x) as.character(x$scan)
  )

  res
}


matchScan <- function(
    demo_ms2,
    all_ms2,
    mz_tol = 0.01
){

  demo_ms2$scan <- NA_integer_

  for(i in seq_len(nrow(demo_ms2))){

    sample_i <- demo_ms2$sample[i]

    mz_i <- demo_ms2$`m/z`[i]

    rt_i <- demo_ms2$RT[i]

    sub_all <- all_ms2[
      Sample == sample_i
    ]

    if(nrow(sub_all) == 0)
      next

    sub_all[, mz_diff := abs(
      ms2_value - mz_i
    )]

    sub_all <- sub_all[
      mz_diff <= mz_tol
    ]

    if(nrow(sub_all) == 0)
      next

    sub_all[, rt_diff := abs(
      StartTime - rt_i
    )]

    data.table::setorder(
      sub_all,
      rt_diff,
      mz_diff
    )

    demo_ms2$scan[i] <- sub_all$scan[1]
  }

  demo_ms2[
    !is.na(scan)
  ]
}


Ms2Geter_server <- function(id){

  moduleServer(id, function(input, output, session){

    volumes <- c(
      "C:" = "C:/",
      "D:" = "D:/",
      "E:" = "E:/",
      "F:" = "F:/",
      "G:" = "G:/",
      "H:" = "H:/"
    )

    shinyDirChoose(
      input,
      "mgf_dir",
      roots = volumes,
      session = session
    )

    mgf_dir_path <- reactiveVal(NULL)

    observeEvent(input$mgf_dir, {

      dir_selected <- parseDirPath(
        volumes,
        input$mgf_dir
      )

      mgf_dir_path(dir_selected)

      output$mgf_dir_path <- renderText(
        paste(
          "📁 Selected folder:",
          dir_selected
        )
      )

    })

    log_text <- reactiveVal("")

    append_log <- function(msg){

      new_log <- paste0(
        format(Sys.time(), "[%H:%M:%S] "),
        msg,
        "\n",
        log_text()
      )

      log_text(new_log)

      updateTextAreaInput(
        session,
        "log_area",
        value = new_log
      )
    }

    observeEvent(input$run, {

      req(
        input$all_ms2_file,
        input$demo_ms2_file,
        mgf_dir_path()
      )

      tryCatch({

        append_log("Reading input files...")

        all_ms2 <- data.table::fread(
          input$all_ms2_file$datapath
        )

        demo_ms2 <- data.table::fread(
          input$demo_ms2_file$datapath
        )

        ################################################
        # Scan Matching
        ################################################

        append_log("Matching scan numbers...")

        demo_ms2[, scan := NA_integer_]

        for(i in seq_len(nrow(demo_ms2))){

          if (!"sample" %in% names(demo_ms2))
  stop("demo.csv中不存在列: sample")

sample_i <- as.character(
  demo_ms2$sample[i]
)

if (!"Sample" %in% names(all_ms2))
  stop("MS2_Group_Info.csv中不存在列: Sample")

          mz_i <- demo_ms2$`m/z`[i]

          rt_i <- demo_ms2$RT[i]

          sub_all <- all_ms2[
            Sample == sample_i
          ]

          if(nrow(sub_all) == 0)
            next

          sub_all <- copy(sub_all)

          sub_all[, mz_diff := abs(
            ms2_value - mz_i
          )]

          sub_all <- sub_all[
            mz_diff <= 0.01
          ]

          if(nrow(sub_all) == 0)
            next

          sub_all[, rt_diff := abs(
            StartTime - rt_i
          )]

          data.table::setorder(
            sub_all,
            rt_diff,
            mz_diff
          )

          demo_ms2$scan[i] <- sub_all$scan[1]
        }

        demo_ms2 <- demo_ms2[
          !is.na(scan)
        ]

        append_log(
          paste(
            "Matched",
            nrow(demo_ms2),
            "features."
          )
        )

        ################################################
        # Read MSP Files
        ################################################

        mgf_dir <- mgf_dir_path()

        msp_files <- list.files(
          mgf_dir,
          pattern = "\\.msp$",
          full.names = TRUE
        )

        append_log(
          paste(
            "Found",
            length(msp_files),
            "MSP files."
          )
        )

        msp_list <- msp_files |>
          setNames(
            stringr::str_remove(
              basename(msp_files),
              "\\.msp$"
            )
          ) |>
          purrr::map(readMSP)

        ################################################
        # Extract Spectra
        ################################################

        append_log(
          "Extracting spectra..."
        )

        msp_lines <- c()

        for(i in seq_len(nrow(demo_ms2))){

          sample_name <- demo_ms2$sample[i]

          scan_i <- demo_ms2$scan[i]

          if(
            !(sample_name %in%
                names(msp_list))
          ){
            next
          }

          sample_msp <- msp_list[[sample_name]]

          if(is.null(sample_msp))
            next

spec <- sample_msp[[as.character(scan_i)]]

          if(is.null(spec))
            next

          peak_lines <- paste(
            spec$mz,
            spec$intensity
          )

          block <- c(

            paste0(
              "NAME:",
              sample_name,
              "_scan",
              scan_i
            ),

            paste0(
              "FEATURE_INFO:",
              sample_name,
              "&",
              round(
                demo_ms2$RT[i],
                4
              ),
              "&",
              round(
                demo_ms2$`m/z`[i],
                6
              )
            ),

            paste0(
              "PRECURSORMZ:",
              round(
                spec$precursorMz,
                6
              )
            ),

            paste0(
              "IONMODE:",
              spec$ionmode
            ),

            paste0(
              "RETENTIONTIME:",
              round(
                spec$rtime,
                4
              )
            ),

            paste0(
              "Num Peaks:",
              length(spec$mz)
            ),

            peak_lines,

            ""
          )

          msp_lines <- c(
            msp_lines,
            block
          )
        }

        ################################################
        # Output MSP
        ################################################

        output_path <- file.path(
          mgf_dir,
          input$output_mgf
        )

        if(
          !grepl(
            "\\.msp$",
            output_path,
            ignore.case = TRUE
          )
        ){
          output_path <- paste0(
            output_path,
            ".msp"
          )
        }

        writeLines(
          msp_lines,
          output_path
        )

        append_log(
          paste(
            "Finished:",
            output_path
          )
        )

        output$status <- renderText(
          paste(
            "Done.",
            nrow(demo_ms2),
            "features matched."
          )
        )

      }, error = function(e){

        append_log(
          paste(
            "ERROR:",
            e$message
          )
        )

        output$status <- renderText(
          "Failed."
        )

      })

    })

  })

}
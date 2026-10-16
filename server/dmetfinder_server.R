# ============================================================
# DMetFinder Server
# ============================================================

dmetfinder_server <- function(input, output, session) {
  
  # Store data
  values <- reactiveValues(
    dataA = NULL,
    dataB = NULL,
    results = list(),
    status = NULL
  )
  
  # ============ Data Reading ============
  
  # Group A data
  observeEvent(input$fileA, {
    req(input$fileA)
    tryCatch({
      withProgress(message = "Reading Group A data...", {
        data <- read_raw_data(input$fileA$datapath)
        values$dataA <- data
      })
      output$fileA_info <- renderUI({
        div(class = "status-box status-success",
            icon("check-circle"),
            sprintf("Group A data loaded successfully: %d samples, %d ion rows per sample", 
                    length(data$sample_ids), nrow(data$samples[[1]])))
      })
    }, error = function(e) {
      output$fileA_info <- renderUI({
        div(class = "status-box status-error",
            icon("exclamation-circle"),
            paste("Failed to load Group A data:", e$message))
      })
    })
  })
  
  # Group B data
  observeEvent(input$fileB, {
    req(input$fileB)
    tryCatch({
      withProgress(message = "Reading Group B data...", {
        data <- read_raw_data(input$fileB$datapath)
        values$dataB <- data
      })
      output$fileB_info <- renderUI({
        div(class = "status-box status-success",
            icon("check-circle"),
            sprintf("Group B data loaded successfully: %d samples, %d ion rows per sample", 
                    length(data$sample_ids), nrow(data$samples[[1]])))
      })
    }, error = function(e) {
      output$fileB_info <- renderUI({
        div(class = "status-box status-error",
            icon("exclamation-circle"),
            paste("Failed to load Group B data:", e$message))
      })
    })
  })
  
  # Data preview
  output$previewA <- renderDT({
    req(values$dataA)
    df <- values$dataA$samples[[1]]
    datatable(head(df, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$previewB <- renderDT({
    req(values$dataB)
    df <- values$dataB$samples[[1]]
    datatable(head(df, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  # ============ Analysis Execution ============
  
  observeEvent(input$runAnalysis, {
    req(values$dataA, values$dataB)
    
    # Get configuration
    config <- list(
      ErrorRange = input$ErrorRange,
      ErrorRangeInGroups = input$ErrorRangeInGroups,
      FloatCount = input$FloatCount,
      mergeRows = input$mergeRows,
      m1 = input$m1,
      m2 = input$m2,
      m3 = input$m3,
      p50IonPercent = input$p50IonPercent,
      p80IonPercent = input$p80IonPercent,
      intensityRange = as.numeric(strsplit(input$intensityRange, ",")[[1]]),
      intensityValue = as.numeric(strsplit(input$intensityValue, ",")[[1]]),
      countRange = as.numeric(strsplit(input$countRange, ",")[[1]]),
      countValue = as.numeric(strsplit(input$countValue, ",")[[1]]),
      relativeIntensityRange1 = as.numeric(strsplit(input$relIntensityRange1, ",")[[1]]),
      relativeIntensityValue1 = as.numeric(strsplit(input$relIntensityValue1, ",")[[1]])
    )
    
    tryCatch({
      withProgress(message = "Analyzing data...", value = 0, {
        
        # Step 1: Merge Group A samples
        incProgress(0.05, detail = "Merging Group A samples...")
        mergedA <- merge_samples(values$dataA, config$ErrorRange)
        
        # Step 2: Merge Group B samples
        incProgress(0.15, detail = "Merging Group B samples...")
        mergedB <- merge_samples(values$dataB, config$ErrorRange)
        
        # Step 3: Score Group A ions
        incProgress(0.25, detail = "Scoring Group A ions...")
        scoredA <- score_ions(mergedA, config)
        
        # Step 4: Score Group B ions
        incProgress(0.35, detail = "Scoring Group B ions...")
        scoredB <- score_ions(mergedB, config)
        
        # Step 5: Group A isotope search
        incProgress(0.45, detail = "Group A isotope search...")
        isoA <- find_isotopes(values$dataA, config)
        
        # Step 6: Group B isotope search
        incProgress(0.55, detail = "Group B isotope search...")
        isoB <- find_isotopes(values$dataB, config)
        
        # Step 7: Group A 80% filter
        incProgress(0.65, detail = "Group A 80% filter...")
        filterA80 <- filter_by_percent(mergedA, config$p80IonPercent)
        
        # Step 8: Group B 80% filter
        incProgress(0.72, detail = "Group B 80% filter...")
        filterB80 <- filter_by_percent(mergedB, config$p80IonPercent)
        
        # Step 9: Compare Group A 80% ions with Group B total ions
        incProgress(0.8, detail = "Comparing Group A 80% ions with Group B total ions...")
        compareA <- compare_groups(filterA80, mergedB, config$ErrorRange)
        
        # Step 10: Compare Group B 80% ions with Group A total ions
        incProgress(0.88, detail = "Comparing Group B 80% ions with Group A total ions...")
        compareB <- compare_groups(filterB80, mergedA, config$ErrorRange)
        
        # Step 11: Group A - Group B differential ion summary
        incProgress(0.94, detail = "Generating differential ion summary...")
        diff_summary <- compare_groups(filterA80, filterB80, config$ErrorRange)
        
        # Save results
        incProgress(1, detail = "Done")
        values$results <- list(
          filterA = mergedA,
          scoreA = scoredA,
          isoA = isoA,
          compareA = compareA,
          diff = diff_summary,
          filterB = mergedB,
          scoreB = scoredB,
          isoB = isoB,
          compareB = compareB
        )
        
        values$status <- "success"
      })
      
      output$run_status <- renderUI({
        div(class = "status-box status-success",
            icon("check-circle"),
            "Analysis complete! Switch to the 'Results' tab to view results.")
      })
      
    }, error = function(e) {
      values$status <- "error"
      output$run_status <- renderUI({
        div(class = "status-box status-error",
            icon("exclamation-circle"),
            paste("Analysis failed:", e$message))
      })
    })
  })
  
  # ============ Result Display ============
  
  # Result file list
  output$result_files <- renderUI({
    req(values$results)
    files <- c(
      "GroupA-50and80PercentIonFilter.xlsx",
      "GroupA-IonScoring.xlsx",
      "GroupA-IsotopeSearch.xlsx",
      "GroupA-80PercentIonsVsGroupBTotalIons.xlsx",
      "GroupA-GroupB-DifferentialIonSummary.xlsx",
      "GroupB-50and80PercentIonFilter.xlsx",
      "GroupB-IonScoring.xlsx",
      "GroupB-IsotopeSearch.xlsx",
      "GroupB-80PercentIonsVsGroupATotalIons.xlsx"
    )
    tags$ul(
      class = "file-list",
      lapply(files, function(f) tags$li(icon("file-excel"), f))
    )
  })
  
  # Result preview
  output$result_filterA <- renderDT({
    req(values$results$filterA)
    datatable(head(values$results$filterA, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_scoreA <- renderDT({
    req(values$results$scoreA)
    datatable(head(values$results$scoreA, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_isoA <- renderDT({
    req(values$results$isoA)
    datatable(head(values$results$isoA, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_compareA <- renderDT({
    req(values$results$compareA)
    datatable(head(values$results$compareA, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_diff <- renderDT({
    req(values$results$diff)
    datatable(head(values$results$diff, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_filterB <- renderDT({
    req(values$results$filterB)
    datatable(head(values$results$filterB, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_scoreB <- renderDT({
    req(values$results$scoreB)
    datatable(head(values$results$scoreB, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_isoB <- renderDT({
    req(values$results$isoB)
    datatable(head(values$results$isoB, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  output$result_compareB <- renderDT({
    req(values$results$compareB)
    datatable(head(values$results$compareB, 100), options = list(scrollX = TRUE, pageLength = 10))
  })
  
  # Download all results
  output$downloadAll <- downloadHandler(
    filename = function() {
      paste0("DMetFinder_results_", format(Sys.Date(), "%Y%m%d"), ".zip")
    },
    content = function(file) {
      req(values$results)
      
      # Create temporary directory
      tmpdir <- tempfile(pattern = "dmetfinder_")
      dir.create(tmpdir, showWarnings = FALSE)
      
      # Write result files
      write_xlsx(values$results$filterA, file.path(tmpdir, "GroupA-50and80PercentIonFilter.xlsx"))
      write_xlsx(values$results$scoreA, file.path(tmpdir, "GroupA-IonScoring.xlsx"))
      write_xlsx(values$results$isoA, file.path(tmpdir, "GroupA-IsotopeSearch.xlsx"))
      write_xlsx(values$results$compareA, file.path(tmpdir, "GroupA-80PercentIonsVsGroupBTotalIons.xlsx"))
      write_xlsx(values$results$diff, file.path(tmpdir, "GroupA-GroupB-DifferentialIonSummary.xlsx"))
      write_xlsx(values$results$filterB, file.path(tmpdir, "GroupB-50and80PercentIonFilter.xlsx"))
      write_xlsx(values$results$scoreB, file.path(tmpdir, "GroupB-IonScoring.xlsx"))
      write_xlsx(values$results$isoB, file.path(tmpdir, "GroupB-IsotopeSearch.xlsx"))
      write_xlsx(values$results$compareB, file.path(tmpdir, "GroupB-80PercentIonsVsGroupATotalIons.xlsx"))
      
      # Zip files
      files_to_zip <- list.files(tmpdir, full.names = TRUE)
      zip(file, files_to_zip, extras = "-j")
    }
  )
}
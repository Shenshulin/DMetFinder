# ============================================================
# Peak Quality Assessment - server module
# ============================================================
# Ids are namespaced, so this module can coexist with the existing tabs.
# The heavy lifting lives in pipeline.R / xic_extract.R / peak_detect.R /
# score_adapter.R; this file only wires UI state together.
# ============================================================

PQ_RAW_PATTERN <- "\\.(raw|mzml|mzxml)$"

peak_quality_server <- function(id) {
  moduleServer(id, function(input, output, session) {

    ns <- session$ns

    # ---------------- state ----------------
    log_text  <- reactiveVal("")
    file_tbl  <- reactiveVal(NULL)
    peak_df   <- reactiveVal(NULL)
    mapping_r <- reactiveVal(NULL)
    features_ok  <- reactiveVal(NULL)
    features_bad <- reactiveVal(NULL)
    lookup_r  <- reactiveVal(NULL)
    results   <- reactiveVal(NULL)
    run_meta  <- reactiveVal(NULL)

    # ---- second method + cross-sample peak groups (stage 2/3) ----
    cpc_tbl      <- reactiveVal(NULL)
    cpc_settings <- reactiveVal(NULL)
    group_diag   <- reactiveVal(NULL)
    group_obj    <- reactiveVal(NULL)
    dnn_result   <- reactiveVal(NULL)

    append_log <- function(msg, level = "INFO") {
      log_text(paste0(log_text(), format(Sys.time(), "[%H:%M:%S] "), msg, "\n"))
      # Same line goes to a file. The UI text dies with the websocket, so a
      # 28-minute run that ends in a grey page would otherwise leave no record
      # of where it stopped or why.
      pq_log_write(log_path, level, msg)
    }
    output$log <- renderText(log_text())

    log_path <- pq_log_open()
    if (!is.null(log_path)) {
      # Set the initial value directly: reading `log_text()` here would run
      # outside any reactive context and abort the whole session at startup
      # ("Operation not allowed without an active reactive context") - which
      # looks exactly like a grey page with an empty log.
      log_text(paste0(format(Sys.time(), "[%H:%M:%S] "), "Run log: ",
                      normalizePath(log_path, winslash = "/", mustWork = FALSE), "\n"))
    }

    # Snapshot of the last finished run, in a plain environment: `onSessionEnded`
    # runs after the reactive graph is gone, so a reactiveVal cannot be read
    # there. Values are copied in as soon as the run produces them.
    run_snapshot <- new.env(parent = emptyenv())
    session$onSessionEnded(function() {
      rows <- run_snapshot$rows
      if (is.null(rows) || !is.data.frame(rows)) return(invisible(NULL))
      if (nrow(rows) < PQ_AUTOSAVE_MIN_ROWS) return(invisible(NULL))
      out <- tryCatch(
        pq_save_run(rows, run_snapshot$detail, run_snapshot$meta),
        error = function(e) NULL)
      pq_log_write(log_path, "INFO", sprintf(
        "session ended with %d result row(s); snapshot %s",
        nrow(rows), if (is.null(out)) "could NOT be written" else paste("saved to", out)))
    })


    # ============================================================
    # 0. Method availability
    # ============================================================
    # The registry is the single authority: a method is offered only when its
    # runtime is actually present. Kumler is vendored, so it always runs.
    methods_tbl <- reactive({
      pq_methods_table()
    })

    output$method_choices_ui <- renderUI({
      tab <- methods_tbl()
      cpc_row <- tab[tab$method == "cpc", , drop = FALSE]
      cpc_ok <- nrow(cpc_row) == 1 && isTRUE(cpc_row$available)

      kumler_box <- div(class = "method-line",
        tags$span(class = "method-line__dot method-line__dot--on"),
        tags$b("Kumler"), tags$span(class = "method-line__hint",
                                    "peak-shape correlation + custom SNR (always evaluated)")
      )

      cpc_box <- if (cpc_ok) {
        checkboxInput(ns("method_cpc"),
                      "CPC: chromatographic metrics + own peak boundaries",
                      value = FALSE)
      } else {
        htmltools::tagAppendAttributes(
          checkboxInput(ns("method_cpc"),
                        "CPC (not installed in this R library)",
                        value = FALSE),
          disabled = "disabled")
      }

      tagList(
        kumler_box,
        cpc_box,
        if (!cpc_ok) div(class = "mini-summary mini-summary--warn",
                         cpc_row$reason),
        checkboxInput(ns("method_dnn"),
                      "DNN: score cross-sample peak groups (Kantz 2019)",
                      value = FALSE),
        conditionalPanel(
          condition = sprintf("input['%s'] == true", ns("method_dnn")),
          numericInput(ns("dnn_threshold"),
                       "DNN score threshold",
                       value = 0.5, min = 0, max = 1, step = 0.01),
          div(class = "mini-summary",
              "0.5 is what the author's ApplyPeakPredictionModel.R uses;",
              " filterOutBadPeaks.R uses 0.4. The DNN never changes the",
              " quality class - it only adds its own columns.")
        )
      )
    })

    output$method_status_ui <- renderUI({
      tab <- methods_tbl()
      # NOTE: a character vector of length > 1 cannot be a single child of a
      # tag (htmltools: "Text to be written must be a length-one character
      # vector"), so the lines are built one by one.
      lines <- lapply(seq_len(nrow(tab)), function(i) {
        cls <- if (isTRUE(tab$available[i])) "mini-summary__ok" else "mini-summary__mute"
        txt <- sprintf(
          "%s: %s%s", tab$label[i],
          if (isTRUE(tab$available[i])) "ready" else "unavailable",
          if (isTRUE(tab$available[i]) && nzchar(tab$version[i]))
            paste0(" (", tab$version[i], ")") else "")
        div(class = cls, txt)
      })
      div(class = "mini-summary", lines)
    })

    output$methods_table <- renderDT({
      tab <- methods_tbl()
      DT::datatable(tab, rownames = FALSE,
                    options = list(dom = "t", pageLength = 5, scrollX = TRUE)) |>
        DT::formatStyle("available",
          backgroundColor = DT::styleEqual(c(TRUE, FALSE), c("#ecfdf5", "#fef2f2")))
    })

    # ============================================================
    # 1. Raw file discovery
    # ============================================================
    pq_scan_dir <- function(dir) {
      if (is.null(dir) || !nzchar(dir) || !dir.exists(dir)) return(NULL)
      f <- list.files(dir, pattern = PQ_RAW_PATTERN, ignore.case = TRUE,
                      full.names = TRUE)
      if (length(f) == 0) return(NULL)
      data.frame(name = basename(f), path = normalizePath(f, winslash = "/",
                                                          mustWork = FALSE),
                 size_mb = round(file.size(f) / 1024^2, 1),
                 stringsAsFactors = FALSE)
    }

    collect_files <- function() {
      if (identical(input$source_type, "upload")) {
        up <- input$raw_upload
        if (is.null(up) || nrow(up) == 0) return(NULL)
        data.frame(name = up$name, path = up$datapath,
                   size_mb = round(up$size / 1024^2, 1),
                   stringsAsFactors = FALSE)
      }
      pq_scan_dir(input$workdir)
    }

    observeEvent(input$scan, {
      ft <- pq_scan_dir(input$workdir)
      file_tbl(ft)
      if (is.null(ft)) {
        append_log("No .raw/.mzML/.mzXML file found in the folder.")
      } else {
        append_log(sprintf("Found %d raw file(s) in %s", nrow(ft), input$workdir))
      }
    })

    observeEvent(input$raw_upload, {
      ft <- collect_files()
      file_tbl(ft)
      if (!is.null(ft)) {
        append_log(sprintf("Uploaded %d raw file(s).", nrow(ft)))
      }
    })

    output$file_summary <- renderUI({
      ft <- file_tbl()
      if (is.null(ft)) {
        return(div(class = "mini-summary mini-summary--muted",
                   "No raw file selected yet"))
      }
      dup <- sum(duplicated(pq_norm_key(ft$name)))
      div(class = "mini-summary",
          sprintf("%d file(s) ready", nrow(ft)),
          if (dup > 0) div(class = "mini-summary__warn",
                           sprintf("%d duplicated sample name(s) - the first file wins", dup))
      )
    })

    # ============================================================
    # 2. Peak table
    # ============================================================
    observeEvent(input$peak_table, {
      req(input$peak_table)
      df <- tryCatch(
        pq_read_table(input$peak_table$datapath, input$peak_table$name),
        error = function(e) {
          append_log(paste0("Failed to read peak table: ", conditionMessage(e)))
          NULL
        })
      if (is.null(df)) return()
      if (nrow(df) == 0) {
        append_log("Peak table is empty.")
        return()
      }
      names(df) <- trimws(names(df))
      peak_df(df)
      mapping_r(pq_guess_mapping(names(df)))
      append_log(sprintf("Peak table loaded: %d rows, %d columns.",
                         nrow(df), ncol(df)))
    })

    output$peak_table_summary <- renderUI({
      df <- peak_df()
      if (is.null(df)) {
        return(div(class = "mini-summary mini-summary--muted",
                   "No peak table loaded yet"))
      }
      div(class = "mini-summary",
          sprintf("%d rows x %d columns", nrow(df), ncol(df)))
    })

    output$mapping_ui <- renderUI({
      df <- peak_df()
      if (is.null(df)) {
        return(div(class = "mini-summary mini-summary--muted",
                   "Load a peak table to configure the mapping"))
      }
      cols <- names(df)
      guess <- pq_guess_mapping(cols)
      choices <- c("(not used)" = "", stats::setNames(cols, cols))

      lapply(c("feature_id", "mz", "rt", "sample_id", "area", "height",
               "polarity", "charge", "original_id"), function(f) {
        selectInput(ns(paste0("map_", f)), pq_field_labels[[f]],
                    choices = choices,
                    selected = ifelse(is.na(guess[[f]]), "", guess[[f]]),
                    selectize = FALSE)
      })
    })

    current_mapping <- function() {
      df <- peak_df()
      if (is.null(df)) return(NULL)
      cols <- names(df)
      fields <- c("feature_id", "mz", "rt", "sample_id", "area", "height",
                  "polarity", "charge", "original_id")
      out <- lapply(fields, function(f) {
        v <- input[[paste0("map_", f)]]
        if (is.null(v) || !nzchar(v) || !v %in% cols) "" else v
      })
      names(out) <- fields
      out
    }

    output$peak_preview <- renderDT({
      df <- peak_df()
      if (is.null(df)) return(DT::datatable(data.frame(Message = "No peak table loaded yet")))
      DT::datatable(utils::head(df, 100), rownames = FALSE,
                    options = list(pageLength = 8, scrollX = TRUE,
                                   dom = "tip"))
    })

    # optional manual sample map
    # NOTE: no req() here - req() would silently cancel the whole run when the
    # (optional) file is not supplied.
    manual_map <- reactive({
      if (is.null(input$sample_map)) return(NULL)
      tryCatch(pq_read_sample_map(input$sample_map$datapath),
               error = function(e) {
                 append_log(paste0("Sample map error: ", conditionMessage(e)))
                 NULL
               })
    })

    # ============================================================
    # 3. Run
    # ============================================================
    observeEvent(input$run, {
      append_log("Run requested.")
      results(NULL); run_meta(NULL)

      ft <- collect_files()
      file_tbl(ft)
      if (is.null(ft)) {
        append_log("ABORTED: no raw file. Select a folder or upload files.")
        showNotification("No raw file available.", type = "error")
        return()
      }

      df <- peak_df()
      if (is.null(df)) {
        append_log("ABORTED: load a peak table first.")
        showNotification("Load a peak table first.", type = "error")
        return()
      }

      map <- current_mapping()
      std <- pq_standardize_features(df, map, rt_unit = input$rt_unit)
      if (length(std$errors) > 0) {
        append_log(paste0("ABORTED: ", paste(std$errors, collapse = "; ")))
        showNotification(paste(std$errors, collapse = "; "), type = "error")
        return()
      }

      feat <- std$ok
      features_bad(std$bad)

      if (nrow(feat) == 0) {
        append_log("ABORTED: no valid row in the peak table.")
        showNotification("No valid row in the peak table.", type = "error")
        return()
      }

      # ---- sample scope -------------------------------------------------
      # An aligned table (MS-DIAL / MZmine) has no sample column: one row per
      # feature, with the cohort-average m/z and RT. Those rows are expanded to
      # feature x raw file so the feature is scored in every sample.
      scope <- if (is.null(input$sample_scope)) "auto" else input$sample_scope
      has_sample_col <- !all(is.na(feat$sample_id) | !nzchar(feat$sample_id))
      broadcast <- identical(scope, "all_files") ||
        (identical(scope, "auto") && !has_sample_col)

      # ---- job size -----------------------------------------------------
      # The cap applies to PEAK TABLE features, i.e. before an aligned table
      # is expanded. 3450 features x 20 raw files = 69000 sample rows is a
      # normal job and is never truncated; an over-large job aborts loudly.
      max_rows <- if (is.null(input$max_expanded_rows)) 200000L else
        as.integer(input$max_expanded_rows)
      plan <- pq_plan_job(nrow(feat), nrow(ft), broadcast,
                          max_features = input$max_features,
                          max_rows = max_rows)
      for (msg in plan$messages) append_log(msg)
      if (plan$abort) {
        showNotification(plan$messages[length(plan$messages)],
                         type = "error", duration = NULL)
        return()
      }
      if (plan$truncate_features) feat <- utils::head(feat, plan$keep_features)

      if (broadcast) {
        feat <- pq_expand_features(feat, ft$path)
        append_log(sprintf(
          "Aligned table: %d feature(s) expanded to %d row(s) across %d raw file(s).",
          nrow(feat) / max(1, nrow(ft)), nrow(feat), nrow(ft)))
      } else if (!has_sample_col) {
        if (nrow(ft) == 1) {
          feat$sample_id <- pq_norm_key(ft$name[1])
          append_log("No sample_id column mapped; single raw file assigned to all rows.")
        } else {
          append_log("ABORTED: several raw files but no sample_id column.")
          showNotification(paste("Map a sample_id column, or set Sample scope to",
                                 "'Every feature in every raw file'."),
                           type = "error")
          return()
        }
      }

      # The plan was made before expansion, but a broadcast job can also be
      # inflated by the sample assignment above; verify the real size too.
      if (nrow(feat) > max_rows) {
        append_log(sprintf(paste0(
          "ABORTED: %d row(s) to process exceed the limit of %d. Nothing was processed."),
          nrow(feat), max_rows))
        showNotification(sprintf("Job too large: %d rows (limit %d).",
                                 nrow(feat), max_rows),
                         type = "error", duration = NULL)
        return()
      }

      lookup <- pq_match_samples(unique(feat$sample_id), ft$path, manual_map())
      lookup_r(lookup)

      n_unmatched <- sum(lookup$match %in% c("none", "ambiguous"))
      if (n_unmatched > 0) {
        append_log(sprintf("%d sample_id(s) could not be matched to a unique raw file.",
                           n_unmatched))
      }

      params <- list(
        mz_tol_unit = input$mz_tol_unit,
        mz_tol_ppm  = input$mz_tol_ppm,
        mz_tol_da   = input$mz_tol_da,
        xic_aggregate = input$xic_aggregate,
        rt_unit = input$rt_unit,
        rt_window = input$rt_window,
        min_points = input$min_points,
        smooth_points = input$smooth_points,
        eic_smooth_method = if (is.null(input$eic_smooth_method)) "none" else
          input$eic_smooth_method,
        eic_smooth_window = if (is.na(input$eic_smooth_window)) 7L else
          input$eic_smooth_window,
        eic_smooth_order = 2L,
        min_prominence_frac = input$min_prominence_frac,
        min_rel_prominence = input$min_rel_prominence,
        min_height_frac = input$min_height_frac,
        edge_frac = input$edge_frac,
        valley_frac = input$valley_frac,
        apex_tolerance = input$apex_tolerance,
        detect_absent = isTRUE(input$detect_absent),
        absent_snr = input$absent_snr,
        absent_min_points = input$absent_min_points,
        max_features = input$max_features,
        max_expanded_rows = max_rows,
        sample_scope = scope,
        sequential = TRUE
      )

      n_files_used <- length(unique(stats::na.omit(lookup$file)))
      append_log(sprintf("RUN START | %d row(s) from %d file(s) | table '%s'",
                         nrow(feat), n_files_used,
                         if (is.null(input$peak_table$name)) "?" else input$peak_table$name),
                 level = "RUN")
      append_log(sprintf("Processing %d feature row(s) from %d file(s).",
                         nrow(feat), n_files_used))
      append_log(sprintf(
        "Each file is parsed once; one parsed file is kept in memory at a time. %s",
        if (isTRUE(params$detect_absent)) {
          sprintf("Peaks below %.1f x the point-to-point noise are reported as absent, not scored.",
                  params$absent_snr)
        } else {
          "Peak presence detection is off: every row with an ion in the window is scored."
        }))

      # How long is this actually going to take? A 3450-feature aligned table in
      # 20 files is 69000 rows: ~10 min of scoring plus ~13 min of reading files
      # on this machine. Saying that up front is the difference between "it hung"
      # and "it needs half an hour".
      est <- pq_estimate_job(nrow(feat), n_files_used)
      append_log(sprintf(
        "Estimated time: %s (reading %d file(s) ~%s, scoring %d row(s) ~%s).",
        est$label, n_files_used, pq_format_duration(est$read_s),
        nrow(feat), pq_format_duration(est$row_s)))
      if (isTRUE(est$long)) {
        append_log(paste0(
          "LONG JOB: this run is expected to take ", est$label, ". The progress ",
          "bar keeps updating, but the log panel and the result tabs will not ",
          "refresh until it finishes. If the browser loses the connection, the ",
          "run keeps going and the result is written to ", PQ_RUN_DIR,
          " when the session ends."), level = "WARN")
        showNotification(
          sprintf(paste("This run is expected to take about %s (%d rows).",
                        "The page stays on the progress bar until it finishes."),
                  est$label, nrow(feat)),
          type = "warning", duration = 12)
      }


      if (!identical(as.character(params$eic_smooth_method), "none")) {
        append_log(paste0(
          pq_eic_smooth_label(params$eic_smooth_method,
                              params$eic_smooth_window,
                              params$eic_smooth_order),
          " is applied to the XIC before boundary detection and scoring. ",
          "The reported peak_cor/SNR are therefore NOT the author's raw-data ",
          "output and must not be compared with a run without smoothing. ",
          "Presence and the point-to-point noise stay on the raw trace."))
      }

      prog <- shiny::Progress$new()
      on.exit(prog$close(), add = TRUE)
      prog$set(message = "Extracting XIC and scoring", value = 0)

      t0 <- Sys.time()
      det <- tryCatch(
        pq_process_features(
          features = feat, params = params, file_lookup = lookup,
          ms_cache = new.env(parent = emptyenv()),
          log_fun = append_log,
          progress_fun = function(value, detail) {
            prog$set(value = min(0.99, value), detail = detail)
          }
        ),
        error = function(e) {
          append_log(paste0("FATAL: ", conditionMessage(e)))
          NULL
        }
      )
      elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

      if (is.null(det)) {
        append_log("RUN FAILED before any result was produced.", level = "ERROR")
        showNotification("Run failed, see the log.", type = "error")
        return()
      }

      # The extraction object is the memory peak of the whole run: 69000 rows
      # keep one XIC + one candidate table each. Report what it actually cost,
      # then hand the garbage back before the tables are built.
      g <- gc(verbose = FALSE)
      append_log(sprintf(
        "Extraction finished in %s | result %.0f MB | R heap in use %.0f MB (max %.0f MB).",
        pq_format_duration(elapsed),
        as.numeric(utils::object.size(det)) / 1024^2,
        sum(g[, "used"]), sum(g[, "max used"])), level = "MEM")

      results(det)
      features_ok(feat)
      run_snapshot$detail <- det$detail
      run_snapshot$rows <- det$rows


      # ---- optional second single-XIC method, same candidate peaks ----
      cpc_tbl(NULL); cpc_settings(NULL); group_diag(NULL); group_obj(NULL)
      cpc_ok <- FALSE
      if (isTRUE(input$method_cpc)) {
        av <- pq_cpc_available()
        if (!isTRUE(av$ok)) {
          append_log(paste0("CPC was ticked but is not available: ", av$reason))
        } else {
          append_log(sprintf(
            paste0("Running CPC %s on the same candidate peaks ",
                   "(it places its own boundaries; nothing is filtered)."), av$version))
          cpc_run <- tryCatch(
            pq_run_cpc(det$detail, det$rows, params,
                       max_rows = if (is.null(input$cpc_max_rows)) NULL else
                         as.integer(input$cpc_max_rows),
                       log_fun = append_log,
                       progress_fun = function(value, detail)
                         prog$set(value = 0.99, detail = detail)),
            error = function(e) {
              append_log(paste0("CPC FAILED: ", conditionMessage(e)))
              NULL
            })
          if (!is.null(cpc_run)) {
            cpc_tbl(cpc_run$table)
            cpc_settings(cpc_run$settings)
            cpc_ok <- TRUE
          }
        }
      }

      # ---- optional DNN on cross-sample peak groups ----
      # Separate from CPC: CPC scores a single peak's shape, the DNN looks at the
      # whole aligned group. Neither contributes to `quality_class`.
      dnn_result(NULL); dnn_ok <- FALSE
      if (isTRUE(input$method_dnn)) {
        paths <- pq_dnn_paths(getwd())
        mi <- pq_dnn_find_model(paths)
        if (!isTRUE(mi$available)) {
          msg <- pq_dnn_unavailable_message(paths)
          append_log(paste0("DNN was ticked but cannot run: ", msg))
          dnn_result(list(ok = FALSE, status = mi$status, detail = msg,
                          rows = pq_dnn_attach(det$rows, NULL, mi)))
        } else {
          thr <- if (is.null(input$dnn_threshold)) 0.5
                 else as.numeric(input$dnn_threshold)
          n_feat <- length(unique(det$rows$feature_id))
          append_log(sprintf("Running DNN %s on %d peak group(s), threshold %.4f",
                             substr(mi$sha256, 1, 12), n_feat, thr))
          dr <- tryCatch(
            pq_dnn_apply(
              det$rows, det$detail, paths, model_info = mi, threshold = thr,
              progress = function(k, n)
                prog$set(value = 0.99,
                         detail = sprintf("DNN peak group %d/%d", k, n))),
            error = function(e) {
              append_log(paste0("DNN FAILED: ", conditionMessage(e)))
              NULL
            })
          if (is.null(dr)) {
            dnn_result(list(ok = FALSE, status = "error",
                            detail = "the DNN run raised an error, see the log",
                            rows = pq_dnn_attach(det$rows, NULL, mi)))
          } else {
            dnn_result(dr)
            dnn_ok <- isTRUE(dr$ok)
            if (dnn_ok) {
              # The attached table is what gets displayed and exported; the
              # quality class inside it was not touched.
              #
              # Keep the SHAPE of `results()`: it is the list returned by
              # pq_process_features() (rows + detail), and every consumer reads
              # det$rows. Putting the bare data.frame here made `det$rows` NULL
              # and every downstream view fail with
              #   "Error in if: missing value where TRUE/FALSE needed" and
              #   "Error in [: incorrect number of dimensions" -
              # only when the DNN had actually run.
              det$rows <- dr$rows
              results(det)
              run_snapshot$rows <- det$rows
              n_scored <- sum(!is.na(dr$rows$dnn_score))
              append_log(sprintf(
                "DNN scored %d feature(s); %d at or below the threshold. Geometry: %s",
                n_scored, sum(dr$rows$dnn_prediction %in% 0),
                if (isTRUE(dr$input_approx))
                  "converted from the native 31x200 to the model grid" else "native"))
              # "0 below the threshold" reads like good news even when it is the
              # opposite: if every score sits at 0.97+ the threshold separates
              # nothing at all. Show the spread so that case cannot be missed.
              sc <- dr$rows$dnn_score[!is.na(dr$rows$dnn_score)]
              if (n_scored > 0L) {
                append_log(sprintf(
                  "DNN score spread: min %.4f, median %.4f, max %.4f (range %.4f).",
                  min(sc), stats::median(sc), max(sc), max(sc) - min(sc)))
                if (max(sc) - min(sc) < 0.10) {
                  append_log(paste0(
                    "WARNING: the DNN scores barely vary, so the threshold cannot ",
                    "separate anything on this cohort. The image layout encodes how ",
                    "many samples are present, and with a small cohort every group ",
                    "looks 'complete' - this is the known sample-count dependence, ",
                    "not evidence that all peaks are good. Do not read the DNN ",
                    "column as a quality filter on this run."))
                }
              }
              if (isTRUE(dr$input_approx)) {
                append_log(paste0(
                  "Note: DNN input was converted, not native to the model. The score ",
                  "is a model output, not a calibrated probability, and is not ",
                  "interchangeable with the paper's operating point."))
              }
              if (n_scored == 0L) {
                append_log(paste0("DNN produced no score for any feature: ",
                                  dr$detail))
              }
            } else {
              append_log(paste0("DNN produced no score: ", dr$detail))
            }
          }
        }
      }

      run_meta(list(
        params = params, mapping = map, lookup = lookup,
        n_rows_input = nrow(df), n_rows_valid = nrow(feat),
        n_bad = if (is.null(std$bad)) 0L else nrow(std$bad),
        elapsed = elapsed,
        files = ft,
        cpc_run = cpc_ok,
        dnn_run = dnn_ok,
        methods = c("kumler", if (cpc_ok) "cpc", if (dnn_ok) "dnn"),
        started = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
      ))

      rows <- det$rows
      append_log(sprintf(
        paste0("Done in %.1f s. scored=%d, absent=%d, ambiguous=%d,",
               " unclear boundary=%d, no signal=%d, unmatched=%d"),
        elapsed,
        sum(rows$score_status == "ok"),
        sum(rows$presence %in% "absent"),
        sum(rows$boundary_status == "ambiguous"),
        sum(rows$boundary_status == "boundary_unclear"),
        sum(rows$boundary_status == "no_signal"),
        sum(rows$boundary_status %in% c("sample_unmatched", "sample_ambiguous"))
      ))
      cp <- cpc_tbl()
      if (!is.null(cp)) {
        st <- as.character(cp$cpc_status)
        append_log(sprintf(
          "CPC: ok=%d, not detected=%d, too few points=%d, failed=%d, absent=%d, not run=%d.",
          sum(st %in% "ok", na.rm = TRUE),
          sum(st %in% "not_detected", na.rm = TRUE),
          sum(st %in% "too_few_points", na.rm = TRUE),
          sum(st %in% "failed", na.rm = TRUE),
          sum(st %in% "absent", na.rm = TRUE),
          sum(st %in% "not_run", na.rm = TRUE)))
        append_log(paste("Both methods are shown side by side in the 'Compare methods' tab.",
                         "Their scores are never averaged or ranked together."))
      }

      showNotification("Peak quality assessment finished.", type = "message")
      updateTabsetPanel(session, "result_tabs", selected = "Results")
      append_log(sprintf("RUN END | total %.1f s", elapsed), level = "RUN")
    })

    # ============================================================
    # 4. Result table
    # ============================================================
    # Verdicts are derived from the result rows + the CPC table. Computed once
    # per change and reused by the table, the cards and the exports, so the
    # screen and the file can never disagree.
    classified_rows <- reactive({
      det <- results()
      if (is.null(det)) return(NULL)
      pq_classify_rows(det$rows, cpc_tbl())
    })

    display_rows <- reactive({
      rows <- classified_rows()
      # A table is required. If an upstream change ever hands us something else,
      # say so in the log and show the "no result" state instead of letting the
      # viewer die with "incorrect number of dimensions".
      if (!is.data.frame(rows)) {
        if (!is.null(rows)) {
          append_log(paste0("Result table unavailable: classified_rows() returned ",
                            paste(class(rows), collapse = "/"),
                            " instead of a data.frame."))
        }
        return(NULL)
      }
      pf <- if (is.null(input$presence_filter)) "all" else input$presence_filter
      if (identical(pf, "present")) {
        rows <- rows[rows$presence %in% "present", , drop = FALSE]
      } else if (identical(pf, "absent")) {
        rows <- rows[rows$presence %in% "absent", , drop = FALSE]
      }
      if (isTRUE(input$only_problems)) {
        # an absent peak is a valid answer, not a problem to review
        keep <- !rows$presence %in% "absent" &
          (rows$score_status != "ok" | rows$boundary_status != "ok")
        rows <- rows[keep, , drop = FALSE]
      }
      rows[, pq_result_columns(rows), drop = FALSE]
    })

    # Four-class counts. `unknown` is shown next to the others on purpose: a
    # large unknown share is information, not something to hide.
    output$quality_cards <- renderUI({
      rows <- classified_rows()
      # Same guard as display_rows: `if (nrow(rows) == 0)` on a non-table aborts
      # the whole card strip with "missing value where TRUE/FALSE needed".
      if (!is.data.frame(rows) || nrow(rows) == 0L) return(NULL)
      s <- pq_class_summary(rows)
      tone <- c(high_quality = "ok", poor_quality = "warn",
                likely_noise = "bad", unknown = "neutral")
      div(class = "pq-cards",
          lapply(seq_len(nrow(s)), function(i) {
            div(class = paste0("pq-card pq-card--", tone[[s$quality_class[i]]]),
                div(class = "pq-card__value", s$n[i]),
                div(class = "pq-card__label",
                    sprintf("%s (%.1f%%)", pq_quality_label(s$quality_class[i]),
                            s$pct[i])))
          }),
          div(class = "pq-card pq-card--neutral",
              div(class = "pq-card__value", "draft"),
              div(class = "pq-card__label",
                  paste("Provisional rules - not a validated classifier;",
                        "see Parameters & provenance")))
      )
    })

    # ============================================================
    # 4b. Cross-software view
    # ============================================================
    software_table <- reactive({
      rows <- classified_rows()
      if (is.null(rows) || nrow(rows) == 0) return(NULL)
      pq_class_by_software(rows)
    })

    output$software_note_ui <- renderUI({
      rows <- classified_rows()
      if (is.null(rows) || nrow(rows) == 0) return(NULL)
      tags$ul(class = "text-muted", style = "margin: 0 0 10px 0; padding-left: 18px;",
              lapply(pq_software_compare_note(rows), function(x) tags$li(x)))
    })

    output$software_table <- renderDT({
      sw <- software_table()
      if (is.null(sw) || nrow(sw) == 0) {
        return(DT::datatable(
          data.frame(Status = "No result yet - run an analysis first"),
          rownames = FALSE, options = list(dom = "t")))
      }
      out <- sw
      out$quality_class_label <- pq_quality_label(out$quality_class)
      out$ci <- sprintf("%.1f - %.1f", out$ci_low, out$ci_high)
      out <- out[, c("software", "quality_class_label", "n", "denominator",
                     "pct", "ci")]
      names(out) <- c("Software", "Quality class", "n", "Denominator",
                      "Percent", "95% CI (Wilson)")
      DT::datatable(out, rownames = FALSE,
                    options = list(pageLength = 20, dom = "t",
                                   order = list(list(0, "asc"), list(1, "asc")))) |>
        DT::formatStyle("Quality class",
          backgroundColor = DT::styleEqual(
            c("High quality", "Poor quality", "Likely noise", "Cannot tell"),
            c("#ecfdf5", "#fffbeb", "#fef2f2", "#f1f5f9")))
    })

    output$software_metrics_table <- renderDT({
      rows <- classified_rows()
      if (is.null(rows) || nrow(rows) == 0) {
        return(DT::datatable(
          data.frame(Status = "No result yet - run an analysis first"),
          rownames = FALSE, options = list(dom = "t")))
      }
      m <- pq_metrics_by_software(rows)
      names(m) <- c("Software", "Metric", "n", "Median", "5th pct", "95th pct")
      DT::datatable(m, rownames = FALSE,
                    options = list(pageLength = 25, dom = "t"))
    })

    output$software_class_table <- renderDT({
      sw <- software_table()
      if (is.null(sw) || nrow(sw) == 0) {
        return(DT::datatable(
          data.frame(Status = "No result yet - run an analysis first"),
          rownames = FALSE, options = list(dom = "t")))
      }
      # one row per software, one count column per class, never a total score
      keys <- sort(unique(sw$software))
      wide <- do.call(rbind, lapply(keys, function(k) {
        s <- sw[sw$software == k, , drop = FALSE]
        row <- list(Software = k,
                    Candidates = unique(s$denominator)[1])
        for (cl in PQ_QUALITY_CLASSES) {
          hit <- s[s$quality_class == cl, , drop = FALSE]
          row[[pq_quality_label(cl)]] <- if (nrow(hit)) hit$n[1] else 0L
        }
        as.data.frame(row, stringsAsFactors = FALSE, check.names = FALSE)
      }))
      DT::datatable(wide, rownames = FALSE,
                    options = list(pageLength = 20, dom = "t"))
    })

    output$dl_software <- downloadHandler(
      filename = function() {
        paste0("peak_quality_by_software_", format(Sys.Date(), "%Y%m%d"), ".csv")
      },
      content = function(file) {
        sw <- software_table()
        req(sw)
        utils::write.csv(sw, file, row.names = FALSE, na = "")
      }
    )

    # ---------------- DNN (separate method, separate page) ----------------
    # The model is discovered once per session. Nothing here trains: training is
    # a deliberate command-line action, because a UI click must never start a
    # run that takes minutes.
    dnn_info <- reactive({
      pq_dnn_find_model(pq_dnn_paths(getwd()))
    })

    output$dnn_available_ui <- renderUI({
      m <- dnn_info()
      if (isTRUE(m$available)) {
        div(class = "mini-summary mini-summary--ok",
            sprintf("Model available - %s, trained %s",
                    substr(m$sha256, 1, 12), m$trained_at))
      } else {
        div(class = "mini-summary mini-summary--warn",
            pq_dnn_unavailable_message(pq_dnn_paths(getwd())))
      }
    })

    # What the last run actually did. Without this, an empty prediction table
    # reads as "the model liked nothing", when in fact it may never have run.
    output$dnn_run_ui <- renderUI({
      r <- dnn_result()
      if (is.null(r)) {
        return(div(class = "mini-summary",
                   "No DNN run yet. Tick the DNN box above and press Run."))
      }
      if (isTRUE(r$ok)) {
        rows <- r$rows
        n <- sum(!is.na(rows$dnn_score))
        n_rej <- sum(rows$dnn_prediction %in% 0, na.rm = TRUE)
        thr <- if (is.null(r$threshold)) 0.5 else r$threshold
        geo <- if (isTRUE(r$input_approx))
          "input converted from the native 31x200 to the model grid" else
          "input was already on the model grid"
        div(class = "mini-summary mini-summary--ok",
            sprintf("%d feature(s) scored, %d at or below %.4f. %s.",
                    n, n_rej, thr, geo))
      } else {
        st <- if (is.null(r$status)) "unknown" else r$status
        dt <- if (is.null(r$detail)) "" else r$detail
        div(class = "mini-summary mini-summary--warn",
            sprintf("DNN did not produce a score (%s): %s", st, dt))
      }
    })

    output$dnn_status_table <- renderDT({
      st <- pq_dnn_status_table(pq_dnn_paths(getwd()))
      names(st) <- c("Item", "Value")
      DT::datatable(st, rownames = FALSE,
                    options = list(dom = "t", pageLength = 20,
                                   columnDefs = list(
                                     list(width = "280px", targets = 0))))
    })

    output$dnn_meaning_ui <- renderText({
      pq_dnn_score_note()
    })

    output$dnn_separation_ui <- renderText({
      pq_dnn_class_separation_note()
    })

    # One row per feature: the model never sees a single (feature, sample).
    dnn_table <- reactive({
      rows <- results()$rows
      if (is.null(rows) || !"dnn_input_status" %in% names(rows)) return(NULL)
      keep <- !is.na(rows$dnn_input_status) & rows$dnn_input_status != "unavailable"
      if (!any(keep)) return(NULL)
      out <- rows[keep, c("feature_id", "dnn_model_version", "dnn_input_status",
                          "dnn_prediction", "dnn_score", "dnn_threshold",
                          "dnn_applicability", "dnn_error"), drop = FALSE]
      out[!duplicated(out$feature_id), , drop = FALSE]
    })

    output$dnn_pred_table <- renderDT({
      d <- dnn_table()
      if (is.null(d) || nrow(d) == 0) {
        return(DT::datatable(
          data.frame(Status = "DNN prediction unavailable: model weights not available"),
          rownames = FALSE, options = list(dom = "t")))
      }
      out <- d
      names(out) <- c("Feature", "Model", "Input", "Prediction", "Score",
                      "Threshold", "Applicability", "Error")
      DT::datatable(out, rownames = FALSE,
                    options = list(pageLength = 20, dom = "tip")) |>
        DT::formatRound("Score", 4)
    })

    output$dl_dnn <- downloadHandler(
      filename = function() {
        paste0("peak_quality_dnn_", format(Sys.Date(), "%Y%m%d"), ".csv")
      },
      content = function(file) {
        d <- dnn_table()
        req(d)
        utils::write.csv(d, file, row.names = FALSE, na = "")
      }
    )

    # ---- what the network actually saw -------------------------------
    # A score without its input is not checkable. This shows the exact matrix
    # that was written to disk and scored, in the model's own orientation
    # (rows = RT slices, columns = samples with the marker in the last one),
    # which is deliberately different from the diagnostic image in the Peak
    # group tab.
    dnn_group_meta <- reactive({
      r <- dnn_result()
      if (is.null(r) || is.null(r$batch)) return(NULL)
      r$batch$meta
    })

    output$dnn_image_ui <- renderUI({
      m <- dnn_group_meta()
      if (is.null(m) || nrow(m) == 0) {
        return(div(class = "mini-summary",
                   paste("No peak-group matrix was built in this run.",
                         "Run with the DNN ticked to see the model input.")))
      }
      ok <- m$feature_id[!is.na(m$image_ok) & m$image_ok]
      if (length(ok) == 0) {
        return(div(class = "mini-summary mini-summary--warn",
                   paste("Every peak group failed to produce an image:",
                         paste(unique(m$image_status), collapse = ", "))))
      }
      tagList(
        selectInput(ns("dnn_group_pick"), NULL, choices = ok,
                    width = "320px"),
        plotly::plotlyOutput(ns("dnn_image"), height = "420px")
      )
    })

    output$dnn_image <- plotly::renderPlotly({
      r <- dnn_result()
      req(r, r$batch, input$dnn_group_pick)
      i <- match(input$dnn_group_pick, r$batch$meta$feature_id)
      if (is.na(i)) return(plotly::plotly_empty())
      pq_plot_model_input_image(r$batch$images[[i]],
                                feature_id = r$batch$meta$feature_id[i],
                                meta = r$batch$meta[i, , drop = FALSE])
    })

    # The contract checks, per feature, so a rejected input is visible as a
    # check that failed rather than as a mysteriously missing score.
    output$dnn_check_table <- renderDT({
      r <- dnn_result()
      g <- if (is.null(r)) NULL else r$guard
      if (is.null(g) || is.null(g$table) || nrow(g$table) == 0) {
        return(DT::datatable(
          data.frame(Check = "no DNN input was validated in this run"),
          rownames = FALSE, options = list(dom = "t")))
      }
      out <- g$table
      names(out) <- c("Feature", "Input status", "Accepted", "Reason",
                      "Failed checks")
      DT::datatable(out, rownames = FALSE,
                    options = list(pageLength = 15, dom = "tip"))
    })

    # ============================================================
    # Three methods - side by side, never combined
    # ============================================================
    # GroupResults (one row per feature) and SampleResults (one row per
    # feature x sample) are the two published tables; the third block puts one
    # number from each method next to the others for reading only. No column is
    # derived from two methods and there is no total.
    group_results_tbl <- reactive({
      r <- results()
      if (is.null(r)) return(NULL)
      pq_group_results(r$rows)
    })

    sample_results_tbl <- reactive({
      r <- results()
      if (is.null(r)) return(NULL)
      pq_sample_results(r$rows, cpc_tbl())
    })

    three_method_tbl <- reactive({
      g <- group_results_tbl()
      s <- sample_results_tbl()
      if (is.null(g) || nrow(g) == 0) return(NULL)

      k_ok <- !is.na(s$kumler_status) & s$kumler_status == "ok"
      c_ok <- !is.na(s$cpc_status) & s$cpc_status == "ok"

      kmed <- tapply(ifelse(k_ok, s$kumler_peak_cor, NA_real_), s$feature_id,
                     function(x) if (all(is.na(x))) NA_real_ else
                       stats::median(x, na.rm = TRUE))
      cmed <- tapply(ifelse(c_ok, s$cpc_fwhm, NA_real_), s$feature_id,
                     function(x) if (all(is.na(x))) NA_real_ else
                       stats::median(x, na.rm = TRUE))

      out <- data.frame(
        feature_id = g$feature_id,
        n_samples = g$n_samples,
        n_present = g$n_present,
        n_absent = g$n_absent,
        n_unknown = g$n_unknown,
        kumler_n_ok = as.integer(tapply(k_ok, s$feature_id, sum)[g$feature_id]),
        kumler_median_peak_cor = as.numeric(kmed[g$feature_id]),
        cpc_n_ok = as.integer(tapply(c_ok, s$feature_id, sum)[g$feature_id]),
        cpc_median_fwhm = as.numeric(cmed[g$feature_id]),
        dnn_scope = g$dnn_scope,
        dnn_score = g$dnn_score,
        dnn_prediction = g$dnn_prediction,
        stringsAsFactors = FALSE
      )
      out$kumler_n_ok[is.na(out$kumler_n_ok)] <- 0L
      out$cpc_n_ok[is.na(out$cpc_n_ok)] <- 0L
      out
    })

    output$group_results_table <- renderDT({
      g <- group_results_tbl()
      if (is.null(g) || nrow(g) == 0) {
        return(DT::datatable(data.frame(Status = "no results yet"),
                             rownames = FALSE, options = list(dom = "t")))
      }
      out <- g
      names(out) <- c("Feature", "m/z", "RT reference (min)", "RT source",
                      "n samples", "present", "absent", "unknown",
                      "DNN status", "DNN scope", "DNN model", "DNN input",
                      "DNN prediction", "DNN score", "DNN threshold",
                      "DNN applicability", "DNN error")
      DT::datatable(out, rownames = FALSE,
                    options = list(pageLength = 15, dom = "tip", scrollX = TRUE)) |>
        DT::formatRound(c("RT reference (min)", "DNN score", "DNN threshold"), 4)
    })

    output$sample_results_table <- renderDT({
      s <- sample_results_tbl()
      if (is.null(s) || nrow(s) == 0) {
        return(DT::datatable(data.frame(Status = "no results yet"),
                             rownames = FALSE, options = list(dom = "t")))
      }
      # CPC and DNN columns are shown only when they carry something, so an
      # unrun method does not look like a column of zeros.
      keep <- c("feature_id", "sample_id", "raw_file", "rt_reference",
                "sample_rt_apex", "presence_status", "boundary_status",
                "kumler_peak_cor", "kumler_snr", "kumler_status")
      if (any(!is.na(s$cpc_status) & s$cpc_status != "not_run")) {
        keep <- c(keep, "cpc_rt", "cpc_rtmin", "cpc_rtmax", "cpc_fwhm",
                  "cpc_tf", "cpc_area", "cpc_sn", "cpc_status")
      }
      if (any(!is.na(s$dnn_scope))) keep <- c(keep, "dnn_scope", "dnn_score")
      keep <- c(keep, "xic_smoothing", "ppm_tolerance", "rt_window",
                "method_errors")
      out <- s[, intersect(keep, names(s)), drop = FALSE]
      DT::datatable(out, rownames = FALSE,
                    options = list(pageLength = 15, dom = "tip", scrollX = TRUE)) |>
        DT::formatRound(c("kumler_peak_cor", "kumler_snr", "cpc_rt",
                          "cpc_rtmin", "cpc_rtmax", "cpc_fwhm", "cpc_tf",
                          "cpc_sn", "dnn_score"), 4)
    })

    output$three_method_table <- renderDT({
      d <- three_method_tbl()
      if (is.null(d) || nrow(d) == 0) {
        return(DT::datatable(data.frame(Status = "no results yet"),
                             rownames = FALSE, options = list(dom = "t")))
      }
      out <- d
      names(out) <- c("Feature", "n samples", "present", "absent", "unknown",
                      "Kumler n ok", "Kumler median peak_cor",
                      "CPC n ok", "CPC median FWHM (min)",
                      "DNN scope", "DNN score", "DNN prediction")
      DT::datatable(out, rownames = FALSE,
                    options = list(pageLength = 15, dom = "tip", scrollX = TRUE)) |>
        DT::formatRound(c("Kumler median peak_cor", "CPC median FWHM (min)",
                          "DNN score"), 4)
    })

    output$dl_groups <- downloadHandler(
      filename = function() {
        paste0("peak_quality_group_results_", format(Sys.Date(), "%Y%m%d"), ".csv")
      },
      content = function(file) {
        g <- group_results_tbl()
        req(g)
        utils::write.csv(g, file, row.names = FALSE, na = "")
      }
    )

    output$dl_samples <- downloadHandler(
      filename = function() {
        paste0("peak_quality_sample_results_", format(Sys.Date(), "%Y%m%d"), ".csv")
      },
      content = function(file) {
        s <- sample_results_tbl()
        req(s)
        utils::write.csv(s, file, row.names = FALSE, na = "")
      }
    )

    # Only the browser view is capped; the exports always carry every row.
    display_note <- reactive({
      rows <- display_rows()
      if (is.null(rows) || nrow(rows) <= PQ_DISPLAY_ROWS) return(NULL)
      sprintf(paste("Showing the first %d of %d rows - the browser table is",
                    "capped for speed. CSV, XLSX and the ZIP report contain",
                    "all %d rows."),
              PQ_DISPLAY_ROWS, nrow(rows), nrow(rows))
    })

    output$status_cards <- renderUI({
      det <- results()
      if (is.null(det) || is.null(det$rows)) return(NULL)
      rows <- det$rows
      n <- nrow(rows)
      ok <- sum(rows$score_status == "ok")
      absent <- sum(rows$presence %in% "absent")
      amb <- sum(rows$boundary_status == "ambiguous")
      unclear <- sum(rows$boundary_status == "boundary_unclear")
      fail <- sum(!rows$score_status %in% c("ok", "absent"))
      div(class = "pq-cards",
          lapply(list(
            list(n, "rows evaluated", "neutral"),
            list(ok, "score ok", "ok"),
            list(absent, "no peak in sample", "neutral"),
            list(amb, "ambiguous", "warn"),
            list(unclear, "boundary unclear", "warn"),
            list(fail, "not scored (other)", "bad")
          ), function(x) {
            div(class = paste0("pq-card pq-card--", x[[3]]),
                div(class = "pq-card__value", x[[1]]),
                div(class = "pq-card__label", x[[2]]))
          })
      )
    })

    output$results_table <- renderDT({
      rows <- display_rows()
      if (is.null(rows)) {
        return(DT::datatable(
          data.frame(Status = "No result yet - configure the inputs and press Run"),
          rownames = FALSE, options = list(dom = "t")))
      }
      note <- display_note()
      if (!is.null(note) && nrow(rows) > PQ_DISPLAY_ROWS) {
        rows <- utils::head(rows, PQ_DISPLAY_ROWS)
      }
      numeric_cols <- c("mz", "input_rt", "start_rt", "apex_rt", "end_rt",
                        "peak_cor", "SNR", "apex_offset", "median_ppm_dev")
      for (cc in intersect(numeric_cols, names(rows))) {
        rows[[cc]] <- round(rows[[cc]], 5)
      }
      cap <- if (is.null(note)) {
        "Low-scoring peaks are never removed automatically - use the status columns to review."
      } else {
        paste(note,
              "Low-scoring peaks are never removed automatically.")
      }
      dt <- DT::datatable(
        rows, rownames = FALSE, filter = "top",
        options = list(pageLength = 15, scrollX = TRUE, autoWidth = TRUE,
                       columnDefs = list(list(className = "dt-center",
                                              targets = "_all"))),
        caption = cap
      )
      if ("boundary_status" %in% names(rows)) {
        dt <- DT::formatStyle(dt, "boundary_status",
          backgroundColor = DT::styleEqual(
            c("ok", "ambiguous", "boundary_unclear", "too_few_points",
              "no_signal", "no_clear_apex", "apex_outside",
              "sample_unmatched", "sample_ambiguous", "file_error"),
            c("#ecfdf5", "#fffbeb", "#fffbeb", "#fffbeb",
              "#fef2f2", "#fef2f2", "#fef2f2",
              "#fef2f2", "#fef2f2", "#fef2f2"))
        )
      }
      if ("score_status" %in% names(rows)) {
        dt <- DT::formatStyle(dt, "score_status",
          backgroundColor = DT::styleEqual(
            c("ok", "skipped", "failed", "not_finite", "not_run", "absent"),
            c("#ecfdf5", "#fffbeb", "#fef2f2", "#fef2f2", "#f1f5f9", "#eef2f7"))
        )
      }
      if ("presence" %in% names(rows)) {
        dt <- DT::formatStyle(dt, "presence",
          backgroundColor = DT::styleEqual(
            c("present", "absent", "unknown"),
            c("#ecfdf5", "#eef2f7", "#f1f5f9"))
        )
      }
      if ("quality_class" %in% names(rows)) {
        dt <- DT::formatStyle(dt, "quality_class",
          backgroundColor = DT::styleEqual(
            c("high_quality", "poor_quality", "likely_noise", "unknown"),
            c("#ecfdf5", "#fffbeb", "#fef2f2", "#f1f5f9"))
        )
      }
      dt
    })

    # feature-level summary (one row per feature, across all its samples)
    feature_summary <- reactive({
      det <- results()
      if (is.null(det)) return(NULL)
      pq_feature_summary(det$rows)
    })

    output$feature_summary_table <- renderDT({
      sm <- feature_summary()
      if (is.null(sm) || nrow(sm) == 0) {
        return(DT::datatable(
          data.frame(Status = "No result yet - configure the inputs and press Run"),
          rownames = FALSE, options = list(dom = "t")))
      }
      dt <- DT::datatable(
        sm, rownames = FALSE, filter = "top",
        options = list(pageLength = 15, scrollX = TRUE, autoWidth = TRUE,
                       columnDefs = list(list(className = "dt-center",
                                              targets = "_all"))),
        caption = paste("Descriptive summary: median and worst per-sample value",
                        "are both kept. Not a pass/fail decision.")
      )
      DT::formatStyle(dt, "consistency",
        backgroundColor = DT::styleEqual(
          c("consistent", "variable", "poor", "single_sample",
            "absent_everywhere", "not_evaluated"),
          c("#ecfdf5", "#fffbeb", "#fef2f2", "#f1f5f9", "#eef2f7", "#fef2f2"))
      )
    })

    # ============================================================
    # 4b. Compare methods (no combined score anywhere)
    # ============================================================
    compare_wide <- reactive({
      det <- results()
      if (is.null(det)) return(NULL)
      pq_wide_compare(det$rows, cpc_tbl())
    })

    output$compare_empty_ui <- renderUI({
      det <- results()
      if (is.null(det)) {
        return(div(class = "mini-summary mini-summary--muted",
                   "Run an assessment first."))
      }
      if (is.null(cpc_tbl())) {
        return(div(class = "mini-summary mini-summary--warn",
          paste("CPC was not run for this job. Tick 'CPC' in section 7 and",
                "press Run again; both methods are then evaluated on the same",
                "candidate peaks and shown side by side.")))
      }
      NULL
    })

    output$compare_cards <- renderUI({
      wide <- compare_wide()
      if (is.null(wide)) return(NULL)
      sm <- pq_agreement_summary(wide)
      get <- function(cat) {
        v <- sm$value[sm$category == cat]
        if (length(v) == 0 || all(is.na(v))) "NA" else format(round(v, 4))
      }
      cnt <- function(cat) {
        v <- sm$n[sm$category == cat]
        if (length(v) == 0 || is.na(v)) 0L else as.integer(v)
      }
      div(class = "pq-cards",
        lapply(list(
          list(cnt("both_scored"), "both methods scored", "ok"),
          list(cnt("kumler_only"), "Kumler only", "warn"),
          list(cnt("cpc_only"), "CPC only", "warn"),
          list(cnt("neither"), "neither scored", "bad"),
          list(get("median |d apex RT| (min)"), "median |d apex RT| (min)", "neutral")
        ), function(x) {
          div(class = paste0("pq-card pq-card--", x[[3]]),
              div(class = "pq-card__value", x[[1]]),
              div(class = "pq-card__label", x[[2]]))
        })
      )
    })

    output$compare_summary <- renderDT({
      wide <- compare_wide()
      sm <- pq_agreement_summary(wide)
      if (is.null(sm)) {
        return(DT::datatable(data.frame(Status = "Nothing to compare yet"),
                             rownames = FALSE, options = list(dom = "t")))
      }
      DT::datatable(sm, rownames = FALSE,
                    options = list(dom = "t", pageLength = 12, scrollX = TRUE))
    })

    output$compare_table <- renderDT({
      wide <- compare_wide()
      if (is.null(wide)) {
        return(DT::datatable(data.frame(Status = "Nothing to compare yet"),
                             rownames = FALSE, options = list(dom = "t")))
      }
      f <- if (is.null(input$compare_filter)) "disagree" else input$compare_filter
      if (identical(f, "disagree")) {
        wide <- wide[wide$method_agreement %in% c("kumler_only", "cpc_only", "neither"), ,
                     drop = FALSE]
      } else if (!identical(f, "all")) {
        wide <- wide[wide$method_agreement %in% f, , drop = FALSE]
      }
      n_all <- nrow(wide)
      shown <- utils::head(wide, PQ_DISPLAY_ROWS)
      num <- vapply(shown, is.numeric, logical(1))
      shown[num] <- lapply(shown[num], function(x) round(x, 5))
      DT::datatable(
        shown, rownames = FALSE, filter = "top",
        options = list(pageLength = 12, scrollX = TRUE, autoWidth = TRUE),
        caption = sprintf(paste("%d row(s) match this view%s. Every column belongs",
                                "to one method; nothing is combined."),
                          n_all,
                          if (n_all > nrow(shown)) sprintf(" (first %d shown)", nrow(shown)) else "")
      )
    })

    output$metrics_table <- renderDT({
      det <- results()
      if (is.null(det)) {
        return(DT::datatable(data.frame(Status = "No result yet"),
                             rownames = FALSE, options = list(dom = "t")))
      }
      m <- pq_metrics_long(det$rows, cpc_tbl())
      if (is.null(m) || nrow(m) == 0) {
        return(DT::datatable(data.frame(Status = "No metric"), rownames = FALSE,
                             options = list(dom = "t")))
      }
      shown <- utils::head(m, 3000)
      shown$value <- signif(shown$value, 6)
      DT::datatable(shown, rownames = FALSE,
                    options = list(pageLength = 12, scrollX = TRUE),
                    caption = sprintf("%d metric row(s) in total%s - the export carries all of them.",
                                      nrow(m),
                                      if (nrow(m) > nrow(shown)) " (first 3000 shown)" else ""))
    })

    output$unified_preview <- renderDT({
      det <- results()
      if (is.null(det)) {
        return(DT::datatable(data.frame(Status = "No result yet"),
                             rownames = FALSE, options = list(dom = "t")))
      }
      u <- pq_unified_from_run(det$rows, cpc_tbl(), run_meta()$params,
                               cpc_settings = cpc_settings())
      shown <- utils::head(u, 500)
      num <- vapply(shown, is.numeric, logical(1))
      shown[num] <- lapply(shown[num], function(x) signif(x, 6))
      DT::datatable(shown, rownames = FALSE,
                    options = list(pageLength = 10, scrollX = TRUE),
                    caption = sprintf("%d unified row(s) in total; 500 shown. raw_score is empty for CPC (metric profile), quality_probability is empty for both.",
                                      nrow(u)))
    })

    output$dl_compare <- downloadHandler(
      filename = function() paste0("peak_quality_compare_",
                                   format(Sys.Date(), "%Y%m%d"), ".csv"),
      content = function(file) {
        wide <- compare_wide()
        req(wide)
        utils::write.csv(wide, file, row.names = FALSE, na = "")
      }
    )

    # ============================================================
    # 4c. Cross-sample peak groups (DNN input, no model)
    # ============================================================
    group_params <- reactive({
      pq_default_group_params() |>
        utils::modifyList(list(
          n_slices = if (is.null(input$group_n_slices)) 64L else
            as.integer(input$group_n_slices),
          min_series = if (is.null(input$group_min_series)) 2L else
            as.integer(input$group_min_series),
          pad_rows = if (isTRUE(input$group_pad)) 63L else 0L
        ))
    })

    output$group_intro_ui <- renderUI({
      card_panel("Why there is no probability here", "circle-exclamation",
        p(class = "text-muted",
          paste("The Kantz 2019 repository publishes the image construction and",
                "the training scripts, but no trained weights:",
                "ApplyPeakPredictionModel.R still contains the placeholder",
                "modelFile <- 'modelFileName.h5'. A classification probability",
                "can therefore not be reproduced, and none is invented here.",
                "This tab builds the peak-group image exactly as the author's",
                "peakGroupImageMatrixAndPlot.R does and reports which samples",
                "of each group are missing or unusable."))
      )
    })

    output$group_selector <- renderUI({
      det <- results()
      if (is.null(det)) return(NULL)
      feats <- unique(det$rows$feature_id)
      feats <- utils::head(feats, PQ_PEAK_CHOICES)
      selectizeInput(ns("group_feature"), "Feature to inspect",
                     choices = feats, selected = feats[1], width = "100%",
                     options = list(maxOptions = 5000))
    })

    observeEvent(input$group_feature, {
      det <- results()
      req(det, input$group_feature)
      group_obj(pq_peak_group(det$rows, det$detail, input$group_feature,
                              group_params()))
    }, ignoreInit = FALSE)

    observeEvent(input$build_groups, {
      det <- results()
      if (is.null(det)) {
        showNotification("Run an assessment first.", type = "error"); return()
      }
      prog <- shiny::Progress$new(); on.exit(prog$close(), add = TRUE)
      prog$set(message = "Building peak-group diagnostics", value = 0)
      g <- pq_peak_group_table(det$rows, det$detail, group_params(),
                               progress_fun = function(v, d)
                                 prog$set(value = v, detail = d))
      group_diag(g)
      append_log(sprintf("Peak-group diagnostics built for %d feature(s).", nrow(g)))
    })

    output$group_plot_ui <- renderUI({
      det <- results()
      if (is.null(det)) {
        return(div(class = "mini-summary mini-summary--muted",
                   "Run an assessment to inspect peak groups"))
      }
      if (!requireNamespace("plotly", quietly = TRUE)) {
        return(div(class = "mini-summary mini-summary--warn",
                   "plotly is not installed; the image can still be exported as a table."))
      }
      tagList(
        card_panel("Peak-group image (rows = samples, columns = RT bins)", "th",
                   p(class = "text-muted",
                     paste("Interpolated onto a common RT grid with rule = 2,",
                           "then divided by the global maximum - the author's",
                           "own construction. Padded rows are labelled.")),
                   plotly::plotlyOutput(ns("group_image"), height = "420px")),
        card_panel("Member traces in the shared RT window", "chart-line",
                   plotly::plotlyOutput(ns("group_traces"), height = "380px"))
      )
    })

    if (requireNamespace("plotly", quietly = TRUE)) {
      output$group_image <- plotly::renderPlotly({
        g <- group_obj(); req(g)
        pq_plot_group_image(g)
      })
      output$group_traces <- plotly::renderPlotly({
        g <- group_obj(); req(g)
        pq_plot_group_traces(g)
      })
    }

    output$group_detail_ui <- renderUI({
      det <- results()
      if (is.null(det)) return(NULL)
      g <- group_obj()
      diag_tbl <- group_diag()
      tagList(
        if (!is.null(g) && !is.null(g$diagnostics))
          card_panel("Diagnostics of this group", "stethoscope",
            tableOutput(ns("group_one_table")),
            if (!is.null(g$reason)) p(class = "text-muted", g$reason)
          ),
        if (!is.null(diag_tbl) && nrow(diag_tbl) > 0)
          card_panel("Diagnostics of every feature", "table-list",
            p(class = "text-muted",
              paste("admissibility says whether a cross-sample image could be",
                    "built at all. 'single_member' means only one sample has",
                    "signal: the published method cannot be applied to it, and",
                    "no probability is produced for it.")),
            DTOutput(ns("group_diag_table")))
      )
    })

    output$group_one_table <- renderTable({
      g <- group_obj()
      req(g, g$diagnostics)
      d <- g$diagnostics
      data.frame(
        item = c("feature", "m/z", "input RT (min)", "window (min)",
                 "rows in table", "samples with signal", "absent in sample",
                 "no XIC stored", "dropped (zero signal)", "image size",
                 "padded rows", "extrapolated members", "members with >1 local max",
                 "median apex RT", "median |apex drift| (min)", "max |apex drift| (min)",
                 "admissibility"),
        value = c(d$feature_id, format(round(d$mz, 5)),
                  format(round(d$input_rt, 4)),
                  sprintf("%.3f - %.3f", d$window_lo, d$window_hi),
                  d$n_rows_in_table, d$n_signal, d$n_absent, d$n_no_xic,
                  d$n_dropped_zero_signal,
                  sprintf("%d x %d", d$n_image_rows, d$n_image_cols),
                  d$n_padded_rows, d$n_extrapolated, d$n_multi_peak_members,
                  format(round(d$apex_rt_median, 4)),
                  format(round(d$apex_drift_median_abs, 4)),
                  format(round(d$apex_drift_max_abs, 4)),
                  d$admissibility),
        stringsAsFactors = FALSE)
    }, striped = TRUE, bordered = FALSE, spacing = "s")

    output$group_diag_table <- renderDT({
      g <- group_diag()
      if (is.null(g)) return(NULL)
      shown <- g
      num <- vapply(shown, is.numeric, logical(1))
      shown[num] <- lapply(shown[num], function(x) round(x, 4))
      DT::datatable(shown, rownames = FALSE, filter = "top",
                    options = list(pageLength = 12, scrollX = TRUE)) |>
        DT::formatStyle("admissibility",
          backgroundColor = DT::styleEqual(
            c("ok", "single_member", "no_signal", "image_failed", "no_window"),
            c("#ecfdf5", "#fffbeb", "#eef2f7", "#fef2f2", "#fef2f2")))
    })

    # ============================================================
    # 5. Peak view
    # ============================================================
    output$peak_selector <- renderUI({
      det <- results()
      if (is.null(det)) return(NULL)
      keys <- names(det$detail)
      keys <- keys[vapply(det$detail, function(d) !is.null(d) && nrow(d$xic) > 0,
                          logical(1))]
      if (length(keys) == 0) return(NULL)
      n_all <- length(keys)
      # the dropdown is searchable; keep the payload sane on 69000-row jobs
      keys <- utils::head(keys, PQ_PEAK_CHOICES)
      label <- if (n_all > length(keys)) {
        sprintf("Feature to inspect (%d of %d - search to narrow down)",
                length(keys), n_all)
      } else {
        "Feature to inspect"
      }
      selectizeInput(ns("peak_key"), label,
                     choices = stats::setNames(keys, gsub("\\|", "  |  ", keys)),
                     selected = keys[1], width = "100%",
                     options = list(maxOptions = 5000))
    })

    current_detail <- reactive({
      det <- results()
      req(det, input$peak_key)
      det$detail[[input$peak_key]]
    })

    output$peak_plot_ui <- renderUI({
      det <- results()
      if (is.null(det)) {
        return(div(class = "mini-summary mini-summary--muted",
                   "Run an assessment to see the XIC"))
      }
      if (requireNamespace("plotly", quietly = TRUE)) {
        tagList(plotly::plotlyOutput(ns("peak_plot"), height = "500px"),
                conditionalPanel(
                  condition = sprintf("input['%s'] == true", ns("show_fit")),
                  plotly::plotlyOutput(ns("resid_plot"), height = "220px")))
      } else {
        tagList(plotOutput(ns("peak_plot_base"), height = "500px"))
      }
    })

    # The row index is resolved once and reused, so the CPC overlay always
    # belongs to the same row as the Kumler values.
    current_row_index <- reactive({
      det <- results()
      req(det, input$peak_key)
      which(det$rows$feature_id == d_feature_id(input$peak_key) &
              det$rows$sample_id == d_sample_id(input$peak_key))[1]
    })

    current_cpc <- reactive({
      cp <- cpc_tbl()
      idx <- current_row_index()
      if (is.null(cp) || is.na(idx) || idx < 1) return(NULL)
      cp[idx, , drop = FALSE]
    })

    if (requireNamespace("plotly", quietly = TRUE)) {
      output$peak_plot <- plotly::renderPlotly({
        d <- current_detail()
        det <- results()
        req(d, det)
        idx <- current_row_index()
        if (is.na(idx)) return(NULL)
        pq_plot_peak_quality(d, det$rows[idx, , drop = FALSE],
                             show_fit = isTRUE(input$show_fit),
                             smooth_points = ifelse(is.na(input$smooth_points), 0,
                                                    input$smooth_points),
                             cpc_row = current_cpc())
      })

      output$resid_plot <- plotly::renderPlotly({
        d <- current_detail()
        det <- results()
        req(d, det)
        idx <- current_row_index()
        if (is.na(idx)) return(NULL)
        pq_plot_residuals(d, det$rows[idx, , drop = FALSE])
      })
    }

    output$peak_plot_base <- renderPlot({
      d <- current_detail()
      det <- results()
      req(d, det)
      idx <- current_row_index()
      if (is.na(idx)) return(NULL)
      pq_plot_peak_base(d, det$rows[idx, , drop = FALSE],
                        show_fit = isTRUE(input$show_fit),
                        smooth_points = ifelse(is.na(input$smooth_points), 0,
                                               input$smooth_points),
                        cpc_row = current_cpc())
    })

    output$peak_detail_ui <- renderUI({
      d <- current_detail()
      det <- results()
      req(d, det)
      idx <- current_row_index()
      if (is.na(idx)) return(NULL)
      r <- det$rows[idx, , drop = FALSE]
      cp <- current_cpc()

      kv <- function(label, value) {
        div(class = "kv", span(class = "kv__k", label),
            span(class = "kv__v", as.character(value)))
      }

      tagList(
        card_panel("Peak metrics", "ruler-combined",
          div(class = "kv-grid",
              kv("feature", r$feature_id),
              kv("sample", r$sample_id),
              kv("file", r$file),
              kv("m/z", format(r$mz, digits = 7)),
              kv("m/z tolerance", r$mz_tol),
              kv("input RT (min)", round(r$input_rt, 4)),
              kv("start RT", round(r$start_rt, 4)),
              kv("apex RT", round(r$apex_rt, 4)),
              kv("end RT", round(r$end_rt, 4)),
              kv("apex offset (min)", round(r$apex_offset, 4)),
              kv("scans inside peak", r$n_points),
              kv("scans in window", r$n_scans_in_window),
              kv("XIC smoothing", if (identical(as.character(r$eic_smoothing), "none")) {
                "none (raw XIC)"
              } else if (isTRUE(r$eic_smoothing_applied)) {
                paste0(r$eic_smoothing, " (applied)")
              } else {
                paste0(r$eic_smoothing, " (requested, not applied)")
              }),
              kv("missing scans", r$n_scans_missing),
              kv("peaks in m/z window", r$n_mz_matched),
              kv("peak_cor", ifelse(is.na(r$peak_cor), "NA", round(r$peak_cor, 4))),
              kv("SNR", ifelse(is.na(r$SNR), "NA", round(r$SNR, 2))),
              kv("presence", pq_presence_label(r$presence)),
              kv("peak height", ifelse(is.na(r$peak_height), "NA",
                                       format(round(r$peak_height), big.mark = ","))),
              kv("point-to-point noise", ifelse(is.na(r$xic_noise), "NA",
                                                format(round(r$xic_noise), big.mark = ","))),
              kv("height / noise", ifelse(is.na(r$presence_snr), "NA",
                                          round(r$presence_snr, 1))),
              kv("boundary status", pq_status_label(r$boundary_status)),
              kv("score status", r$score_status),
              kv("reason", ifelse(is.na(r$failure_reason), "-", r$failure_reason))
          )
        ),
        if (!is.null(d$candidates) && nrow(d$candidates) > 0)
          card_panel("Candidate peaks in the search window", "list-ol",
            DT::datatable(round_df(d$candidates), rownames = FALSE,
                          options = list(dom = "t", pageLength = 10,
                                         scrollX = TRUE))),
        if (!is.null(cp) && "cpc_status" %in% names(cp))
          card_panel("Same peak, both methods", "scale-balanced",
            p(class = "text-muted",
              paste("Two independent methods on the same candidate. The values",
                    "are not combined, ranked or averaged.")),
            DT::datatable(pq_method_side_by_side(r, cp), rownames = FALSE,
                          options = list(dom = "t", pageLength = 20,
                                         scrollX = TRUE)),
            if (!identical(as.character(cp$cpc_status[1]), "ok"))
              p(class = "text-muted",
                paste("CPC did not produce a result for this row:",
                      as.character(cp$cpc_reason[1])))
          )
      )
    })

    round_df <- function(df) {
      num <- vapply(df, is.numeric, logical(1))
      df[num] <- lapply(df[num], function(x) round(x, 4))
      df
    }

    # ============================================================
    # 6. Inputs & mapping tab
    # ============================================================
    output$sample_match_table <- renderDT({
      lk <- lookup_r()
      if (is.null(lk)) {
        return(DT::datatable(data.frame(Status = "No run yet"), rownames = FALSE,
                             options = list(dom = "t")))
      }
      lk$file <- ifelse(is.na(lk$file), "", basename(lk$file))
      DT::datatable(lk, rownames = FALSE,
                    options = list(dom = "tip", pageLength = 10))
    })

    output$bad_rows_table <- renderDT({
      bad <- features_bad()
      if (is.null(bad) || nrow(bad) == 0) {
        return(DT::datatable(data.frame(Status = "No rejected row"), rownames = FALSE,
                             options = list(dom = "t")))
      }
      DT::datatable(utils::head(bad, 200), rownames = FALSE,
                    options = list(dom = "tip", pageLength = 10, scrollX = TRUE))
    })

    # ============================================================
    # 7. Parameters / provenance
    # ============================================================
    output$params_table <- renderTable({
      meta <- run_meta()
      if (is.null(meta)) {
        p <- pq_default_params()
        return(pq_params_table(p))
      }
      pq_params_table(meta$params)
    }, striped = TRUE, bordered = FALSE, spacing = "s")

    output$provenance <- renderText({
      meta <- run_meta()
      sm_lines <- pq_eic_smooth_provenance_lines(
        if (is.null(meta)) pq_default_params() else meta$params)
      paste(c(pq_provenance_lines(),
              sm_lines,
              "",
              unlist(lapply(PQ_METHOD_IDS, function(id) {
                c(pq_method_provenance_lines(id), "")
              })),
              "Boundary detection, XIC extraction and the display-only fit",
              "reconstruction are implemented in this project and are NOT part",
              "of any of the published methods.",
              "CPC is executed from the installed GPL package; its source is not",
              "redistributed with DMetFinder. No CPC filter (min_sn / min_pts)",
              "is ever applied, no peak is removed.",
              "No DNN model is executed: the authors publish no trained weights,",
              "so quality_probability is never filled for it."),
            collapse = "\n")
    })

    # ============================================================
    # 8. Downloads
    # ============================================================
    output$template <- downloadHandler(
      filename = function() "peak_quality_template.csv",
      content = function(file) {
        utils::write.csv(
          data.frame(feature_id = c("F001", "F002"),
                     mz = c(301.1234, 455.2101),
                     rt = c(6.42, 9.85),
                     sample_id = c("sampleA", "sampleA")),
          file, row.names = FALSE)
      }
    )

    output$dl_csv <- downloadHandler(
      filename = function() paste0("peak_quality_", format(Sys.Date(), "%Y%m%d"), ".csv"),
      content = function(file) {
        rows <- classified_rows()
        # a table, not just "something non-NULL": see the results() shape bug
        req(is.data.frame(rows))
        utils::write.csv(rows[, pq_result_columns(rows)],
                         file, row.names = FALSE, na = "")
      }
    )

    output$dl_xlsx <- downloadHandler(
      filename = function() paste0("peak_quality_", format(Sys.Date(), "%Y%m%d"), ".xlsx"),
      content = function(file) {
        req(results(), run_meta())
        det <- results()
        req(det$rows)
        pq_export_xlsx(file, det$rows, det$detail,
                       run_meta()$params, run_meta()$mapping, run_meta()$lookup,
                       summary = feature_summary(),
                       cpc = cpc_tbl(), cpc_settings = cpc_settings(),
                       unified = pq_unified_from_run(det$rows, cpc_tbl(),
                                                     run_meta()$params,
                                                     cpc_settings = cpc_settings()),
                       metrics = pq_method_metrics(det$rows, cpc_tbl()),
                       compare = compare_wide(),
                       group_diag = group_diag(),
                       methods_run = run_meta()$methods,
                       paths = pq_dnn_paths(getwd()))
      }
    )

    output$dl_report <- downloadHandler(
      filename = function() paste0("peak_quality_report_", format(Sys.Date(), "%Y%m%d"), ".zip"),
      content = function(file) {
        req(results(), run_meta())
        det <- results()
        req(det$rows)
        wd <- file.path(tempdir(), paste0("pq_report_", as.integer(Sys.time())))
        pq_export_report_zip(
          zipfile = file, workdir = wd,
          rows = det$rows, detail = det$detail,
          params = run_meta()$params, mapping = run_meta()$mapping,
          lookup = run_meta()$lookup, summary = feature_summary(),
          cpc = cpc_tbl(), cpc_settings = cpc_settings(),
          unified = pq_unified_from_run(det$rows, cpc_tbl(), run_meta()$params,
                                        cpc_settings = cpc_settings()),
          metrics = pq_method_metrics(det$rows, cpc_tbl()),
          compare = compare_wide(),
          group_diag = group_diag(),
          methods_run = run_meta()$methods,
          paths = pq_dnn_paths(getwd())
        )
      }
    )
  })
}

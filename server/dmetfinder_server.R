# ============================================================
# DMetFinder Server
# ------------------------------------------------------------
# 分析主流程在 R/dmetfinder_functions.R 的 dmetfinder_run()，
# 这里只负责：文件读取与预览、参数装配、进度、结果预览与打包下载。
# ============================================================

dmetfinder_server <- function(input, output, session) {

  values <- reactiveValues(
    dataA = NULL,
    dataB = NULL,
    run = NULL,
    status = NULL
  )

  # ---------- 参数解析 ----------
  parse_num <- function(txt) {
    if (is.null(txt) || !nzchar(txt)) return(NULL)
    v <- suppressWarnings(as.numeric(trimws(strsplit(txt, ",")[[1]])))
    v[!is.na(v)]
  }

  read_group <- function(file, group_label) {
    tryCatch({
      withProgress(message = sprintf("读取 %s 数据…", group_label), {
        rd <- dmf_read_samples(file$datapath)
      })
      list(ok = TRUE, data = rd,
           msg = sprintf("读取成功：%d 个样品，%s 条离子记录（读取阶段未做合并）",
                         length(rd$sample_names),
                         format(nrow(rd$ions), big.mark = ",")))
    }, error = function(e) {
      list(ok = FALSE, data = NULL, msg = paste("读取失败：", e$message))
    })
  }

  # ---------- 数据读取 ----------
  observeEvent(input$fileA, {
    req(input$fileA)
    r <- read_group(input$fileA, "Group A")
    values$dataA <- r$data
    output$fileA_info <- renderUI({
      div(class = if (r$ok) "status-box status-success" else "status-box status-error",
          icon(if (r$ok) "check-circle" else "exclamation-circle"),
          r$msg)
    })
  })

  observeEvent(input$fileB, {
    req(input$fileB)
    r <- read_group(input$fileB, "Group B")
    values$dataB <- r$data
    output$fileB_info <- renderUI({
      div(class = if (r$ok) "status-box status-success" else "status-box status-error",
          icon(if (r$ok) "check-circle" else "exclamation-circle"),
          r$msg)
    })
  })

  preview_ions <- function(rd) {
    req(rd)
    df <- data.frame(
      `Sample (No)` = rd$ions$no_int,
      RT = rd$ions$rt,
      `RT&m/z` = rd$ions$rt_mz,
      mz = rd$ions$mz,
      Intensity = rd$ions$intensity,
      check.names = FALSE
    )
    utils::head(df, 200)
  }

  output$previewA <- renderDT({
    datatable(preview_ions(values$dataA), options = list(scrollX = TRUE, pageLength = 10))
  })

  output$previewB <- renderDT({
    datatable(preview_ions(values$dataB), options = list(scrollX = TRUE, pageLength = 10))
  })

  # ---------- 执行分析 ----------
  observeEvent(input$runAnalysis, {
    req(input$fileA, input$fileB)

    config <- list(
      ErrorRange = input$ErrorRange,
      ErrorRangeInGroups = input$ErrorRangeInGroups,
      FloatCount = as.integer(input$FloatCount),
      mergeRows = isTRUE(input$mergeRows),
      m1 = input$m1, m2 = input$m2, m3 = input$m3,
      p50IonPercent = input$p50IonPercent,
      p80IonPercent = input$p80IonPercent,
      intensityRange = parse_num(input$intensityRange),
      intensityValue = parse_num(input$intensityValue),
      countRange = parse_num(input$countRange),
      countValue = parse_num(input$countValue),
      relativeIntensityRange1 = parse_num(input$relIntensityRange1),
      relativeIntensityValue1 = parse_num(input$relIntensityValue1)
    )

    outdir <- file.path(tempdir(), paste0("dmetfinder_out_", format(Sys.time(), "%Y%m%d%H%M%S")))

    tryCatch({
      withProgress(message = "分析中…", value = 0, {
        values$run <- dmetfinder_run(
          input$fileA$datapath,
          input$fileB$datapath,
          outdir,
          config = config,
          progress = function(frac, detail) incProgress(frac, detail = detail)
        )
      })
      values$status <- "success"
      output$run_status <- renderUI({
        div(class = "status-box status-success", icon("check-circle"),
            "分析完成，可在 Results 标签查看与下载结果。")
      })
    }, error = function(e) {
      values$status <- "error"
      output$run_status <- renderUI({
        div(class = "status-box status-error", icon("exclamation-circle"),
            paste("分析失败：", e$message))
      })
    })
  })

  # ---------- 结果展示 ----------
  output$result_files <- renderUI({
    req(values$run)
    tags$ul(class = "file-list",
            lapply(basename(values$run$files), function(f)
              tags$li(icon("file-excel"), f)))
  })

  # 结果表 -> 预览用 data.frame（超过 500 行只预览前 500 行）
  sheet_df <- function(sh, limit = 500L) {
    req(sh)
    cols <- sh$cols
    df <- as.data.frame(cols, stringsAsFactors = FALSE, check.names = FALSE,
                        optional = TRUE)
    hdr <- sh$header[[length(sh$header)]]
    nm <- rep(NA_character_, ncol(df))
    m <- min(length(hdr), ncol(df))
    if (m > 0) nm[seq_len(m)] <- as.character(hdr[seq_len(m)])
    bad <- is.na(nm) | !nzchar(nm)
    nm[bad] <- paste0("V", which(bad))
    names(df) <- make.unique(nm)
    if (nrow(df) > limit) df <- df[seq_len(limit), , drop = FALSE]
    df
  }

  pick <- function(res, which) {
    req(res)
    switch(which,
      filterA = sheet_df(res$groups$A$sheets[[2]]),
      scoreA  = sheet_df(res$groups$A$sheets[[6]]),
      isoA    = sheet_df(res$groups$A$sheets[[7]]),
      cmpA    = sheet_df(res$sheets$compare_ab),
      diff    = sheet_df(res$sheets$diff_ab),
      filterB = sheet_df(res$groups$B$sheets[[2]]),
      scoreB  = sheet_df(res$groups$B$sheets[[6]]),
      isoB    = sheet_df(res$groups$B$sheets[[7]]),
      cmpB    = sheet_df(res$sheets$compare_ba)
    )
  }

  render_result <- function(which) {
    renderDT({
      datatable(pick(values$run, which),
                options = list(scrollX = TRUE, pageLength = 10))
    })
  }

  output$result_filterA <- render_result("filterA")
  output$result_scoreA  <- render_result("scoreA")
  output$result_isoA    <- render_result("isoA")
  output$result_compareA <- render_result("cmpA")
  output$result_diff    <- render_result("diff")
  output$result_filterB <- render_result("filterB")
  output$result_scoreB  <- render_result("scoreB")
  output$result_isoB    <- render_result("isoB")
  output$result_compareB <- render_result("cmpB")

  # ---------- 打包下载 ----------
  output$downloadAll <- downloadHandler(
    filename = function() {
      paste0("DMetFinder_results_", format(Sys.Date(), "%Y%m%d"), ".zip")
    },
    content = function(file) {
      req(values$run)
      old <- setwd(dirname(values$run$files[1]))
      on.exit(setwd(old), add = TRUE)
      utils::zip(file, basename(values$run$files), flags = "-j")
    }
  )
}

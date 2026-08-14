# ============================================================
# DMetFinder UI
# ============================================================

dmetfinder_ui <- fluidPage(
  tags$head(
    tags$style(HTML("
      .title-panel {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        color: white;
        padding: 20px;
        border-radius: 10px;
        margin-bottom: 20px;
      }
      .title-panel h2 {
        margin: 0;
        font-weight: bold;
      }
      .title-panel p {
        margin: 5px 0 0 0;
        opacity: 0.9;
      }
      .section-box {
        background: #f8f9fa;
        border: 1px solid #dee2e6;
        border-radius: 8px;
        padding: 15px;
        margin-bottom: 15px;
      }
      .section-title {
        font-weight: bold;
        color: #495057;
        margin-bottom: 10px;
        border-bottom: 2px solid #667eea;
        padding-bottom: 5px;
      }
      .btn-run {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        border: none;
        color: white;
        font-weight: bold;
      }
      .btn-run:hover {
        background: linear-gradient(135deg, #5a67d8 0%, #6b46a1 100%);
      }
      .status-box { padding: 10px; border-radius: 5px; margin-top: 10px; }
      .status-success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
      .status-error { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
      .status-info { background: #d1ecf1; color: #0c5460; border: 1px solid #bee5eb; }
    "))
  ),
  
  div(class = "title-panel",
      h2("DMetFinder - Differential Metabolite Screening Software"),
      p("R Shiny implementation | Group A/B differential metabolite screening and analysis")
  ),
  
  tabsetPanel(
    # ============ Data Input ============
    tabPanel("Data Input",
      fluidRow(
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Group A Data"),
            fileInput("fileA", "Select Group A Excel file (6 columns per sample: Sample(No), RT, RT&m/z, m/z, Intensity)",
                     accept = c(".xlsx", ".xls")),
            uiOutput("fileA_info")
          )
        ),
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Group B Data"),
            fileInput("fileB", "Select Group B Excel file (6 columns per sample: Sample(No), RT, RT&m/z, m/z, Intensity)",
                     accept = c(".xlsx", ".xls")),
            uiOutput("fileB_info")
          )
        )
      ),
      fluidRow(
        column(12,
          div(class = "section-box",
            h4(class = "section-title", "Data Preview"),
            tabsetPanel(
              tabPanel("Group A Data", DTOutput("previewA")),
              tabPanel("Group B Data", DTOutput("previewB"))
            )
          )
        )
      )
    ),
    
    # ============ Parameter Settings ============
    tabPanel("Parameters",
      fluidRow(
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Matching Parameters"),
            numericInput("ErrorRange", "Ion Matching Error Range", 
                        value = default_config$ErrorRange, min = 0.0001, max = 1, step = 0.0001),
            numericInput("ErrorRangeInGroups", "Within-Group Matching Error Range", 
                        value = default_config$ErrorRangeInGroups, min = 0.0001, max = 1, step = 0.0001),
            numericInput("FloatCount", "Decimal Places", 
                        value = default_config$FloatCount, min = 1, max = 15, step = 1),
            checkboxInput("mergeRows", "Merge Duplicate Rows", value = default_config$mergeRows)
          )
        ),
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Isotope Parameters"),
            numericInput("m1", "M+1 Mass Difference", value = default_config$m1, step = 0.00001),
            numericInput("m2", "M+2 Mass Difference", value = default_config$m2, step = 0.00001),
            numericInput("m3", "M+3 Mass Difference", value = default_config$m3, step = 0.00001)
          )
        )
      ),
      fluidRow(
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Intensity Scoring"),
            textInput("intensityRange", "Intensity Ranges (comma-separated)", 
                     value = paste(default_config$intensityRange, collapse = ",")),
            textInput("intensityValue", "Intensity Scores (comma-separated)", 
                     value = paste(default_config$intensityValue, collapse = ","))
          )
        ),
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Count Scoring"),
            textInput("countRange", "Count Ranges (comma-separated)", 
                     value = paste(default_config$countRange, collapse = ",")),
            textInput("countValue", "Count Scores (comma-separated)", 
                     value = paste(default_config$countValue, collapse = ","))
          )
        )
      ),
      fluidRow(
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Relative Ion Intensity Scoring"),
            textInput("relIntensityRange1", "Relative Intensity Ranges (comma-separated)", 
                     value = paste(default_config$relativeIntensityRange1, collapse = ",")),
            textInput("relIntensityValue1", "Relative Intensity Scores (comma-separated)", 
                     value = paste(default_config$relativeIntensityValue1, collapse = ","))
          )
        ),
        column(6,
          div(class = "section-box",
            h4(class = "section-title", "Filter Parameters"),
            numericInput("p50IonPercent", "50% Filter Threshold", 
                        value = default_config$p50IonPercent, min = 0, max = 1, step = 0.05),
            numericInput("p80IonPercent", "80% Filter Threshold", 
                        value = default_config$p80IonPercent, min = 0, max = 1, step = 0.05)
          )
        )
      ),
      fluidRow(
        column(12,
          div(class = "section-box",
            h4(class = "section-title", "Actions"),
            actionButton("runAnalysis", "Run Analysis", 
                        class = "btn-run btn-lg",
                        icon = icon("play"), width = "200px"),
            br(), br(),
            uiOutput("run_status")
          )
        )
      )
    ),
    
    # ============ Analysis Results ============
    tabPanel("Results",
      fluidRow(
        column(12,
          div(class = "section-box",
            h4(class = "section-title", "Result Files"),
            uiOutput("result_files"),
            br(),
            downloadButton("downloadAll", "Download All Results", class = "btn-primary")
          )
        )
      ),
      fluidRow(
        column(12,
          div(class = "section-box",
            h4(class = "section-title", "Result Preview"),
            tabsetPanel(
              tabPanel("Group A - 50% and 80% Ion Filter", DTOutput("result_filterA")),
              tabPanel("Group A - Ion Scoring", DTOutput("result_scoreA")),
              tabPanel("Group A - Isotope Search", DTOutput("result_isoA")),
              tabPanel("Group A - 80% Ions vs Group B Total Ions", DTOutput("result_compareA")),
              tabPanel("Group A - Group B Differential Ion Summary", DTOutput("result_diff")),
              tabPanel("Group B - 50% and 80% Ion Filter", DTOutput("result_filterB")),
              tabPanel("Group B - Ion Scoring", DTOutput("result_scoreB")),
              tabPanel("Group B - Isotope Search", DTOutput("result_isoB")),
              tabPanel("Group B - 80% Ions vs Group A Total Ions", DTOutput("result_compareB"))
            )
          )
        )
      )
    )
  )
)
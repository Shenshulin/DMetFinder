# ============================================================
# DMetFinder UI
# ============================================================
# Visual layer comes from shiny_app/ui/theme.R
# (app_css / hero_panel / card_panel / format_hint).
# All input and output ids are unchanged.
# ============================================================

dmetfinder_ui <- fluidPage(
  hero_panel(
    title     = "DMetFinder",
    subtitle  = "Differential Metabolite Screening Software - Group A/B differential ion screening and analysis",
    icon_name = "magnifying-glass-chart",
    variant   = "dmetfinder",
    chips     = c("Group A/B differential ions",
                  "Isotope search M+1 / M+2 / M+3",
                  "9 result tables, one-click export")
  ),

  tabsetPanel(
    id   = "dmf_tabs",
    type = "pills",

    # ============ Data Input ============
    tabPanel("Data Input", icon = icon("file-arrow-up"),
      fluidRow(
        column(6,
          card_panel("Group A Data", "flask",
            fileInput("fileA", "Group A data file (.xlsx / .xls)",
                      accept = c(".xlsx", ".xls")),
            format_hint("Each sample occupies 6 columns: Sample(No), RT, RT&m/z, m/z, Intensity, (blank column).",
                        "circle-info", "neutral"),
            uiOutput("fileA_info")
          )
        ),
        column(6,
          card_panel("Group B Data", "flask",
            fileInput("fileB", "Group B data file (.xlsx / .xls)",
                      accept = c(".xlsx", ".xls")),
            format_hint("Same layout as Group A. Sample names come from the header columns.",
                        "circle-info", "neutral"),
            uiOutput("fileB_info")
          )
        )
      ),
      fluidRow(
        column(12,
          card_panel("Data Preview", "table-list",
            tabsetPanel(
              type = "pills",
              tabPanel("Group A Data", DTOutput("previewA")),
              tabPanel("Group B Data", DTOutput("previewB"))
            )
          )
        )
      )
    ),

    # ============ Parameter Settings ============
    tabPanel("Parameters", icon = icon("sliders"),
      fluidRow(
        column(6,
          card_panel("Matching Parameters", "gears",
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
          card_panel("Isotope Parameters", "atom",
            numericInput("m1", "M+1 Mass Difference", value = default_config$m1, step = 0.00001),
            numericInput("m2", "M+2 Mass Difference", value = default_config$m2, step = 0.00001),
            numericInput("m3", "M+3 Mass Difference", value = default_config$m3, step = 0.00001)
          )
        )
      ),
      fluidRow(
        column(6,
          card_panel("Intensity Scoring", "chart-simple",
            textInput("intensityRange", "Intensity Ranges (comma-separated)",
                     value = paste(default_config$intensityRange, collapse = ",")),
            textInput("intensityValue", "Intensity Scores (comma-separated)",
                     value = paste(default_config$intensityValue, collapse = ","))
          )
        ),
        column(6,
          card_panel("Count Scoring", "list-ol",
            textInput("countRange", "Count Ranges (comma-separated)",
                     value = paste(default_config$countRange, collapse = ",")),
            textInput("countValue", "Count Scores (comma-separated)",
                     value = paste(default_config$countValue, collapse = ","))
          )
        )
      ),
      fluidRow(
        column(6,
          card_panel("Relative Ion Intensity Scoring", "percent",
            textInput("relIntensityRange1", "Relative Intensity Ranges (comma-separated)",
                     value = paste(default_config$relativeIntensityRange1, collapse = ",")),
            textInput("relIntensityValue1", "Relative Intensity Scores (comma-separated)",
                     value = paste(default_config$relativeIntensityValue1, collapse = ","))
          )
        ),
        column(6,
          card_panel("Filter Parameters", "filter",
            numericInput("p50IonPercent", "50% Filter Threshold",
                        value = default_config$p50IonPercent, min = 0, max = 1, step = 0.05),
            numericInput("p80IonPercent", "80% Filter Threshold",
                        value = default_config$p80IonPercent, min = 0, max = 1, step = 0.05)
          )
        )
      ),
      fluidRow(
        column(12,
          card_panel("Actions", "play",
            actionButton("runAnalysis", "Run Analysis",
                        class = "btn-run btn-lg",
                        icon = icon("play"), width = "220px"),
            uiOutput("run_status")
          )
        )
      )
    ),

    # ============ Analysis Results ============
    tabPanel("Results", icon = icon("table-list"),
      fluidRow(
        column(12,
          card_panel("Result Files", "folder-tree",
            uiOutput("result_files"),
            downloadButton("downloadAll", "Download All Results",
                           class = "btn-primary btn-lg", icon = icon("download"))
          )
        )
      ),
      fluidRow(
        column(12,
          card_panel("Result Preview", "table-list",
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

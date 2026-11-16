# ============================================================
# DMetFinder UI
# ============================================================
# Visual layer comes from shiny_app/ui/theme.R
# (app_css / hero_panel / card_panel / format_hint).
# All input and output ids are unchanged.
# ============================================================

# Render a numeric vector as a default-value string of the form "a,b,c".
#
# A plain paste(x, collapse = ",") goes through as.character(), so values such
# as 1e5 come out as "1e+05": it looks like scientific notation in the UI and
# makes users suspect the parameter was modified. Here every element is written
# in fixed notation (no exponent) with redundant trailing zeros dropped.
# digits = 15 keeps 1234567.891 from being cut off at the default 7 significant
# digits.
dmf_numlist <- function(x) {
  x <- as.numeric(x)
  out <- vapply(x, function(v) {
    if (!is.finite(v)) return(as.character(v))
    trimws(format(v, scientific = FALSE, trim = TRUE, drop0trailing = TRUE,
                  digits = 15))
  }, character(1), USE.NAMES = FALSE)
  paste(out, collapse = ",")
}

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
            radioButtons("ErrorRangeUnit", "Error Range Unit",
                        choices = c("ppm (scales with m/z)" = "ppm",
                                    "Da (fixed absolute)" = "Da"),
                        selected = default_config$ErrorRangeUnit, inline = TRUE),
            helpText(paste(
              "ppm: tolerance of each ion = m/z \u00d7 ppm \u00d7 1e-6, so the window",
              "narrows at low m/z and widens at high m/z, matching how mass error",
              "actually behaves. Da: one fixed absolute tolerance for every ion",
              "(the original Java behaviour; use it to reproduce old results).")),
            numericInput("ErrorRange", "Ion Matching Error Range",
                        value = default_config$ErrorRange, min = 1e-5, max = 1e4, step = 0.0001),
            numericInput("ErrorRangeInGroups", "Within-Group Matching Error Range",
                        value = default_config$ErrorRangeInGroups, min = 1e-5, max = 1e4, step = 0.0001),
            helpText(paste("Units follow the selector above. Switching the unit",
                           "resets both values to that unit's defaults.")),
            numericInput("FloatCount", "Decimal Places",
                        value = default_config$FloatCount, min = 1, max = 15, step = 1),
            checkboxInput("mergeRows", "Merge Duplicate Rows", value = default_config$mergeRows),
            selectInput("MatrixPick", "Duplicate Ion Inside One Sample",
                        choices = c("Highest intensity (v1.0.4 default)" = "max",
                                    "First in file (original Java)" = "first"),
                        selected = default_config$MatrixPick),
            helpText(paste(
              "When several centroids of the same sample fall inside one ion's",
              "m/z window, which one represents it. \u201cFirst in file\u201d is the",
              "original rule; \u201chighest intensity\u201d stops the chosen branch from",
              "flickering when a feature splits into several m/z branches.")),
            numericInput("ClusterRtTol", "Apex RT Tolerance (min)",
                        value = default_config$ClusterRtTol, min = 0, step = 0.05),
            helpText(paste(
              "Extra check during within-group matching: the ion's apex RT must be",
              "within this many minutes. 0 disables it and leaves only the original",
              "\u201csame integer minute bin\u201d rule, which is required to reproduce the",
              "original Java output. Needs an RT_apex column in the input."))
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
                     value = dmf_numlist(default_config$intensityRange)),
            textInput("intensityValue", "Intensity Scores (comma-separated)",
                     value = dmf_numlist(default_config$intensityValue))
          )
        ),
        column(6,
          card_panel("Count Scoring", "list-ol",
            textInput("countRange", "Count Ranges (comma-separated)",
                     value = dmf_numlist(default_config$countRange)),
            textInput("countValue", "Count Scores (comma-separated)",
                     value = dmf_numlist(default_config$countValue))
          )
        )
      ),
      fluidRow(
        column(6,
          card_panel("Relative Ion Intensity Scoring", "percent",
            textInput("relIntensityRange1", "Table 1 Ranges (comma-separated)",
                     value = dmf_numlist(default_config$relativeIntensityRange1)),
            textInput("relIntensityValue1", "Table 1 Scores (comma-separated)",
                     value = dmf_numlist(default_config$relativeIntensityValue1)),
            numericInput("relIntensitySplit", "Split on Ion Count",
                        value = default_config$relativeIntensitySplit, min = 0, step = 1),
            textInput("relIntensityRange2", "Table 2 Ranges (comma-separated)",
                     value = dmf_numlist(default_config$relativeIntensityRange2)),
            textInput("relIntensityValue2", "Table 2 Scores (comma-separated)",
                     value = dmf_numlist(default_config$relativeIntensityValue2)),
            helpText(paste(
              "Relative intensity = the ion's intensity divided by the mean intensity",
              "of its m/z group. Which table applies above the split follows the",
              "original implementation and is not symmetric: all-ion scoring uses",
              "table 2, the 50% pass uses table 1. With the shipped values both",
              "tables score identically, so this only matters if you edit them."))
          )
        ),
        column(6,
          card_panel("Filter Parameters", "filter",
            numericInput("p50IonPercent", "50% Filter Threshold",
                        value = default_config$p50IonPercent, min = 0, max = 1, step = 0.05),
            numericInput("p80IonPercent", "80% Filter Threshold",
                        value = default_config$p80IonPercent, min = 0, max = 1, step = 0.05),
            numericInput("FoldChangeThreshold", "Verdict Fold-Change Threshold",
                        value = default_config$FoldChangeThreshold, min = 1, step = 0.5),
            numericInput("PValueThreshold", "Verdict P-Value Threshold",
                        value = default_config$PValueThreshold, min = 0, max = 1, step = 0.01),
            helpText(paste(
              "The last two only decide the wording of the Verdict column in the",
              "merged differential-ion sheet (higher in A / higher in B / no",
              "change). They do not filter rows and do not affect any other sheet."))
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
              tabPanel("Differential Ions - Integrated (A and B)", DTOutput("result_diff_union")),
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

# RtGeter_ui.R
# Visual layer comes from shiny_app/ui/theme.R (format_hint / side_group /
# card_panel / sub_bar). Only the RT summary tile is styled locally
# (.rtg-*) so that the shared theme stays untouched.
RtGeter_ui <- function(id){
  ns <- NS(id)
  fluidPage(
    tags$style(HTML("
      .rtg-result { margin-top: 4px; }
      .rtg-hero {
        display: flex; align-items: baseline; gap: 10px;
        padding: 14px 18px; margin-bottom: 12px;
        border-radius: 12px; border: 1px solid #dbe3f5;
        background: linear-gradient(120deg, #eef2ff 0%, #f8fafc 100%);
      }
      .rtg-hero__label {
        color: #4b5563; font-size: .78rem; letter-spacing: .04em;
        text-transform: uppercase; font-weight: 600;
      }
      .rtg-hero__value {
        font-size: 2rem; font-weight: 700; color: #312e81;
        line-height: 1; font-variant-numeric: tabular-nums;
      }
      .rtg-hero__unit { color: #4f46e5; font-size: .9rem; font-weight: 600; }
      .rtg-meta { color: #6b7280; font-size: .78rem; margin-top: -4px; }
      /* fileInput 上传完成后 Shiny 留下的进度条会横在文件名下面，
         文件名和行列数由 .rtg-meta 显示，这里直接不显示进度条 */
      .shiny-file-input-progress { display: none; }
      .rtg-actions { display: flex; gap: 8px; margin-bottom: 8px; }
      .rtg-actions .btn { flex: 1 1 0; margin-bottom: 0; }
    ")),

    sub_bar("RtGeter",
            "Turn an integer-minute window into the exact retention time, for a whole peak table at once",
            "crosshairs"),

    sidebarLayout(
      sidebarPanel(
        width = 4,

        format_hint("Upload a peak table with four columns (peak id / sample / MZ / RT_min) and point to the folder holding the raw files. RtGeter returns the same table plus one RT column.",
                    "circle-info"),

        side_group("Data Source", "folder-open",
          textInput(ns("workdir"), "Raw data folder",
                    value = "G:/method_ms2/MSDIAL_TEST"),
          fileInput(ns("peak_table"), "Peak table",
                    accept = c(".xlsx", ".xls", ".csv", ".tsv", ".txt"),
                    buttonLabel = "Browse",
                    placeholder = "xlsx / xls / csv / tsv / txt"),
          uiOutput(ns("file_info"))
        ),

        side_group("Column Mapping", "table-columns",
          uiOutput(ns("col_map"))
        ),

        side_group("Search Settings", "sliders",
          fluidRow(
            column(7, numericInput(ns("tol"), "Mass tolerance",
                                   value = 10, min = 0, step = 1)),
            column(5, selectInput(ns("tol_unit"), "Unit",
                                  choices = c("ppm", "Da"), selected = "ppm"))
          ),
          format_hint("RT_min = 2 means the window (1, 2] minutes, RT_min = 3 means (2, 3]. Only MS1 scans are searched; within one scan the most intense peak inside the tolerance wins.",
                      "clock", "neutral")
        ),

        div(class = "rtg-actions",
          actionButton(ns("run"), "Find RT", class = "btn-run btn-lg",
                       icon = icon("crosshairs")),
          actionButton(ns("clear"), "Clear", class = "btn-soft")
        ),

        side_group("Run Info", "terminal",
          div(class = "table-tools",
            downloadButton(ns("dl_log"), "Save log", class = "btn-soft btn-sm")
          ),
          div(class = "log-box", verbatimTextOutput(ns("log")))
        )
      ),

      mainPanel(
        width = 8,
        card_panel("Summary", "chart-simple", uiOutput(ns("summary_box"))),

        card_panel("Results", "table-list",
          div(class = "table-tools",
            downloadButton(ns("dl_csv"), "CSV", class = "btn-soft btn-sm"),
            downloadButton(ns("dl_xlsx"), "XLSX", class = "btn-soft btn-sm")
          ),
          uiOutput(ns("preview_empty")),
          DT::dataTableOutput(ns("preview"))
        )
      )
    )
  )
}

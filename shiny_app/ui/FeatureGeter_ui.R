# FeatureGeter_ui.R
# Visual layer comes from shiny_app/ui/theme.R (format_hint / side_group /
# card_panel / sub_bar). All input and output ids are unchanged.
FeatureGeter_ui <- function(id){
  ns <- NS(id)
  fluidPage(
    sub_bar("Ms1Geter",
            "Extract MS1 features and MS2 scan metadata from raw mass spectrometry data",
            "wave-square"),

    sidebarLayout(
      sidebarPanel(
        width = 4,

        format_hint("Supported input: .raw (Thermo, via rawrr), .mzML / .mzXML (via mzR). Sample names must match the file names.",
                    "circle-info"),

        side_group("Input", "folder-open",
          textInput(ns("workdir"), "Set Workdir",
                    value = "G:/method_ms2/MSDIAL_TEST"),
          fileInput(ns("sample_file"), "Sample Group File (CSV / XLSX)",
                    accept = c(".csv", ".xlsx"))
        ),

        side_group("Time Range (min)", "clock",
          fluidRow(
            column(6, numericInput(ns("rt_min"), "RT min", value = 2,
                                   min = 0, step = 0.5)),
            column(6, numericInput(ns("rt_max"), "RT max", value = 19,
                                   min = 0, step = 0.5))
          ),
          format_hint("Only minute bins whose RT (bin start + 1) falls in this range are kept. Default 2-19 reproduces the previous hard-coded behaviour.",
                      "circle-info")
        ),

        actionButton(ns("run"), "Run Analysis",
                     class = "btn-run btn-lg", icon = icon("play")),

        side_group("Run Info", "terminal",
          div(class = "log-box", verbatimTextOutput(ns("log")))
        )
      ),

      mainPanel(
        width = 8,
        card_panel("Output Files Info", "folder-tree",
          tableOutput(ns("output_files"))
        )
      )
    )
  )
}

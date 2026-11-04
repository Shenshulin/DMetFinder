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

        side_group("Time & Intensity", "clock",
          fluidRow(
            column(6, numericInput(ns("rt_min"), "Actual RT min", value = 1,
                                   min = 0, step = 0.5)),
            column(6, numericInput(ns("rt_max"), "Actual RT max", value = 18,
                                   min = 0, step = 0.5))
          ),
          format_hint("These are the acquisition times you actually care about, not the RT values written to the output. A window of 1-10 min is recorded as RT 2-11 min, because RT is the right edge of each 1-minute bin (RT = bin index + 1). Default 1-18 produces RT 2-19, i.e. the previous hard-coded behaviour.",
                      "circle-info"),
          numericInput(ns("min_intensity"), "Min peak intensity",
                       value = 10000, min = 0, step = 1000),
          format_hint("Peaks at or below the intensity floor are dropped after deconvolution; default 10000 is the value that used to be hard-coded.",
                      "circle-info")
        ),

        side_group("Deconvolution", "layer-group",
          numericInput(ns("ppm_tol"), "Clustering window (ppm)",
                       value = 10, min = 5, max = 30, step = 5),
          format_hint("Peaks stacked inside one minute bin are clustered by this relative m/z window and only the most intense member of each cluster is kept. Range 5-30 ppm, step 5. 10 ppm is the previous hard-coded value; a wider window merges more aggressively, which removes near-duplicate rows but can also merge two genuinely resolved ions. Profile-mode input is collapsed to centroids with the same window, so it must be wider than one peak width there (>=20 ppm for typical profile data).",
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

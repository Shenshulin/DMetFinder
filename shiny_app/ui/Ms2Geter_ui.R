# Ms2Geter_ui.R
# Visual layer comes from shiny_app/ui/theme.R (format_hint / side_group /
# card_panel / sub_bar). All input and output ids are unchanged.
Ms2Geter_ui <- function(id){
  ns <- NS(id)
  fluidPage(
    sub_bar("Ms2Geter",
            "Match and extract MS2 spectra of target features from MSP files",
            "layer-group"),

    sidebarLayout(
      sidebarPanel(
        width = 4,

        format_hint("Provide the MS2 group information table, the target feature list, and the folder holding the MSP files.",
                    "circle-info"),

        side_group("Input Files", "file-import",
          fileInput(ns("all_ms2_file"), "Upload MS2_Group_Info.csv", accept = c(".csv")),
          fileInput(ns("demo_ms2_file"), "Upload demo.csv", accept = c(".csv"))
        ),

        side_group("MSP Source", "folder-open",
          shinyDirButton(ns("mgf_dir"), "Select MGF Folder",
                         "Please choose the folder containing MGF files"),
          div(class = "path-box", verbatimTextOutput(ns("mgf_dir_path"))),
          textInput(ns("output_mgf"), "Output MGF File", value = "demo_extract.mgf")
        ),

        actionButton(ns("run"), "Run Extraction",
                     class = "btn-run btn-lg", icon = icon("play")),

        side_group("Run Info", "terminal",
          div(class = "log-box", verbatimTextOutput(ns("status")))
        )
      ),

      mainPanel(
        width = 8,
        card_panel("Processing Log", "list-check",
          div(class = "log-area",
            textAreaInput(ns("log_area"), NULL, value = "",
                          width = "100%", height = "520px")
          )
        )
      )
    )
  )
}

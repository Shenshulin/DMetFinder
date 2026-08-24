# FeatureGeter_ui.R
FeatureGeter_ui <- function(id){
  ns <- NS(id)
  fluidPage(
    titlePanel("MS1"),
    sidebarLayout(
      sidebarPanel(
        textInput(ns("workdir"), "Set Workdir：", value = "G:/method_ms2/MSDIAL_TEST"),
        fileInput(ns("sample_file"), "Sample Group File (CSV)",
                  accept = c(".csv", ".xlsx")),
        actionButton(ns("run"), "Run Analysis", class = "btn-primary"),
        hr(),
        h4("Run Info"),
        verbatimTextOutput(ns("log"))
      ),
      mainPanel(
        h4("Output Files Info"),
        tableOutput(ns("output_files"))
      )
    )
  )
}

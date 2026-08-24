Ms2Geter_ui <- function(id){
  ns <- NS(id)
  fluidPage(
    titlePanel("MS2"),
    sidebarLayout(
      sidebarPanel(
        fileInput(ns("all_ms2_file"), "Upload MS2_Group_Info.csv", accept = c(".csv")),
        fileInput(ns("demo_ms2_file"), "Upload demo.csv", accept = c(".csv")),
        
        # ✅ 改成目录选择器
        shinyDirButton(ns("mgf_dir"), "Select MGF Folder", "Please choose the folder containing MGF files"),
        verbatimTextOutput(ns("mgf_dir_path")),
        
        textInput(ns("output_mgf"), "Output MGF File", value = "demo_extract.mgf"),
        actionButton(ns("run"), "Run Extraction", class = "btn-primary"),
        hr(),
        h4("Run Info"),
        verbatimTextOutput(ns("status"))
      ),
      
      mainPanel(
        h4("Processing Log"),
        textAreaInput(ns("log_area"), NULL, value = "", width = "100%", height = "500px")
      )
    )
  )
}
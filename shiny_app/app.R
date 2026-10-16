#app.R
# load packages
rm(list=ls())
library(shiny)
library(shinyFiles)
library(readxl)
library(dplyr)
library(openxlsx)
library(stringr)
library(tools)
library(data.table)
library(purrr)
library(rawrr)
# library(shinyWidgets)
# library(shinyjs)
# library(msentropy)
# library(tidyr)
# library(DT)
# library(plotly)
# library(MsBackendMsp)
# library(MSnbase)
# library(MsBackendMgf)


# setwd("D:\\shiny_ms")
# source shared visual theme (the very same file used by the root app.R entry)
source("ui/theme.R")
# source modules
source("ui/FeatureGeter_ui.R")
source("server/FeatureGeter_server.R")
source("ui/Ms2Geter_ui.R")
source("server/Ms2Geter_server.R")
options(shiny.maxRequestSize = 100 * 1024^2)
# Define UI and server
ui <- shiny::fluidPage(
  theme = app_theme(),
  app_css(),
  navbarPage(
    title = tags$span(
      class = "app-brand",
      tags$span(class = "app-brand__mark", icon("vial")),
      tags$span(class = "app-brand__text", "MSGeter", tags$small("Ms1 / Ms2"))
    ),
    windowTitle = "MSGeter | Mass Spectrometry Processing",
    collapsible = TRUE,
    tabPanel("Ms1Geter", icon = icon("wave-square"), FeatureGeter_ui("FeatureGeter")),
    tabPanel("Ms2Geter", icon = icon("layer-group"), Ms2Geter_ui("Ms2Geter"))
  )
)
# Define server logic
server <- function(input, output, session) {
  FeatureGeter_server("FeatureGeter")
  Ms2Geter_server("Ms2Geter")
}

shinyApp(ui,server)

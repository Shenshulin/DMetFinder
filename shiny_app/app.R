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
# source modules
source("ui/FeatureGeter_ui.R")
source("server/FeatureGeter_server.R")
source("ui/Ms2Geter_ui.R")
source("server/Ms2Geter_server.R")
options(shiny.maxRequestSize = 100 * 1024^2)
# Define UI and server
ui <- shiny::fluidPage(
  navbarPage(
    "MSGeter",
    tabPanel("Ms1Geter", FeatureGeter_ui("FeatureGeter")),
    tabPanel("Ms2Geter", Ms2Geter_ui("Ms2Geter"))
  )
)
# Define server logic
server <- function(input, output, session) {
  FeatureGeter_server("FeatureGeter")
  Ms2Geter_server("Ms2Geter")
}

shinyApp(ui,server)

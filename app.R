# ============================================================
# DMetFinder & MSGeter - Metabolomics Analysis Platform
# ============================================================
# DMetFinder: Differential Metabolite Screening Software
#   1. Read raw mass spectrometry data for Group A/B (6 columns per sample)
#   2. Merge sample ions by RT&m/z matching -> Filter 50% and 80% ions
#   3. Ion scoring (intensity/count/relative intensity)
#   4. Isotope ion search (M+1, M+2, M+3)
#   5. Compare 80% ions of one group against total ions of the other group
#   6. Differential ion screening summary
# MSGeter: Mass Spectrometry Data Processing Tool
#   Ms1Geter: Extract MS1 and MS2 information from raw mass spectrometry data (.raw)
#   Ms2Geter: Extract matched MS2 spectra from MSP files based on target feature list
# ============================================================

# ============================================================
# Load Required Packages
# ============================================================
library(shiny)
library(shinyWidgets)
library(shinyFiles)
library(readxl)
library(writexl)
library(dplyr)
library(DT)
library(openxlsx)
library(stringr)
library(tools)
library(data.table)
library(purrr)
library(rawrr)

# Increase upload file size limit (default 5MB, set to 500MB here)
options(shiny.maxRequestSize = 500 * 1024^2)

# ============================================================
# Source Configuration
# ============================================================
source("R/config.R")

# ============================================================
# Source Utility Functions
# ============================================================
source("R/dmetfinder_functions.R")

# ============================================================
# Source MSGeter Modules
# ============================================================
source("shiny_app/ui/FeatureGeter_ui.R")
source("shiny_app/server/FeatureGeter_server.R")
source("shiny_app/ui/Ms2Geter_ui.R")
source("shiny_app/server/Ms2Geter_server.R")

# ============================================================
# Source UI
# ============================================================
source("ui/dmetfinder_ui.R")
source("ui/msgeter_ui.R")
source("ui/main_ui.R")

# ============================================================
# Source Server
# ============================================================
source("server/dmetfinder_server.R")
source("server/main_server.R")

# ============================================================
# Run the application
# ============================================================
shinyApp(ui = ui, server = server)
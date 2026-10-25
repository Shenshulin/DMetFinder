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
#   Ms1Geter: Extract MS1 and MS2 information from mass spectrometry data
#             (supports Thermo .raw via rawrr, .mzML/.mzXML via mzR - lazy loaded)
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
# Source Visual Theme (shared with the standalone shiny_app entry)
# ============================================================
source("shiny_app/ui/theme.R")

# ============================================================
# Source Configuration
# ============================================================
source("R/config.R")

# ============================================================
# Source Utility Functions
# ============================================================
source("R/dmetfinder_functions.R")

# ============================================================
# Source Peak Quality module (new tab, isolated from the others)
# ============================================================
source("R/peak_quality/peak_quality_config.R")
source("R/peak_quality/run_log.R")           # log on disk / job estimate / snapshot
source("R/peak_quality/eic_smooth.R")        # XIC smoothing before analysis
source("R/peak_quality/vendor/squallms_qscore.R")   # verbatim upstream code
source("R/peak_quality/score_adapter.R")
source("R/peak_quality/xic_extract.R")
source("R/peak_quality/peak_detect.R")
source("R/peak_quality/presence.R")
source("R/peak_quality/peak_table.R")
source("R/peak_quality/feature_summary.R")
source("R/peak_quality/pipeline.R")
source("R/peak_quality/plot_peak_quality.R")
source("R/peak_quality/method_registry.R")
source("R/peak_quality/cpc_adapter.R")
source("R/peak_quality/unified_results.R")
source("R/peak_quality/quality_class.R")     # provisional four-class verdict
source("R/peak_quality/compare_methods.R")
source("R/peak_quality/peak_group.R")
# DNN: peak-group image construction, then the bridge to the Python model.
# data must come first - integration calls into it.
source("R/peak_quality/pq_dnn_data.R")
source("R/peak_quality/pq_dnn_integration.R")
# The three published tables (GroupResults / SampleResults / MethodMetrics) and
# the provenance block. Needs the registry, the unified builder and the DNN
# bridge, so it is sourced last of the analytical files.
source("R/peak_quality/result_tables.R")
source("R/peak_quality/plot_compare.R")
source("R/peak_quality/export_peak_quality.R")
source("R/peak_quality/peak_quality_ui.R")
source("R/peak_quality/peak_quality_server.R")

# ============================================================
# Source MSGeter Modules
# ============================================================
source("shiny_app/ui/FeatureGeter_ui.R")
source("shiny_app/server/FeatureGeter_server.R")
source("shiny_app/ui/Ms2Geter_ui.R")
source("shiny_app/server/Ms2Geter_server.R")
source("shiny_app/ui/RtGeter_ui.R")
source("shiny_app/server/RtGeter_server.R")

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
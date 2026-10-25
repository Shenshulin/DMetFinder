# ============================================================
# MSGeter UI
# ============================================================

msgeter_ui <- fluidPage(
  hero_panel(
    title     = "MSGeter",
    subtitle  = "Mass Spectrometry Data Pre-processing - MS1 feature cleaning and MS2 library extraction",
    icon_name = "vial",
    variant   = "msgeter",
    chips     = c("Ms1Geter : MS1 cleaning + MS2 export",
                  "Ms2Geter : target-feature spectrum matching",
                  "RtGeter : exact RT for a whole peak table",
                  "Thermo .raw / .mzML / .mzXML")
  ),

  tabsetPanel(
    id   = "msg_tabs",
    type = "pills",
    tabPanel("Ms1Geter", icon = icon("wave-square"),  FeatureGeter_ui("FeatureGeter")),
    tabPanel("Ms2Geter", icon = icon("layer-group"),  Ms2Geter_ui("Ms2Geter")),
    tabPanel("RtGeter",  icon = icon("crosshairs"),   RtGeter_ui("RtGeter"))
  )
)

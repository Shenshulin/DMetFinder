# ============================================================
# MSGeter UI
# ============================================================

msgeter_ui <- fluidPage(
  tabsetPanel(
    tabPanel("Ms1Geter", FeatureGeter_ui("FeatureGeter")),
    tabPanel("Ms2Geter", Ms2Geter_ui("Ms2Geter"))
  )
)
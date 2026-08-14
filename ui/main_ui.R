# ============================================================
# Combined UI
# ============================================================

ui <- navbarPage(
  title = "DMetFinder & MSGeter",
  tabPanel("MSGeter", msgeter_ui),
  tabPanel("DMetFinder", dmetfinder_ui)
)
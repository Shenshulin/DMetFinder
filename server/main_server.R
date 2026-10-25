# ============================================================
# Main Server
# ============================================================

server <- function(input, output, session) {
  
  # ============ DMetFinder Server ============
  dmetfinder_server(input, output, session)
  
  # ============ MSGeter Server ============
  FeatureGeter_server("FeatureGeter")
  Ms2Geter_server("Ms2Geter")
  RtGeter_server("RtGeter")

  # ============ Peak Quality Server ============
  peak_quality_server("PeakQuality")
}
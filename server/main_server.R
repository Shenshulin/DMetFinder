# ============================================================
# Main Server
# ============================================================

server <- function(input, output, session) {

  # Automatic reconnect after a disconnect.
  # Shiny disallows session resumption by default: as soon as the WebSocket
  # between browser and server drops (tab suspended by the OS, laptop resumed
  # from sleep, Chrome discarding a background tab), the page is stuck behind
  # the grey overlay forever and only a manual refresh helps -- but a manual
  # refresh starts a new session and every uploaded peak table / finished
  # result is lost. With this switch on, the client reconnects by itself and
  # recovers the original session as long as the server process is still alive.
  session$allowReconnect(TRUE)

  # ============ DMetFinder Server ============
  dmetfinder_server(input, output, session)
  
  # ============ MSGeter Server ============
  FeatureGeter_server("FeatureGeter")
  Ms2Geter_server("Ms2Geter")
  RtGeter_server("RtGeter")

  # ============ Peak Quality Server ============
  # Shares the same switch as ui/main_ui.R (ui_show_peak_quality in
  # R/config.R): when the tab is not shown the server is not mounted either,
  # so no background work runs for something nobody can see.
  if (isTRUE(ui_show_peak_quality)) {
    peak_quality_server("PeakQuality")
  }
}
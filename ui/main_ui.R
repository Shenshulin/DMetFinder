# ============================================================
# Combined UI
# ============================================================
# Visual layer comes from shiny_app/ui/theme.R (must be sourced
# before this file): app_theme() = Bootstrap 5 variables,
# app_css() = component styles.
# ============================================================

# Main pipeline tabs: MSGeter (pre-processing) + DMetFinder (differential screening).
dmf_tabs <- list(
  tabPanel("MSGeter",    icon = icon("vial"),                   msgeter_ui),
  tabPanel("DMetFinder", icon = icon("magnifying-glass-chart"), dmetfinder_ui)
)

# Peak Quality is currently not exposed: no code was removed, only the entry
# point is switched off. The switch is ui_show_peak_quality in R/config.R;
# setting it to TRUE restores the tab.
if (isTRUE(ui_show_peak_quality)) {
  dmf_tabs <- c(dmf_tabs, list(
    tabPanel("Peak Quality", icon = icon("chart-line"),
             peak_quality_ui("PeakQuality"))
  ))
}

ui <- do.call(
  navbarPage,
  c(list(
    title = tags$span(
      class = "app-brand",
      tags$span(class = "app-brand__mark", icon("flask-vial")),
      tags$span(class = "app-brand__text",
                "DMetFinder",
                tags$small("& MSGeter"))
    ),
    windowTitle = "DMetFinder & MSGeter | Metabolomics Analysis Platform",
    theme       = app_theme(),
    header      = app_css(),
    collapsible = TRUE
  ), dmf_tabs)
)

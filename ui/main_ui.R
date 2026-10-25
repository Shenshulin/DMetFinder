# ============================================================
# Combined UI
# ============================================================
# Visual layer comes from shiny_app/ui/theme.R (must be sourced
# before this file): app_theme() = Bootstrap 5 variables,
# app_css() = component styles.
# ============================================================

ui <- navbarPage(
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
  collapsible = TRUE,

  tabPanel("MSGeter",    icon = icon("vial"),                  msgeter_ui),
  tabPanel("DMetFinder", icon = icon("magnifying-glass-chart"), dmetfinder_ui),
  tabPanel("Peak Quality", icon = icon("chart-line"),
           peak_quality_ui("PeakQuality"))
)

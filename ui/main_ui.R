# ============================================================
# Combined UI
# ============================================================
# Visual layer comes from shiny_app/ui/theme.R (must be sourced
# before this file): app_theme() = Bootstrap 5 variables,
# app_css() = component styles.
# ============================================================

# 主流程页签：MSGeter（前处理）+ DMetFinder（差异筛选）。
dmf_tabs <- list(
  tabPanel("MSGeter",    icon = icon("vial"),                   msgeter_ui),
  tabPanel("DMetFinder", icon = icon("magnifying-glass-chart"), dmetfinder_ui)
)

# 质量检测（Peak Quality）当前不对外展示：不改代码、只关入口，
# 开关在 R/config.R 的 ui_show_peak_quality。置 TRUE 即恢复该页签。
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

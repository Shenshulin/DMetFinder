# ============================================================
# Shared UI Theme - single source of truth for all entry points
# ============================================================
# Provides:
#   app_theme()  -> bslib::bs_theme() object (Bootstrap 5 variables)
#   app_css()    -> <style> tag with component-level styling
#   hero_panel() -> module hero banner
#   sub_bar()    -> section sub-header
#   format_hint()-> inline format/notice hint
#
# Usage (project root app.R):
#   source("shiny_app/ui/theme.R")
#   ui <- navbarPage(..., theme = app_theme(), header = app_css(), ...)
#
# Usage (standalone shiny_app/app.R):
#   source("ui/theme.R")
#   ui <- fluidPage(theme = app_theme(), app_css(), ...)
#
# Style only - no functional behaviour is changed.
# ============================================================


# ------------------------------------------------------------
# 1. Bootstrap 5 variable layer
# ------------------------------------------------------------
app_theme <- function() {
  if (!requireNamespace("bslib", quietly = TRUE)) return(NULL)
  tryCatch(
    bslib::bs_theme(
      version       = 5,
      bg            = "#f5f7fb",
      fg            = "#1f2937",
      primary       = "#4f46e5",
      secondary     = "#64748b",
      success       = "#0f9d58",
      info          = "#0284c7",
      warning       = "#d97706",
      danger        = "#dc2626",
      base_font     = "system-ui, -apple-system, 'Segoe UI', 'Microsoft YaHei', 'PingFang SC', 'Hiragino Sans GB', sans-serif",
      code_font     = "'Cascadia Mono', Consolas, 'Courier New', monospace",
      font_scale    = 0.95,
      border_radius = "0.7rem",
      spacer        = "0.9rem"
    ),
    error = function(e) {
      message("[app_theme] bslib theme unavailable, using Shiny defaults: ",
              conditionMessage(e))
      NULL
    }
  )
}


# ------------------------------------------------------------
# 2. Component-level CSS
# ------------------------------------------------------------
APP_CSS <- "
/* ==================== base ==================== */
body {
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
  background: #f5f7fb;
  color: #1f2937;
}
.container-fluid { max-width: 1680px; padding-left: 22px; padding-right: 22px; }
hr { border-top: 1px solid #e8ebf3; opacity: 1; margin: 16px 0; }
a { text-decoration: none; }

/* ==================== navbar ==================== */
.navbar {
  background: #ffffff;
  border: 0;
  border-bottom: 1px solid #e8ebf3;
  box-shadow: 0 10px 30px -26px rgba(15, 23, 42, .85);
  padding: 6px 14px;
  margin-bottom: 0;
}
.navbar .navbar-brand {
  display: flex; align-items: center; gap: 10px;
  font-weight: 750; font-size: 1.06rem; letter-spacing: .2px;
  color: #1e293b; padding: 6px 14px 6px 4px; height: auto;
}
.app-brand__mark {
  width: 34px; height: 34px; border-radius: 11px;
  display: grid; place-items: center;
  background: linear-gradient(135deg, #4f46e5 0%, #0ea5e9 100%);
  color: #fff; font-size: 15px; line-height: 1;
  box-shadow: 0 6px 16px -6px rgba(79, 70, 229, .8);
}
.app-brand__text { display: flex; align-items: baseline; gap: 6px; }
.app-brand__text small { font-size: .74rem; font-weight: 600; color: #94a3b8; letter-spacing: .3px; }

.navbar .navbar-nav { display: flex; align-items: center; gap: 4px; }
.navbar .navbar-nav > a,
.navbar .navbar-nav > li > a {
  color: #4b5563; font-weight: 650; font-size: .92rem;
  padding: 9px 15px; border-radius: 10px; position: relative;
  transition: background .16s ease, color .16s ease;
}
.navbar .navbar-nav > a:hover,
.navbar .navbar-nav > li > a:hover { background: #f1f5ff; color: #4338ca; }
.navbar .navbar-nav > a.active,
.navbar .navbar-nav > li > a.active,
.navbar .navbar-nav > a[aria-selected='true'] { color: #4338ca; background: #eef2ff; }
.navbar .navbar-nav > a.active::after,
.navbar .navbar-nav > li > a.active::after,
.navbar .navbar-nav > li.active > a::after {
  content: ''; position: absolute; left: 15px; right: 15px; bottom: 2px; height: 3px;
  border-radius: 3px; background: linear-gradient(90deg, #4f46e5, #0ea5e9);
}
.navbar .navbar-nav .fa, .navbar .navbar-nav .fas, .navbar .navbar-nav .far { margin-right: 6px; }

/* ==================== hero banner ==================== */
.app-hero {
  position: relative; overflow: hidden;
  border-radius: 18px; padding: 24px 28px; margin: 20px 0 22px;
  color: #fff;
  background: linear-gradient(120deg, #4f46e5 0%, #6366f1 48%, #0ea5e9 100%);
  box-shadow: 0 22px 44px -26px rgba(49, 46, 129, .85);
}
.app-hero--dmetfinder { background: linear-gradient(120deg, #6d28d9 0%, #6366f1 52%, #4f46e5 100%); }
.app-hero--msgeter    { background: linear-gradient(120deg, #0369a1 0%, #2563eb 52%, #4f46e5 100%); }
.app-hero__glow {
  position: absolute; border-radius: 50%;
  background: rgba(255, 255, 255, .13); pointer-events: none;
}
.app-hero__glow--1 { width: 260px; height: 260px; right: -70px; top: -120px; }
.app-hero__glow--2 { width: 170px; height: 170px; right: 110px; bottom: -110px; background: rgba(255,255,255,.09); }
.app-hero__inner { position: relative; display: flex; align-items: center; gap: 18px; }
.app-hero__icon {
  flex: 0 0 auto; width: 56px; height: 56px; border-radius: 16px;
  display: grid; place-items: center; font-size: 24px;
  background: rgba(255, 255, 255, .18);
  border: 1px solid rgba(255, 255, 255, .28);
  box-shadow: inset 0 1px 0 rgba(255,255,255,.35);
}
.app-hero__title { margin: 0; font-size: 1.55rem; font-weight: 780; letter-spacing: .2px; color: #fff; }
.app-hero__subtitle { margin: 5px 0 0; font-size: .93rem; color: rgba(255, 255, 255, .9); }
.app-hero__chips { margin-top: 12px; display: flex; flex-wrap: wrap; gap: 8px; }
.app-hero__chips .chip {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 5px 12px; border-radius: 999px; font-size: .78rem; font-weight: 600;
  background: rgba(255, 255, 255, .17);
  border: 1px solid rgba(255, 255, 255, .3);
  color: #fff;
}

/* ==================== sub header ==================== */
.sub-bar {
  display: flex; align-items: center; gap: 11px;
  padding: 13px 18px; margin: 16px 0 18px;
  background: #fff; border: 1px solid #e8ebf3; border-radius: 14px;
  box-shadow: 0 12px 30px -26px rgba(15, 23, 42, .7);
}
.sub-bar__icon {
  width: 36px; height: 36px; border-radius: 11px; flex: 0 0 auto;
  display: grid; place-items: center; font-size: 15px;
  background: #eef2ff; color: #4f46e5;
}
.sub-bar__title { margin: 0; font-size: 1.06rem; font-weight: 730; color: #1f2937; }
.sub-bar__subtitle { margin: 2px 0 0; font-size: .83rem; color: #6b7280; }

/* ==================== cards / sections ==================== */
.section-box, .card-panel {
  background: #fff;
  border: 1px solid #e8ebf3;
  border-radius: 16px;
  padding: 20px 22px;
  margin-bottom: 18px;
  box-shadow: 0 14px 36px -32px rgba(15, 23, 42, .9);
}
.section-title {
  position: relative; margin: 0 0 16px;
  padding-left: 13px;
  font-size: 1rem; font-weight: 750; color: #1f2937;
  border: 0;
}
.section-title::before {
  content: ''; position: absolute; left: 0; top: 50%; transform: translateY(-50%);
  width: 4px; height: 1.05em; border-radius: 3px;
  background: linear-gradient(180deg, #4f46e5, #0ea5e9);
}
.section-title .fa, .section-title .fas { color: #6366f1; margin-right: 7px; }

/* keep legacy title-panel working if used */
.title-panel {
  background: linear-gradient(120deg, #6d28d9 0%, #6366f1 52%, #4f46e5 100%);
  color: #fff; padding: 22px 26px; border-radius: 18px; margin: 20px 0 22px;
}
.title-panel h2 { margin: 0; font-weight: 760; }
.title-panel p { margin: 6px 0 0; opacity: .92; }

/* ==================== sidebar ==================== */
.well {
  background: #fff;
  border: 1px solid #e8ebf3;
  border-radius: 16px;
  padding: 18px 18px 20px;
  box-shadow: 0 14px 36px -32px rgba(15, 23, 42, .9);
  margin-bottom: 18px;
}
.side-group {
  padding: 14px 15px;
  border: 1px solid #eef1f7;
  border-radius: 13px;
  background: #fbfcfe;
  margin-bottom: 14px;
}
.side-group__title {
  display: flex; align-items: center; gap: 8px;
  font-size: .8rem; font-weight: 750; letter-spacing: .5px;
  text-transform: uppercase; color: #64748b; margin-bottom: 12px;
}
.side-group__title .fa, .side-group__title .fas { color: #6366f1; }

/* ==================== form controls ==================== */
.control-label, label.control-label {
  font-size: .84rem; font-weight: 650; color: #3f4756; margin-bottom: 5px;
}
.form-control, .form-select, select.form-control, textarea.form-control {
  border-radius: 10px;
  border: 1px solid #dbe2ef;
  background: #fff;
  font-size: .88rem;
  color: #1f2937;
  box-shadow: none;
  transition: border-color .16s ease, box-shadow .16s ease;
}
.form-control:focus, .form-select:focus {
  border-color: #818cf8;
  box-shadow: 0 0 0 .2rem rgba(99, 102, 241, .16);
}
.form-control::placeholder { color: #a9b2c3; }
select.form-control, .form-select { padding-right: 28px; }
.shiny-input-container { margin-bottom: 12px; }

/* checkboxes */
.checkbox label, .shiny-input-container .checkbox label { font-weight: 600; color: #3f4756; }

/* ==================== file input ==================== */
.shiny-input-container .input-group { display: flex; gap: 8px; align-items: stretch; flex-wrap: wrap; }
.input-group-btn, .input-group-prepend { display: flex; margin: 0; }
.btn-file {
  display: inline-flex; align-items: center; gap: 7px;
  border-radius: 10px !important;
  border: 1px dashed #b9c2d8 !important;
  background: #f8faff !important;
  color: #4338ca !important;
  font-weight: 650;
  padding: 8px 14px;
}
.btn-file:hover { background: #eef2ff !important; border-color: #818cf8 !important; }
.btn-file input[type='file'] { position: absolute; opacity: 0; }
.shiny-input-container .input-group .form-control[type='text'],
.shiny-input-container .input-group input.form-control {
  border-radius: 10px; background: #fbfcfe; color: #475569; font-size: .84rem;
}

/* ==================== buttons ==================== */
.btn {
  border-radius: 10px;
  font-weight: 650;
  font-size: .88rem;
  padding: 8px 16px;
  transition: transform .14s ease, box-shadow .18s ease, background .18s ease;
}
.btn-default, .btn-secondary {
  background: #fff; border: 1px solid #dbe2ef; color: #3f4756;
}
.btn-default:hover, .btn-secondary:hover { background: #f5f7ff; border-color: #b9c2d8; color: #4338ca; }
.btn-primary {
  background: linear-gradient(120deg, #4f46e5 0%, #6366f1 100%);
  border: 0; color: #fff;
  box-shadow: 0 10px 22px -14px rgba(79, 70, 229, .95);
}
.btn-primary:hover { transform: translateY(-1px); box-shadow: 0 14px 26px -14px rgba(79, 70, 229, 1); }
.btn-run {
  background: linear-gradient(120deg, #4f46e5 0%, #0ea5e9 100%) !important;
  border: 0 !important; color: #fff !important;
  font-weight: 750 !important; letter-spacing: .3px;
  box-shadow: 0 14px 28px -16px rgba(79, 70, 229, 1) !important;
}
.btn-run:hover { transform: translateY(-1px); }
.btn-lg { padding: 11px 24px; font-size: .95rem; }
.btn .fa, .btn .fas { margin-right: 6px; }

/* ==================== status boxes ==================== */
.status-box {
  display: flex; gap: 9px; align-items: flex-start;
  padding: 11px 14px; margin-top: 12px;
  border-radius: 11px; font-size: .86rem; line-height: 1.5;
  border: 1px solid transparent; border-left-width: 4px;
}
.status-box .fa, .status-box .fas { margin-top: 2px; }
.status-success { background: #ecfdf5; color: #0b6b45; border-color: #b7ebd4; border-left-color: #10b981; }
.status-error   { background: #fef2f2; color: #991b1b; border-color: #fbd5d5; border-left-color: #ef4444; }
.status-info    { background: #eff6ff; color: #1e40af; border-color: #cfe2ff; border-left-color: #3b82f6; }

/* ==================== hints ==================== */
.format-hint {
  display: flex; gap: 9px; align-items: flex-start;
  padding: 10px 13px; margin-bottom: 14px;
  background: #eef2ff; color: #3730a3;
  border: 1px solid #dfe3ff; border-radius: 11px;
  font-size: .81rem; line-height: 1.5;
}
.format-hint .fa, .format-hint .fas { margin-top: 2px; color: #6366f1; }
.hint-neutral { background: #f8fafc; color: #475569; border-color: #e8ebf3; }
.hint-neutral .fa, .hint-neutral .fas { color: #94a3b8; }
/* Used for settings that change the meaning of the numbers, not just their
   value (e.g. smoothing an XIC before scoring). #92400e on #fffbeb = 8.6:1. */
.hint-warning { background: #fffbeb; color: #92400e; border-color: #fde68a; }
.hint-warning .fa, .hint-warning .fas { color: #b45309; }

/* ==================== log / console output ==================== */
pre.shiny-text-output,
.log-box pre,
.console-box pre {
  background: #0b1220 !important;
  color: #a5f3fc !important;
  border: 1px solid #1e293b !important;
  border-radius: 12px !important;
  padding: 14px 15px !important;
  font-family: 'Cascadia Mono', Consolas, 'Courier New', monospace !important;
  font-size: 12.4px !important;
  line-height: 1.55 !important;
  max-height: 340px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
}
.log-box, .console-box { margin-top: 6px; }
.log-area textarea, textarea.log-area {
  background: #0b1220 !important;
  color: #d1fae5 !important;
  border: 1px solid #1e293b !important;
  border-radius: 12px !important;
  font-family: 'Cascadia Mono', Consolas, 'Courier New', monospace !important;
  font-size: 12.4px !important;
  line-height: 1.55 !important;
  padding: 13px !important;
}

/* ==================== tables (renderTable) ==================== */
table.table, .shiny-table-output table {
  font-size: .87rem;
  border-color: #eef1f7;
}
table.table > thead > tr > th {
  background: #f8fafc; color: #334155; font-weight: 700;
  border-bottom: 1px solid #e5e9f2 !important; white-space: nowrap;
}
table.table > tbody > tr > td { border-color: #eef1f7 !important; vertical-align: middle; }
table.table > tbody > tr:hover > * { background: #f5f7ff; }

/* ==================== DT tables ==================== */
.dataTables_wrapper { font-size: .87rem; }
table.dataTable { border-collapse: separate; border-spacing: 0; width: 100% !important; margin: 6px 0 10px; }
table.dataTable thead th {
  background: #f8fafc !important; color: #334155 !important;
  font-weight: 700 !important; font-size: .84rem;
  border-bottom: 1px solid #e5e9f2 !important;
  white-space: nowrap; padding: 10px 12px !important;
}
table.dataTable tbody td { padding: 9px 12px !important; border-color: #eef1f7 !important; color: #334155; }
table.dataTable tbody tr:hover > * { background: #f5f7ff !important; }
table.dataTable.stripe tbody tr.odd > * { background: #fcfdff; }
.dataTables_wrapper .dataTables_length select,
.dataTables_wrapper .dataTables_filter input {
  border-radius: 9px; border: 1px solid #dbe2ef; padding: 4px 9px; font-size: .84rem;
}
.dataTables_wrapper .dataTables_filter input:focus { border-color: #818cf8; box-shadow: 0 0 0 .18rem rgba(99,102,241,.15); }
.dataTables_wrapper .dataTables_info,
.dataTables_wrapper .dataTables_length,
.dataTables_wrapper .dataTables_filter { color: #64748b; font-size: .84rem; }
.dataTables_wrapper .pagination { gap: 4px; margin: 10px 0 4px; }
.dataTables_wrapper .pagination .page-link {
  border-radius: 9px !important; border: 1px solid #e5e9f2; color: #4f46e5;
  padding: 5px 11px; font-size: .84rem; font-weight: 600;
}
.dataTables_wrapper .pagination .page-link:hover { background: #eef2ff; border-color: #c7d2fe; }
.dataTables_wrapper .pagination .active .page-link {
  background: linear-gradient(120deg, #4f46e5, #6366f1); border-color: #4f46e5; color: #fff;
}
.dataTables_wrapper .pagination .disabled .page-link { color: #cbd5e1; }

/* ==================== tabs (inner tabsetPanel) ==================== */
.tabbable > .nav {
  gap: 4px; flex-wrap: wrap;
  border-bottom: 1px solid #e8ebf3;
  padding-bottom: 8px;
  margin-bottom: 16px;
}
.tabbable > .nav.nav-tabs > a,
.tabbable > .nav.nav-tabs > li > a {
  border: 1px solid transparent !important;
  border-radius: 10px;
  color: #4b5563; font-weight: 650; font-size: .88rem;
  padding: 8px 14px; margin: 0;
  transition: background .16s ease, color .16s ease;
}
.tabbable > .nav.nav-tabs > a:hover,
.tabbable > .nav.nav-tabs > li > a:hover { background: #f1f5ff; color: #4338ca; }
.tabbable > .nav.nav-tabs > li > a.active,
.tabbable > .nav.nav-tabs > a.active,
.tabbable > .nav.nav-tabs > li.active > a {
  background: #fff; border-color: #e8ebf3 !important; color: #4338ca;
  box-shadow: 0 8px 20px -18px rgba(15, 23, 42, .9);
}
.tabbable > .nav.nav-pills > a,
.tabbable > .nav.nav-pills > li > a {
  border-radius: 999px; color: #4b5563; font-weight: 650; font-size: .88rem;
  padding: 8px 16px;
  transition: background-color .16s ease, color .16s ease, box-shadow .16s ease;
}
.tabbable > .nav.nav-pills > a:hover,
.tabbable > .nav.nav-pills > li > a:hover { background: #eef2ff; color: #4338ca; }

/* NOTE: Bootstrap 5 puts `active` on the <a> (.nav-link.active); the <li> only
   carries .nav-item. The old BS3 form `li.active > a` silently matched nothing,
   which left the selected pill with a dark-grey label on the BS5 default fill.
   List both shapes so the rule holds on either markup. Contrast of #fff on this
   gradient is ~6.3-7.9:1 (WCAG AA for normal text needs 4.5:1). */
.tabbable > .nav.nav-pills > li > a.active,
.tabbable > .nav.nav-pills > a.active,
.tabbable > .nav.nav-pills > li.active > a,
.tabbable > .nav.nav-pills > li.show > a {
  background-color: #4338ca;
  background-image: linear-gradient(120deg, #4338ca 0%, #4f46e5 100%);
  color: #fff;
  box-shadow: 0 12px 24px -16px rgba(67, 56, 202, .95);
}
/* keep the selected pill clearly selected while hovering / focused */
.tabbable > .nav.nav-pills > li > a.active:hover,
.tabbable > .nav.nav-pills > li > a.active:focus,
.tabbable > .nav.nav-pills > li > a.active:active {
  background-color: #3730a3;
  background-image: linear-gradient(120deg, #3730a3 0%, #4338ca 100%);
  color: #fff;
}
.tabbable > .nav.nav-pills > li > a.active .fa,
.tabbable > .nav.nav-pills > li > a.active .fas { color: #fff; }
.tabbable > .nav.nav-pills > li > a:focus-visible {
  outline: 3px solid #c7d2fe; outline-offset: 2px;
}
.tabbable > .nav .fa, .tabbable > .nav .fas { margin-right: 6px; }

/* ==================== progress bar ==================== */
.progress {
  height: 8px; border-radius: 999px; background: #e8ebf3;
  box-shadow: none; overflow: hidden;
}
.progress-bar {
  background: linear-gradient(90deg, #4f46e5 0%, #0ea5e9 100%);
  box-shadow: 0 0 12px rgba(79, 70, 229, .5);
}
.shiny-notification {
  border-radius: 12px;
  border: 1px solid #e8ebf3;
  box-shadow: 0 18px 40px -22px rgba(15, 23, 42, .9);
}

/* ==================== result file list ==================== */
ul.file-list {
  list-style: none; padding: 0; margin: 4px 0 16px;
  display: grid; grid-template-columns: repeat(auto-fill, minmax(310px, 1fr)); gap: 9px;
}
ul.file-list li {
  display: flex; align-items: center; gap: 9px;
  background: #f8fafc; border: 1px solid #e8ebf3; border-radius: 11px;
  padding: 10px 13px; font-size: .85rem; color: #334155; font-weight: 600;
}
ul.file-list li .fa, ul.file-list li .fas { color: #16a34a; }
.badge-soft {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 3px 10px; border-radius: 999px;
  background: #eef2ff; color: #4338ca;
  font-size: .76rem; font-weight: 700;
}

/* ==================== path / value output (light box) ==================== */
.path-box pre.shiny-text-output {
  background: #f8fafc !important;
  color: #334155 !important;
  border: 1px solid #e8ebf3 !important;
  border-radius: 9px !important;
  padding: 8px 11px !important;
  font-size: .8rem !important;
  max-height: none;
  margin: 6px 0 12px;
}

/* sidebar action buttons span the full column width */
.well > .btn { width: 100%; margin-bottom: 14px; }
.well > .btn:last-child { margin-bottom: 18px; }

/* ==================== empty output placeholders ==================== */
.log-box pre.shiny-text-output:empty,
.console-box pre.shiny-text-output:empty {
  display: block !important;
  min-height: 58px;
}
.log-box pre.shiny-text-output:empty::before {
  content: 'Ready. Run the analysis to follow live progress.';
  color: #55698a;
  font-style: italic;
}
.path-box pre.shiny-text-output:empty { min-height: 34px; }
.path-box pre.shiny-text-output:empty::before {
  content: 'No folder selected';
  color: #99a3b5;
  font-style: italic;
}

/* ==================== Peak Quality module ==================== */
.mini-summary {
  margin: 4px 0 12px;
  padding: 8px 11px;
  border-radius: 9px;
  background: #eef2ff;
  color: #3730a3;
  font-size: .8rem;
  font-weight: 600;
  border: 1px solid #e0e7ff;
}
.mini-summary--muted {
  background: #f8fafc; color: #8290a6; border-color: #eef1f7; font-weight: 500;
}
.mini-summary__warn { margin-top: 5px; color: #b45309; font-weight: 600; }

.pq-cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(118px, 1fr));
  gap: 10px;
  margin-bottom: 16px;
}
.pq-card {
  background: #fff; border: 1px solid #e8ebf3; border-radius: 12px;
  padding: 12px 14px; text-align: left;
  box-shadow: 0 1px 2px rgba(15, 23, 42, .04);
}
.pq-card__value { font-size: 1.35rem; font-weight: 700; line-height: 1.1; color: #1f2937; }
.pq-card__label { font-size: .72rem; color: #6b7280; margin-top: 3px; text-transform: uppercase; letter-spacing: .04em; }
.pq-card--ok    { border-left: 4px solid #10b981; }
.pq-card--ok    .pq-card__value { color: #047857; }
.pq-card--warn  { border-left: 4px solid #f59e0b; }
.pq-card--warn  .pq-card__value { color: #b45309; }
.pq-card--bad   { border-left: 4px solid #ef4444; }
.pq-card--bad   .pq-card__value { color: #b91c1c; }
.pq-card--neutral { border-left: 4px solid #6366f1; }

.kv-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
  gap: 6px 18px;
}
.kv { display: flex; justify-content: space-between; gap: 10px; padding: 4px 0; border-bottom: 1px dashed #eef1f7; }
.kv__k { color: #6b7280; font-size: .8rem; }
.kv__v { color: #111827; font-size: .82rem; font-weight: 600; text-align: right; word-break: break-word; }

.table-tools {
  display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
  margin-bottom: 10px;
}
.table-tools .form-group { margin-bottom: 0; }
.table-tools .checkbox { margin: 0; font-size: .82rem; }
.peak-view__toggle .checkbox { margin-top: 26px; font-size: .8rem; color: #4b5563; }

.btn-soft {
  background: #eef2ff; color: #3730a3; border: 1px solid #e0e7ff;
  border-radius: 9px; font-weight: 600;
}
.btn-soft:hover, .btn-soft:focus {
  background: #e0e7ff; color: #312e81; border-color: #c7d2fe;
}
.btn-sm.btn-soft { padding: 4px 10px; font-size: .78rem; }

/* ==================== misc ==================== */
.text-muted, .help-block { color: #8a93a5 !important; font-size: .8rem; }
.shiny-output-error { color: #b91c1c; }
.shiny-output-error:before { content: '\\26A0  '; }
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: #f1f4f9; border-radius: 999px; }
::-webkit-scrollbar-thumb { background: #c8d1e0; border-radius: 999px; border: 2px solid #f1f4f9; }
::-webkit-scrollbar-thumb:hover { background: #a9b5c9; }

@media (max-width: 992px) {
  .app-hero { padding: 20px; }
  .app-hero__title { font-size: 1.3rem; }
  .app-hero__icon { width: 46px; height: 46px; font-size: 20px; }
  .container-fluid { padding-left: 14px; padding-right: 14px; }
}
"


# ------------------------------------------------------------
# 3. Helpers
# ------------------------------------------------------------

# <link rel="icon"> + <style> tag carrying APP_CSS
# (a bare style tag is used so it stays valid both inside <head> and in the
#  page body, where navbarPage(header = ...) / fluidPage(...) place it)
app_css <- function() {
  shiny::tagList(
    shiny::tags$link(rel = "icon", type = "image/svg+xml", href = "favicon.svg"),
    shiny::tags$style(shiny::HTML(APP_CSS))
  )
}

# Module hero banner
hero_panel <- function(title, subtitle = NULL, icon_name = NULL,
                       variant = c("default", "msgeter", "dmetfinder"),
                       chips = character()) {
  variant <- match.arg(variant)

  chips_html <- if (length(chips) > 0) {
    shiny::div(class = "app-hero__chips",
               lapply(chips, function(ch) shiny::span(class = "chip", ch)))
  }

  shiny::div(
    class = paste("app-hero", paste0("app-hero--", variant)),
    shiny::div(class = "app-hero__glow app-hero__glow--1"),
    shiny::div(class = "app-hero__glow app-hero__glow--2"),
    shiny::div(
      class = "app-hero__inner",
      if (!is.null(icon_name)) shiny::div(class = "app-hero__icon", shiny::icon(icon_name)),
      shiny::div(
        class = "app-hero__text",
        shiny::h2(class = "app-hero__title", title),
        if (!is.null(subtitle)) shiny::p(class = "app-hero__subtitle", subtitle),
        chips_html
      )
    )
  )
}

# Section sub-header inside a tab
sub_bar <- function(title, subtitle = NULL, icon_name = "circle-dot") {
  shiny::div(
    class = "sub-bar",
    shiny::div(class = "sub-bar__icon", shiny::icon(icon_name)),
    shiny::div(
      shiny::h4(class = "sub-bar__title", title),
      if (!is.null(subtitle)) shiny::p(class = "sub-bar__subtitle", subtitle)
    )
  )
}

# Inline hint box (variant = "info" | "neutral" | "warning")
format_hint <- function(text, icon_name = "circle-info", variant = "info") {
  variant <- as.character(variant)[1]
  cls <- switch(variant,
                neutral = "hint-neutral",
                warning = "hint-warning",
                "")
  shiny::div(
    class = paste("format-hint", cls),
    shiny::icon(icon_name),
    shiny::span(text)
  )
}

# Grouped sidebar card
side_group <- function(title, icon_name = "sliders", ...) {
  shiny::div(
    class = "side-group",
    shiny::div(class = "side-group__title",
               shiny::icon(icon_name),
               shiny::span(title)),
    ...
  )
}

# Card panel with decorated title
card_panel <- function(title, icon_name = NULL, ...) {
  shiny::div(
    class = "section-box",
    shiny::h4(
      class = "section-title",
      if (!is.null(icon_name)) shiny::icon(icon_name),
      title
    ),
    ...
  )
}

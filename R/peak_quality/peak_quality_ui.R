# ============================================================
# Peak Quality Assessment - UI
# ============================================================
# A new, self-contained module. It does not touch Ms1Geter / Ms2Geter /
# DMetFinder inputs, outputs or layout. Visual helpers come from
# shiny_app/ui/theme.R (sub_bar / side_group / card_panel / format_hint).
# ============================================================

peak_quality_ui <- function(id) {
  ns <- NS(id)

  fluidPage(
    sub_bar("Peak Quality Assessment",
            paste("Re-extract the XIC of user-supplied features from raw files,",
                  "locate candidate peak boundaries, and score peak shape with",
                  "the Kumler et al. (2023) metrics"),
            "chart-line"),

    sidebarLayout(
      sidebarPanel(
        width = 4,

        format_hint(paste("Supported raw formats: .raw (Thermo), .mzML, .mzXML.",
                          "The peak table only needs feature id, m/z and RT;",
                          "peak start/end RT are located automatically."),
                    "circle-info"),

        # ---------------- input ----------------
        side_group("1. Raw files", "folder-open",
          radioButtons(ns("source_type"), NULL,
                       choices = c("Scan a folder" = "dir",
                                   "Upload files" = "upload"),
                       selected = "dir", inline = TRUE),
          conditionalPanel(
            condition = sprintf("input['%s'] == 'dir'", ns("source_type")),
            textInput(ns("workdir"), "Folder containing raw files",
                      value = "G:/method_ms2/MSDIAL_TEST"),
            actionButton(ns("scan"), "Scan folder",
                         icon = icon("magnifying-glass"),
                         class = "btn-soft")
          ),
          conditionalPanel(
            condition = sprintf("input['%s'] == 'upload'", ns("source_type")),
            fileInput(ns("raw_upload"), "Upload .raw / .mzML / .mzXML",
                      multiple = TRUE,
                      accept = c(".raw", ".mzML", ".mzXML", ".mzml", ".mzxml"))
          ),
          uiOutput(ns("file_summary"))
        ),

        # ---------------- peak table ----------------
        side_group("2. Peak table", "table-list",
          fileInput(ns("peak_table"), "Feature list (CSV / TSV / XLSX)",
                    accept = c(".csv", ".tsv", ".txt", ".xlsx", ".xls")),
          downloadLink(ns("template"), "Download an empty template"),
          fileInput(ns("sample_map"), "Optional: sample_id -> file map (CSV)",
                    accept = c(".csv", ".tsv", ".txt")),
          uiOutput(ns("peak_table_summary"))
        ),

        # ---------------- mapping ----------------
        side_group("3. Field mapping", "diagram-project",
          uiOutput(ns("mapping_ui")),
          selectInput(ns("rt_unit"), "RT unit in the peak table",
                      choices = c("minutes" = "min", "seconds" = "sec"),
                      selected = "min"),
          selectInput(ns("sample_scope"), "Sample scope",
                      choices = PQ_SCOPE_CHOICES, selected = "auto"),
          conditionalPanel(
            condition = sprintf("input['%s'] != 'by_column'", ns("sample_scope")),
            format_hint(paste("An aligned table (MS-DIAL / MZmine) has one row",
                              "per feature with a shared average m/z and RT.",
                              "Each feature is then evaluated in every raw file",
                              "and summarised per feature. The table RT is an",
                              "average, so allow for RT drift between samples."),
                        "circle-info", "neutral")
          )
        ),

        # ---------------- parameters ----------------
        side_group("4. Extraction parameters", "sliders",
          fluidRow(
            column(6, selectInput(ns("mz_tol_unit"), "m/z tolerance unit",
                                  choices = c("ppm" = "ppm", "Da" = "Da"),
                                  selected = "ppm")),
            column(6, conditionalPanel(
              condition = sprintf("input['%s'] == 'ppm'", ns("mz_tol_unit")),
              numericInput(ns("mz_tol_ppm"), "Tolerance (ppm)",
                           value = 10, min = 0.1, max = 100, step = 0.5)
            ))
          ),
          conditionalPanel(
            condition = sprintf("input['%s'] == 'Da'", ns("mz_tol_unit")),
            numericInput(ns("mz_tol_da"), "Tolerance (Da)",
                         value = 0.005, min = 0.0001, max = 0.5, step = 0.001)
          ),
          selectInput(ns("xic_aggregate"), "Inside the m/z window, use",
                      choices = PQ_AGGREGATE_CHOICES, selected = "max"),
          format_hint(paste("Several ions can fall inside the tolerance window.",
                            "The default keeps the highest intensity per scan and",
                            "never sums them; the applied strategy is recorded",
                            "with every result row."),
                      "circle-info", "neutral"),
          numericInput(ns("rt_window"), "RT search half-window (min)",
                       value = 0.30, min = 0.01, max = 5, step = 0.01),
          numericInput(ns("min_points"), "Minimum scans inside the peak",
                       value = 5, min = 3, max = 50, step = 1),
          numericInput(ns("max_features"), "Maximum features per run (peak-table rows)",
                       value = 20000, min = 1, max = 500000, step = 500),
          format_hint(paste("This limit applies to the rows of the peak table",
                            "BEFORE an aligned table is expanded, so a 3450-row",
                            "aligned table evaluated in 20 raw files runs in full",
                            "(69000 sample rows)."),
                      "circle-info", "neutral"),
          numericInput(ns("max_expanded_rows"), "Maximum rows per run (after expansion)",
                       value = 200000, min = 100, max = 5000000, step = 1000),
          format_hint("Exceeding this aborts the run; rows are never dropped silently.",
                      "circle-exclamation", "neutral"),
          format_hint("Files are processed one after another; this architecture has no parallel backend.",
                      "circle-info", "neutral")
        ),

        # ---------------- XIC smoothing ----------------
        side_group("5. XIC smoothing before analysis", "wave-square",
          format_hint(paste("Off by default. When enabled, the smoothed trace is",
                            "what boundary detection, peak_cor/SNR, the CPC",
                            "input and the peak-group image all use - so the",
                            "scores are no longer the author's raw-data output",
                            "and are NOT comparable to a raw run."),
                      "circle-exclamation", "warning"),
          selectInput(ns("eic_smooth_method"), "Smoothing",
                      choices = PQ_EIC_SMOOTH_CHOICES, selected = "none"),
          numericInput(ns("eic_smooth_window"), "Window (scans, odd)",
                       value = 7, min = 3, max = 31, step = 2),
          format_hint(paste("Savitzky-Golay fits a local quadratic, so it removes",
                            "noise while keeping peak height and width; a moving",
                            "average flattens the apex more. Presence, peak height",
                            "and the point-to-point noise are ALWAYS measured on",
                            "the raw trace, so smoothing cannot turn noise into a",
                            "present peak. A trace shorter than the window is left",
                            "unsmoothed and the reason is recorded per row."),
                      "circle-info", "neutral")
        ),

        # ---------------- presence ----------------
        side_group("6. Peak presence (absent in a sample)", "circle-half-stroke",
          checkboxInput(ns("detect_absent"),
                        "Report samples without the peak as absent",
                        value = TRUE),
          numericInput(ns("absent_snr"), "Minimum peak height / point-to-point noise",
                       value = 5, min = 0, max = 100, step = 0.5),
          numericInput(ns("absent_min_points"), "Minimum XIC points to count as present",
                       value = 3, min = 1, max = 50, step = 1),
          format_hint(paste("An aligned table asks for every feature in every",
                            "sample, but a compound is often not in all of them.",
                            "Absent rows are kept in the results with the reason,",
                            "are not scored and are NOT counted as failures; the",
                            "per-feature summary computes its percentages over",
                            "present samples only. Set the noise ratio to 0 to",
                            "disable the intensity test."),
                      "circle-info", "neutral")
        ),

        # ---------------- boundary ----------------
        side_group("7. Boundary detection", "bezier-curve",
          format_hint("These rules are new pre-processing, not part of the paper's metrics.",
                      "circle-exclamation", "neutral"),
          numericInput(ns("min_prominence_frac"), "Min. prominence (fraction of range)",
                       value = 0.05, min = 0, max = 1, step = 0.01),
          numericInput(ns("min_rel_prominence"), "Min. prominence relative to the strongest apex",
                       value = 0.25, min = 0, max = 1, step = 0.05),
          numericInput(ns("min_height_frac"), "Min. apex height (fraction of range)",
                       value = 0.10, min = 0, max = 1, step = 0.01),
          numericInput(ns("edge_frac"), "Boundary must fall below (fraction of apex)",
                       value = 0.10, min = 0, max = 1, step = 0.01),
          numericInput(ns("valley_frac"), "Valley depth that splits two peaks (fraction)",
                       value = 0.05, min = 0, max = 1, step = 0.01),
          numericInput(ns("apex_tolerance"), "Apex tolerance vs input RT (min)",
                       value = 0.20, min = 0, max = 5, step = 0.01),
          numericInput(ns("smooth_points"), "Extra apex-search smoothing (odd, 0 = off)",
                       value = 0, min = 0, max = 21, step = 2),
          format_hint(paste("This one only helps locate the apex; it never changes",
                            "the intensities that are scored. It is applied on top",
                            "of the analysis trace from section 5."),
                      "circle-info", "neutral")
        ),

        # ---------------- scoring methods ----------------
        side_group("8. Scoring methods", "flask",
          uiOutput(ns("method_choices_ui")),
          numericInput(ns("cpc_max_rows"), "CPC: maximum rows per run",
                       value = 20000, min = 1, max = 500000, step = 1000),
          format_hint(paste("CPC is an external, compiled package (GPL) and is",
                            "only executed when it is installed and ticked.",
                            "Rows beyond the limit are reported as 'not_run',",
                            "never dropped. No method removes a peak."),
                      "circle-info", "neutral"),
          uiOutput(ns("method_status_ui"))
        ),

        # ---------------- cross-sample peak group ----------------
        side_group("9. Cross-sample peak group", "layer-group",
          format_hint(paste("Input for the Kantz 2019 network. The author code",
                            "ships no trained weights, so this build only builds",
                            "and visualises the peak-group image and diagnoses",
                            "missing samples - it never outputs a probability."),
                      "circle-exclamation", "neutral"),
          numericInput(ns("group_n_slices"), "Image width (RT bins)",
                       value = 64, min = 8, max = 512, step = 8),
          numericInput(ns("group_min_series"), "Minimum samples with signal in a group",
                       value = 2, min = 1, max = 200, step = 1),
          checkboxInput(ns("group_pad"),
                        "Pad the image to fixed rows (author: 30 or 63)",
                        value = FALSE)
        ),

        actionButton(ns("run"), "Run peak quality assessment",
                     class = "btn-run btn-lg", icon = icon("play")),

        side_group("Log", "terminal",
          div(class = "log-box", verbatimTextOutput(ns("log")))
        )
      ),

      mainPanel(
        width = 8,
        tabsetPanel(
          id = ns("result_tabs"),
          type = "pills",

          tabPanel("Results", icon = icon("table"),
            br(),
            uiOutput(ns("status_cards")),
            br(),
            uiOutput(ns("quality_cards")),
            card_panel("Peak quality table", "table",
              div(class = "table-tools",
                radioButtons(ns("table_view"), NULL, inline = TRUE,
                             choices = c("Per sample" = "sample",
                                         "Per feature" = "feature"),
                             selected = "sample"),
                selectInput(ns("presence_filter"), NULL,
                            choices = c("All rows" = "all",
                                        "Peak present only" = "present",
                                        "Absent only" = "absent"),
                            selected = "all", width = "170px"),
                checkboxInput(ns("only_problems"),
                              "Show only rows needing review", value = FALSE),
                downloadButton(ns("dl_csv"), "CSV", class = "btn-soft btn-sm"),
                downloadButton(ns("dl_xlsx"), "XLSX", class = "btn-soft btn-sm"),
                downloadButton(ns("dl_report"), "Full report (ZIP)", class = "btn-soft btn-sm")
              ),
              conditionalPanel(
                condition = sprintf("input['%s'] == 'sample'", ns("table_view")),
                DTOutput(ns("results_table"))
              ),
              conditionalPanel(
                condition = sprintf("input['%s'] == 'feature'", ns("table_view")),
                p(class = "text-muted",
                  paste("Descriptive summary of the per-sample results of each",
                        "feature: median and worst value are both kept. It does",
                        "not decide whether a feature is good.")),
                DTOutput(ns("feature_summary_table"))
              )
            )
          ),

          tabPanel("Peak view", icon = icon("chart-area"),
            br(),
            fluidRow(
              column(7, uiOutput(ns("peak_selector"))),
              column(5, div(class = "peak-view__toggle",
                            checkboxInput(ns("show_fit"),
                                          "Show beta fit + residuals (display-only reconstruction)",
                                          value = FALSE)))
            ),
            uiOutput(ns("peak_plot_ui")),
            uiOutput(ns("peak_detail_ui"))
          ),

          tabPanel("Compare methods", icon = icon("scale-balanced"),
            br(),
            uiOutput(ns("compare_empty_ui")),
            uiOutput(ns("compare_cards")),
            card_panel("Method agreement", "handshake",
              p(class = "text-muted",
                paste("The two methods are not combined into a score. These",
                      "counts only say where they produced a usable result, and",
                      "how far their boundaries are apart.")),
              DTOutput(ns("compare_summary"))
            ),
            card_panel("Side-by-side results (one row per feature and sample)", "table-columns",
              div(class = "table-tools",
                selectInput(ns("compare_filter"), NULL, width = "260px",
                            choices = c("Rows where the methods disagree" = "disagree",
                                        "All compared rows" = "all",
                                        "Both scored" = "both_scored",
                                        "Only Kumler scored" = "kumler_only",
                                        "Only CPC scored" = "cpc_only")),
                downloadButton(ns("dl_compare"), "CSV", class = "btn-soft btn-sm")
              ),
              p(class = "text-muted",
                paste("Every column belongs to exactly one method: kumler_*,",
                      "cpc_*. No column mixes them, and no column is a total.",
                      "'d_*_rt' are simple differences in minutes, provided for",
                      "review, not as a quality verdict.")),
              DTOutput(ns("compare_table"))
            ),
            card_panel("Native metrics (long format)", "list",
              p(class = "text-muted",
                paste("This is where the metric names live: one row per metric,",
                      "with its own unit. area is 'intensity x scan count'",
                      "because of the author's integration bug; sn is the",
                      "author's value and is never used as a filter.")),
              DTOutput(ns("metrics_table"))
            ),
            card_panel("Unified result structure", "diagram-project",
              p(class = "text-muted",
                paste("The exported unified table has the agreed columns:",
                      "feature_id, sample_id, mz, input_rt, start_rt, apex_rt,",
                      "end_rt, n_points, method, raw_score, quality_probability,",
                      "boundary_status, score_status, failure_reason, plus the",
                      "traceability columns. quality_probability stays empty:",
                      "neither of these methods emits a probability.")),
              DTOutput(ns("unified_preview"))
            )
          ),

          tabPanel("By software", icon = icon("code-compare"),
            br(),
            card_panel("Same raw files, same tolerances, same rules", "scale-unbalanced",
              p(class = "text-muted",
                paste("Every candidate - whichever tool proposed it - is",
                      "re-extracted from the same raw file and scored by the",
                      "same rules. The tools' own internal scores are never",
                      "read or compared. The 'software' column of the peak",
                      "table is the only input to this grouping; rows without",
                      "it are reported as (not stated), never dropped.")),
              uiOutput(ns("software_note_ui")),
              DTOutput(ns("software_table"))
            ),
            card_panel("Raw metric distribution per software", "chart-simple",
              p(class = "text-muted",
                paste("Distribution, not ranking. A tool that reports fewer,",
                      "easier candidates can win on any per-candidate average,",
                      "so read the count next to each row.")),
              DTOutput(ns("software_metrics_table"))
            ),
            card_panel("Quality class per software", "table-cells",
              div(class = "table-tools",
                downloadButton(ns("dl_software"), "CSV", class = "btn-soft btn-sm")),
              DTOutput(ns("software_class_table"))
            )
          ),

          tabPanel("Peak group", icon = icon("layer-group"),
            br(),
            uiOutput(ns("group_intro_ui")),
            fluidRow(
              column(7, uiOutput(ns("group_selector"))),
              column(5, div(class = "peak-view__toggle",
                            actionButton(ns("build_groups"),
                                         "Build peak-group diagnostics for all features",
                                         class = "btn-soft btn-sm",
                                         icon = icon("table-list"))))
            ),
            uiOutput(ns("group_plot_ui")),
            uiOutput(ns("group_detail_ui"))
          ),

          tabPanel("DNN", icon = icon("brain"),
            br(),
            card_panel("Model state", "microchip",
              p(class = "text-muted",
                paste("The DNN from Kantz et al. 2019 scores a whole peak",
                      "group (the same feature across samples), not a single",
                      "(feature, sample) peak. Its verdict is therefore shown",
                      "here and never merged into quality_class: a peak the",
                      "model likes can still tail, front or be badly bounded.")),
              uiOutput(ns("dnn_available_ui")),
              uiOutput(ns("dnn_run_ui")),
              DTOutput(ns("dnn_status_table"))
            ),
            card_panel("What the score means", "circle-info",
              p(class = "text-muted", uiOutput(ns("dnn_meaning_ui"))),
              p(class = "text-muted", uiOutput(ns("dnn_separation_ui")))
            ),
            card_panel("Peak-group predictions", "table-list",
              p(class = "text-muted",
                paste("One row per feature. A feature with no row here was",
                      "never scored, which is different from being scored low.")),
              div(class = "table-tools",
                downloadButton(ns("dl_dnn"), "CSV", class = "btn-soft btn-sm")),
              DTOutput(ns("dnn_pred_table"))
            ),
            card_panel("Model input (what was actually scored)", "image",
              p(class = "text-muted",
                paste("This is the matrix written to disk and handed to the",
                      "network: rows are retention-time slices, columns are",
                      "samples, and the LAST column is the window marker. It is",
                      "deliberately not the same picture as the diagnostic",
                      "image in the Peak group tab, because the model was",
                      "trained on the transposed layout. If the marker ever",
                      "appears as a row instead of a column, the input is",
                      "wrong and the run is refused rather than scored.")),
              uiOutput(ns("dnn_image_ui"))
            ),
            card_panel("Input checks", "check-double",
              p(class = "text-muted",
                paste("Shape, marker axis, marker content, value range and",
                      "signal are checked before prediction. A failed check",
                      "stops the run: a transposed image does not make the",
                      "model complain, it makes it return a confident-looking",
                      "low score.")),
              DTOutput(ns("dnn_check_table"))
            )
          ),

          tabPanel("Three methods", icon = icon("table-columns"),
            br(),
            card_panel("How to read this page", "circle-info",
              p(class = "text-muted",
                paste("Three methods, three questions, three units of",
                      "analysis. The DNN answers 'is this whole peak group",
                      "real?' once per feature (scope = peak_group). CPC and",
                      "Kumler answer shape questions per sample",
                      "(scope = single_sample). The numbers are placed side by",
                      "side for reading; they are not summed, weighted, ranked",
                      "or turned into a total. A CPC or Kumler value never",
                      "changes the DNN verdict, and the DNN verdict never",
                      "changes a quality class.")),
              p(class = "text-muted",
                paste("Kumler peak_cor is a correlation, not a probability.",
                      "CPC area is intensity x scan count (the author",
                      "integrates over scan indices), so it must not be",
                      "compared across scan rates. DNN score is an",
                      "uncalibrated model output."))
            ),
            card_panel("GroupResults - one row per feature", "layer-group",
              p(class = "text-muted",
                paste("The DNN's unit of analysis. n_present / n_absent /",
                      "n_unknown count the samples of the group; 'unknown'",
                      "means the sample could not be judged, and it is not",
                      "folded into either of the other two.")),
              div(class = "table-tools",
                downloadButton(ns("dl_groups"), "CSV", class = "btn-soft btn-sm")),
              DTOutput(ns("group_results_table"))
            ),
            card_panel("SampleResults - one row per feature and sample", "table",
              p(class = "text-muted",
                paste("Where CPC and Kumler operate. dnn_score appears here",
                      "only as a reference repeated across the group, and",
                      "dnn_scope says so; it is not a per-sample",
                      "measurement. method_errors names the method that",
                      "reported the problem.")),
              div(class = "table-tools",
                downloadButton(ns("dl_samples"), "CSV", class = "btn-soft btn-sm")),
              DTOutput(ns("sample_results_table"))
            ),
            card_panel("Side by side (reading aid, not a total)", "scale-balanced",
              p(class = "text-muted",
                paste("One summary number per method per feature: a median over",
                      "the samples that actually produced a value, plus how",
                      "many did. Read the count first - a median over two",
                      "samples and a median over twenty are not the same",
                      "evidence.")),
              DTOutput(ns("three_method_table"))
            )
          ),

          tabPanel("Inputs & mapping", icon = icon("diagram-project"),
            br(),
            card_panel("Peak table preview", "table-list", DTOutput(ns("peak_preview"))),
            card_panel("Sample to file matching", "link", DTOutput(ns("sample_match_table"))),
            card_panel("Rows rejected by validation", "triangle-exclamation",
                       DTOutput(ns("bad_rows_table")))
          ),

          tabPanel("Parameters & provenance", icon = icon("code-branch"),
            br(),
            card_panel("Parameters used for this run", "sliders",
                       tableOutput(ns("params_table"))),
            card_panel("Scoring code provenance", "code",
                       verbatimTextOutput(ns("provenance"))),
            card_panel("Methods available in this session", "flask",
              p(class = "text-muted",
                paste("A method that is merely known is not a method that can",
                      "run. This table is the authority the UI uses.")),
              DTOutput(ns("methods_table"))
            ),
            card_panel("Reference fitting curve", "circle-info",
                       p(class = "text-muted",
                         paste("The upstream scoring function returns only SNR and",
                               "peak_cor; it does not expose the fitted beta curve.",
                               "The optional curve in the Peak view tab is a",
                               "display-only reconstruction from the same four",
                               "candidate skews and is never used for scoring.")))
          )
        )
      )
    )
  )
}

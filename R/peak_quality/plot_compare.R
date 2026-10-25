# ============================================================
# Peak Quality - plots for the cross-sample peak group
# ============================================================
# Two views, both read-only:
#   * the traces of every member of a group inside the shared RT window,
#   * the image matrix the published network would consume (rows = samples,
#     columns = RT bins, values normalised to the global maximum).
# Neither view implies that a classification was produced.
# ============================================================

# ------------------------------------------------------------
# Traces of all members
# ------------------------------------------------------------
pq_plot_group_traces <- function(group, max_traces = 60L) {
  if (is.null(group) || is.null(group$members) || length(group$members) == 0) {
    return(NULL)
  }
  if (!requireNamespace("plotly", quietly = TRUE)) return(NULL)

  members <- group$members
  sig <- vapply(members, function(m) identical(m$status, "signal"), logical(1))
  members <- members[sig]
  if (length(members) == 0) return(NULL)
  members <- utils::head(members, max_traces)

  p <- plotly::plot_ly()
  for (m in members) {
    p <- plotly::add_lines(
      p, x = m$rt, y = m$intensity, name = m$sample_id,
      line = list(width = 1.1),
      hovertemplate = paste0(m$sample_id,
                             "<br>RT %{x:.3f} min<br>Intensity %{y:.4g}<extra></extra>")
    )
  }

  win <- group$window
  shapes <- list()
  if (length(win) == 2 && all(is.finite(win))) {
    shapes <- list(
      list(type = "line", xref = "x", yref = "paper", x0 = win[1], x1 = win[1],
           y0 = 0, y1 = 1, line = list(color = "#0f766e", width = 1, dash = "dot")),
      list(type = "line", xref = "x", yref = "paper", x0 = win[2], x1 = win[2],
           y0 = 0, y1 = 1, line = list(color = "#0f766e", width = 1, dash = "dot"))
    )
  }

  plotly::layout(
    p,
    title = list(
      text = sprintf("<b>%s</b> | %d member(s) with signal in %.3f-%.3f min",
                     group$feature_id, length(members), win[1], win[2]),
      x = 0.01, xanchor = "left", font = list(size = 13)),
    xaxis = list(title = "Retention time (min)", zeroline = FALSE),
    yaxis = list(title = "Intensity", rangemode = "tozero"),
    shapes = shapes,
    margin = list(t = 50, b = 50, l = 70, r = 20),
    hovermode = "closest",
    legend = list(orientation = "v", x = 1.0, y = 1, font = list(size = 9))
  )
}

# ------------------------------------------------------------
# The image matrix
# ------------------------------------------------------------
pq_plot_group_image <- function(group) {
  if (is.null(group) || !isTRUE(group$ok) || is.null(group$image$matrix)) {
    return(NULL)
  }
  if (!requireNamespace("plotly", quietly = TRUE)) return(NULL)

  img <- group$image
  mat <- img$matrix
  labs <- img$samples
  labs[is.na(labs)] <- paste0("padding ", seq_len(sum(is.na(labs))))

  # explicit colour stops: plotly's `colors` argument needs an actual colour
  # vector or a palette function, not the name of a palette
  viridis5 <- c("#440154", "#3b528b", "#21918c", "#5ec962", "#fde725")

  # the mask row is shown separately so it is never mistaken for a sample
  plotly::layout(
    plotly::plot_ly(
      x = img$rt_slices, y = labs, z = mat,
      type = "heatmap", colors = viridis5, zmin = 0, zmax = 1,
      hovertemplate = "RT %{x:.3f} min<br>%{y}<br>normalised intensity %{z:.3f}<extra></extra>"
    ),
    title = list(
      text = sprintf("<b>%s</b> | peak-group image %d x %d (rows = samples, columns = RT bins)",
                     group$feature_id, nrow(mat), ncol(mat)),
      x = 0.01, xanchor = "left", font = list(size = 13)),
    xaxis = list(title = "Retention time (min)"),
    yaxis = list(title = "", autorange = "reversed", tickfont = list(size = 9)),
    margin = list(t = 50, b = 50, l = 140, r = 20)
  )
}

# Static fallback (used in the ZIP report).
pq_plot_group_image_base <- function(group) {
  if (is.null(group) || !isTRUE(group$ok) || is.null(group$image$matrix)) {
    return(invisible(NULL))
  }
  img <- group$image
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::par(mar = c(4, 8, 3, 1))
  graphics::image(
    x = img$rt_slices, y = seq_len(nrow(img$matrix)), z = t(img$matrix),
    col = grDevices::hcl.colors(50, "Viridis"),
    xlab = "Retention time (min)", ylab = "",
    main = sprintf("%s | peak-group image %d x %d", group$feature_id,
                   nrow(img$matrix), ncol(img$matrix)),
    axes = FALSE
  )
  graphics::axis(1)
  graphics::axis(2, at = seq_len(nrow(img$matrix)),
                 labels = img$samples, las = 1, cex.axis = 0.7)
  graphics::box()
  invisible(NULL)
}

# ------------------------------------------------------------
# Unified row view for one peak, both methods side by side
# ------------------------------------------------------------
# A compact table used in the "Compare methods" tab and the report: one row
# per method, no combined column.
pq_method_side_by_side <- function(row, cpc_row = NULL) {
  kv <- function(method, metric, value, unit, note) {
    data.frame(method = method, metric = metric, value = as.character(value),
               unit = unit, note = note, stringsAsFactors = FALSE)
  }
  out <- rbind(
    kv("kumler", "start_rt", fmt_num(row$start_rt, 4), "min", "detected boundary"),
    kv("kumler", "apex_rt", fmt_num(row$apex_rt, 4), "min", "closest candidate apex"),
    kv("kumler", "end_rt", fmt_num(row$end_rt, 4), "min", "detected boundary"),
    kv("kumler", "n_points", as.integer(row$n_points), "scans", ""),
    kv("kumler", "peak_cor", fmt_num(row$peak_cor, 4), "correlation",
       "not a probability"),
    kv("kumler", "SNR", fmt_num(row$SNR, 2), "ratio", "author metric")
  )
  if (!is.null(cpc_row) && "cpc_status" %in% names(cpc_row)) {
    ok <- identical(as.character(cpc_row$cpc_status[1]), "ok")
    out <- rbind(out,
      kv("cpc", "start_rt", fmt_num(cpc_row$cpc_rtmin[1], 4), "min",
         if (ok) paste("code", cpc_row$cpc_front_code[1]) else as.character(cpc_row$cpc_status[1])),
      kv("cpc", "apex_rt", fmt_num(cpc_row$cpc_rt[1], 4), "min", "CPC peak apex"),
      kv("cpc", "end_rt", fmt_num(cpc_row$cpc_rtmax[1], 4), "min",
         if (ok) paste("code", cpc_row$cpc_tail_code[1]) else as.character(cpc_row$cpc_status[1])),
      kv("cpc", "n_points", as.integer(cpc_row$cpc_n_points[1]), "scans", ""),
      kv("cpc", "height", fmt_num(cpc_row$cpc_height[1], 1), "intensity", ""),
      kv("cpc", "fwhm", fmt_num(cpc_row$cpc_fwhm[1], 4), "min", ""),
      kv("cpc", "tf", fmt_num(cpc_row$cpc_tf[1], 3), "ratio", "1.0 = symmetric"),
      kv("cpc", "area", fmt_num(cpc_row$cpc_area[1], 0), "intensity x scan count",
         "author value; do not compare across scan rates"),
      kv("cpc", "sn", fmt_num(cpc_row$cpc_sn[1], 2), "ratio",
         "author value; reported only, never filtered")
    )
  }
  out
}

# ------------------------------------------------------------
# The matrix the MODEL actually consumes
# ------------------------------------------------------------
# This is a different object from pq_plot_group_image(): that one shows the
# diagnostic image in the author's R layout (rows = samples, columns = RT).
# The model was trained on the transposed layout (rows = RT slices, columns =
# samples with the window marker in the LAST column), so a user looking at the
# diagnostic view cannot see what the network sees. Showing the scored matrix
# is what makes an "approximate input" claim checkable.
pq_plot_model_input_image <- function(mat, feature_id = NULL, meta = NULL) {
  if (is.null(mat) || is.null(dim(mat))) return(NULL)
  if (!requireNamespace("plotly", quietly = TRUE)) return(NULL)

  nr <- nrow(mat); nc <- ncol(mat)
  # The last column is the marker, not a sample; label it so it is never read
  # as one more sample.
  xlab <- c(sprintf("s%02d", seq_len(max(0, nc - 1L))), "marker")
  viridis5 <- c("#440154", "#3b528b", "#21918c", "#5ec962", "#fde725")

  subtitle <- if (!is.null(meta) && !is.null(meta$image_resampled) &&
                   isTRUE(meta$image_resampled)) {
    sprintf("converted from the native %s x %s to the model grid",
            meta$image_native_rows, meta$image_native_cols)
  } else {
    "native geometry"
  }

  plotly::layout(
    plotly::plot_ly(
      x = xlab, y = seq_len(nr), z = t(mat),
      type = "heatmap", colors = viridis5, zmin = 0, zmax = 1,
      hovertemplate = "column %{x}<br>RT slice %{y}<br>value %{z:.3f}<extra></extra>"
    ),
    title = list(
      text = sprintf("<b>%s</b> | matrix fed to the model: %d x %d (%s)",
                     if (is.null(feature_id)) "peak group" else feature_id,
                     nr, nc, subtitle),
      x = 0.01, xanchor = "left", font = list(size = 13)),
    xaxis = list(title = "sample index (last column = window marker)",
                 tickfont = list(size = 8), type = "category"),
    yaxis = list(title = "RT slice (index)", autorange = "reversed"),
    margin = list(t = 50, b = 60, l = 70, r = 20)
  )
}

# Static fallback for the ZIP report.
pq_plot_model_input_image_base <- function(mat, main = "model input") {
  if (is.null(mat) || is.null(dim(mat))) return(invisible(NULL))
  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)
  graphics::par(mar = c(4, 6, 3, 1))
  graphics::image(
    x = seq_len(ncol(mat)), y = seq_len(nrow(mat)), z = t(mat),
    col = grDevices::hcl.colors(50, "Viridis"),
    xlab = "column (last = marker)", ylab = "RT slice", main = main,
    axes = FALSE, zlim = c(0, 1)
  )
  graphics::axis(1, cex.axis = 0.6)
  graphics::axis(2)
  graphics::box()
  invisible(NULL)
}

fmt_num <- function(x, digits = 3) {
  if (is.null(x) || length(x) == 0 || all(is.na(x))) return("NA")
  format(round(as.numeric(x[1]), digits), big.mark = ",", trim = TRUE)
}

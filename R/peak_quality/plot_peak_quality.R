# ============================================================
# Peak Quality - plotting
# ============================================================
# The plot draws BOTH traces when XIC smoothing is enabled: the raw XIC in
# thin indigo, and the analysis trace that was actually scored in thick sky
# blue. With smoothing off (the default) only the raw trace is drawn, and it
# is exactly the vector handed to the scoring function. The older
# `smooth_points` overlay is an apex-search aid only and is suppressed while
# the analysis trace is already smoothed, to keep the plot readable.
#
# The beta fit / residuals shown when "show_fit" is on are a DISPLAY-ONLY
# reconstruction: the author function returns only SNR and peak_cor, not the
# fitted curve, so the curve is recomputed from the same 4 candidate skews
# and is explicitly labelled as such. It never feeds the reported scores.
# ============================================================

PQ_COL_RAW   <- "#4f46e5"
PQ_COL_APEX  <- "#dc2626"
PQ_COL_EDGE  <- "#0f766e"
PQ_COL_INPUT <- "#d97706"
PQ_COL_FIT   <- "#94a3b8"
PQ_COL_CPC   <- "#7c3aed"
PQ_COL_SMOOTH <- "#0ea5e9"   # analysis trace, always drawn thicker than raw

# Display-only reconstruction of the author's beta fit
pq_display_fit <- function(rt, int) {
  if (length(rt) < 5 || !is.finite(max(int)) || max(int) <= 0) return(NULL)
  scaled <- (rt - min(rt)) / (max(rt) - min(rt))
  maybe <- c(2.5, 3, 4, 5)
  cors <- vapply(maybe, function(s) suppressWarnings(cor(dbeta(scaled, s, 5), int)), numeric(1))
  if (all(is.na(cors))) return(NULL)
  skew <- maybe[which.max(cors)]
  fit <- dbeta(scaled, skew, 5)
  residuals <- int / max(int) - fit / max(fit)
  list(rt = rt, fit = fit, residuals = residuals, skew = skew,
       cor = suppressWarnings(cor(fit, int)))
}

pq_xic_frame <- function(entry, per_peak = TRUE) {
  xic <- pq_analysis_xic(entry)
  if (per_peak) {
    slice <- pq_peak_slice(xic, entry$peak)
  } else {
    slice <- xic
  }
  slice
}

# ------------------------------------------------------------
# Interactive plot (plotly when installed)
# ------------------------------------------------------------
pq_plot_peak_quality <- function(entry, row, show_fit = FALSE, smooth_points = 0,
                                 cpc_row = NULL) {
  if (is.null(entry) || is.null(entry$xic) || nrow(entry$xic) == 0) {
    return(NULL)
  }

  xic <- entry$xic                    # always the raw trace
  xa  <- pq_analysis_xic(entry)       # what the analysis actually used
  sm_on <- pq_smoothing_applied(entry)
  sm_label <- if (!is.null(entry$smoothing)) entry$smoothing$label else "none"
  sm_short <- if (!is.null(entry$smoothing$short)) entry$smoothing$short else sm_label
  peak <- entry$peak
  ymax <- max(c(xic$intensity, xa$intensity), na.rm = TRUE)

  if (!requireNamespace("plotly", quietly = TRUE)) {
    return(pq_plot_peak_base(entry, row, show_fit, smooth_points))
  }

  p <- plotly::plot_ly()

  # raw XIC
  p <- plotly::add_lines(
    p, x = xic$rt, y = xic$intensity, name = "XIC (raw)",
    line = list(color = PQ_COL_RAW, width = 1.6),
    hovertemplate = "RT %{x:.3f} min<br>Intensity %{y:.4g}<extra>raw XIC</extra>"
  )
  p <- plotly::add_markers(
    p, x = xic$rt, y = xic$intensity, name = "scans",
    marker = list(color = PQ_COL_RAW, size = 4),
    showlegend = FALSE, hoverinfo = "skip"
  )

  # smoothed analysis trace, drawn on top because it is the one that was scored
  if (isTRUE(sm_on)) {
    p <- plotly::add_lines(
      p, x = xa$rt, y = xa$intensity,
      name = sprintf("XIC analysis trace (%s)", sm_short),
      line = list(color = PQ_COL_SMOOTH, width = 2.4),
      hovertemplate = "RT %{x:.3f} min<br>Intensity %{y:.4g}<extra>smoothed</extra>"
    )
  }

  # detection-only smoothing: skipped when the analysis trace is already
  # smoothed, otherwise three overlapping lines make the plot unreadable
  if (!isTRUE(sm_on) && smooth_points >= 3 && nrow(xic) >= smooth_points) {
    sm <- pq_movavg(xic$intensity, as.integer(smooth_points))
    p <- plotly::add_lines(
      p, x = xic$rt, y = sm, name = "detection smoothing (apex search only)",
      line = list(color = PQ_COL_FIT, width = 1.2, dash = "dot"),
      hoverinfo = "skip"
    )
  }

  # peak region shading
  if (!is.na(peak$start_rt) && !is.na(peak$end_rt)) {
    p <- plotly::add_segments(
      p, x = peak$start_rt, xend = peak$end_rt, y = 0, yend = 0,
      name = "detected peak", line = list(color = PQ_COL_EDGE, width = 6),
      hoverinfo = "skip", showlegend = TRUE
    )
  }

  shapes <- list()
  ann <- list()

  vline <- function(x, color, dash) {
    list(type = "line", xref = "x", yref = "paper",
         x0 = x, x1 = x, y0 = 0, y1 = 1,
         line = list(color = color, width = 1.4, dash = dash))
  }

  if (!is.na(row$input_rt)) {
    shapes <- c(shapes, list(vline(row$input_rt, PQ_COL_INPUT, "dash")))
    ann <- c(ann, list(list(x = row$input_rt, y = 1.02, yref = "paper",
                            text = "peak table RT", showarrow = FALSE,
                            font = list(color = PQ_COL_INPUT, size = 11))))
  }
  if (!is.na(peak$apex_rt)) {
    shapes <- c(shapes, list(vline(peak$apex_rt, PQ_COL_APEX, "solid")))
    ann <- c(ann, list(list(x = peak$apex_rt, y = 0.94, yref = "paper",
                            text = "apex", showarrow = FALSE,
                            font = list(color = PQ_COL_APEX, size = 11))))
  }
  if (!is.na(peak$start_rt)) {
    shapes <- c(shapes, list(vline(peak$start_rt, PQ_COL_EDGE, "solid")))
  }
  if (!is.na(peak$end_rt)) {
    shapes <- c(shapes, list(vline(peak$end_rt, PQ_COL_EDGE, "solid")))
  }

  # CPC boundaries / apex, when that method was run for this row.
  # Drawn in a different colour AND a different dash so the two methods can
  # never be confused in a screenshot.
  if (!is.null(cpc_row) && "cpc_status" %in% names(cpc_row) &&
      identical(as.character(cpc_row$cpc_status[1]), "ok")) {
    for (v in c(cpc_row$cpc_rtmin[1], cpc_row$cpc_rtmax[1])) {
      if (!is.na(v)) shapes <- c(shapes, list(vline(v, PQ_COL_CPC, "dot")))
    }
    if (!is.na(cpc_row$cpc_rt[1])) {
      shapes <- c(shapes, list(vline(cpc_row$cpc_rt[1], PQ_COL_CPC, "dashdot")))
      ann <- c(ann, list(list(x = cpc_row$cpc_rt[1], y = 0.86, yref = "paper",
                              text = "CPC apex", showarrow = FALSE,
                              font = list(color = PQ_COL_CPC, size = 11))))
    }
  }

  # display-only beta fit, reconstructed from the SAME trace that was scored
  if (isTRUE(show_fit) && !is.na(peak$start_index)) {
    slice <- pq_peak_slice(xa, peak)
    fit <- pq_display_fit(slice$rt, slice$intensity)
    if (!is.null(fit)) {
      y_fit <- fit$fit * max(slice$intensity)
      p <- plotly::add_lines(
        p, x = fit$rt, y = y_fit,
        name = sprintf("beta fit reconstruction (display only, skew %s)", fit$skew),
        line = list(color = PQ_COL_APEX, width = 1.2, dash = "dashdot"),
        hoverinfo = "skip"
      )
    }
  }

  subtitle <- sprintf(
    "m/z tolerance %s &nbsp;|&nbsp; RT window +/-%s min &nbsp;|&nbsp; %d scans in window, %d inside the peak<br>peak_cor = %s &nbsp;|&nbsp; SNR = %s &nbsp;|&nbsp; boundary: %s",
    row$mz_tol, format(row$rt_window, trim = TRUE),
    as.integer(row$n_scans_in_window), as.integer(row$n_points),
    ifelse(is.na(row$peak_cor), "NA", format(round(row$peak_cor, 4))),
    ifelse(is.na(row$SNR), "NA", format(round(row$SNR, 2))),
    pq_status_label(row$boundary_status)
  )
  if (isTRUE(sm_on)) {
    subtitle <- paste0(
      subtitle, "<br>XIC smoothing: ", sm_label,
      " - boundaries and scores use the smoothed trace; presence and noise do not")
  }
  if (!is.null(cpc_row) && "cpc_status" %in% names(cpc_row) &&
      identical(as.character(cpc_row$cpc_status[1]), "ok")) {
    subtitle <- paste0(
      subtitle, "<br>CPC: ",
      sprintf("rt %.3f (%s..%s) min | FWHM %s | TF %s | height %s | area %s (index units) | sn %s",
              cpc_row$cpc_rt[1],
              format(round(cpc_row$cpc_rtmin[1], 3)),
              format(round(cpc_row$cpc_rtmax[1], 3)),
              format(round(cpc_row$cpc_fwhm[1], 4)),
              format(round(cpc_row$cpc_tf[1], 3)),
              format(round(cpc_row$cpc_height[1]), big.mark = ","),
              format(round(cpc_row$cpc_area[1]), big.mark = ","),
              format(round(cpc_row$cpc_sn[1], 2))),
      " | bounds ", cpc_row$cpc_front_code[1], "/", cpc_row$cpc_tail_code[1])
  }

  plotly::layout(
    p,
    title = list(
      text = sprintf("<b>%s</b> &nbsp;|&nbsp; %s", row$feature_id, row$sample_id),
      x = 0.01, xanchor = "left", font = list(size = 14)
    ),
    xaxis = list(title = list(text = "Retention time (min)", standoff = 8),
                 zeroline = FALSE),
    yaxis = list(title = "Intensity", rangemode = "tozero"),
    shapes = shapes,
    annotations = c(ann, list(list(
      x = 0, y = -0.42, xref = "paper", yref = "paper",
      text = subtitle, showarrow = FALSE, xanchor = "left", align = "left",
      font = list(size = 10, color = "#475569")
    ))),
    margin = list(t = 64, b = 140, l = 70, r = 20),
    hovermode = "closest",
    legend = list(orientation = "h", y = 1.12, x = 0)
  )
}

# ------------------------------------------------------------
# Residual plot (display-only fit reconstruction)
# ------------------------------------------------------------
pq_plot_residuals <- function(entry, row) {
  if (is.null(entry) || is.null(entry$peak) || is.na(entry$peak$start_index)) return(NULL)
  slice <- pq_peak_slice(pq_analysis_xic(entry), entry$peak)
  fit <- pq_display_fit(slice$rt, slice$intensity)
  if (is.null(fit)) return(NULL)

  if (!requireNamespace("plotly", quietly = TRUE)) return(NULL)

  plotly::layout(
    plotly::add_lines(
      plotly::plot_ly(), x = fit$rt, y = fit$residuals,
      name = "normalised residual",
      line = list(color = PQ_COL_EDGE, width = 1.4),
      hovertemplate = "RT %{x:.3f} min<br>residual %{y:.4g}<extra></extra>"
    ),
    title = list(text = "Residuals of the display-only fit (not used for scoring)",
                 x = 0.01, xanchor = "left", font = list(size = 12)),
    xaxis = list(title = "Retention time (min)"),
    yaxis = list(title = "int/max(int) - fit/max(fit)"),
    margin = list(t = 40, b = 50)
  )
}

# ------------------------------------------------------------
# Base R fallback (used when plotly is unavailable, e.g. export)
# ------------------------------------------------------------
pq_plot_peak_base <- function(entry, row, show_fit = FALSE, smooth_points = 0,
                              add_residuals = FALSE, cpc_row = NULL) {
  xic <- entry$xic
  xa <- pq_analysis_xic(entry)
  sm_on <- pq_smoothing_applied(entry)
  sm_short <- if (!is.null(entry$smoothing$short)) entry$smoothing$short else "smoothed"
  peak <- entry$peak

  op <- graphics::par(no.readonly = TRUE)
  on.exit(graphics::par(op), add = TRUE)

  if (add_residuals && isTRUE(show_fit)) {
    graphics::par(mfrow = c(2, 1), mar = c(3.6, 4.2, 2.4, 1))
  }

  graphics::plot(
    xic$rt, xic$intensity, type = "l", col = PQ_COL_RAW, lwd = 1.6,
    xlab = "Retention time (min)", ylab = "Intensity",
    main = sprintf("%s | %s  (peak_cor %s, SNR %s)", row$feature_id, row$sample_id,
                   ifelse(is.na(row$peak_cor), "NA", format(round(row$peak_cor, 4))),
                   ifelse(is.na(row$SNR), "NA", format(round(row$SNR, 2)))),
    ylim = c(0, max(c(xic$intensity, xa$intensity)) * 1.05)
  )
  graphics::points(xic$rt, xic$intensity, pch = 16, cex = 0.5, col = PQ_COL_RAW)

  if (isTRUE(sm_on)) {
    graphics::lines(xa$rt, xa$intensity, col = PQ_COL_SMOOTH, lwd = 2.4)
    graphics::mtext(sprintf("analysis trace: %s", sm_short),
                    side = 3, line = 0.1, cex = 0.7, col = PQ_COL_SMOOTH)
  } else if (smooth_points >= 3 && nrow(xic) >= smooth_points) {
    graphics::lines(xic$rt, pq_movavg(xic$intensity, as.integer(smooth_points)),
                    col = PQ_COL_FIT, lty = 3)
  }
  if (!is.na(row$input_rt)) {
    graphics::abline(v = row$input_rt, col = PQ_COL_INPUT, lty = 2, lwd = 1.4)
  }
  if (!is.na(peak$apex_rt)) {
    graphics::abline(v = peak$apex_rt, col = PQ_COL_APEX, lwd = 1.6)
  }
  if (!is.na(peak$start_rt)) {
    graphics::abline(v = peak$start_rt, col = PQ_COL_EDGE, lwd = 1.2)
  }
  if (!is.na(peak$end_rt)) {
    graphics::abline(v = peak$end_rt, col = PQ_COL_EDGE, lwd = 1.2)
  }
  if (!is.null(cpc_row) && all(c("cpc_status") %in% names(cpc_row)) &&
      identical(as.character(cpc_row$cpc_status[1]), "ok")) {
    for (v in c(cpc_row$cpc_rtmin[1], cpc_row$cpc_rt[1], cpc_row$cpc_rtmax[1])) {
      if (!is.na(v)) graphics::abline(v = v, col = PQ_COL_CPC, lty = 3, lwd = 1.1)
    }
  }
  leg_lab <- c("XIC (raw)", "peak table RT", "apex", "boundaries",
               if (isTRUE(sm_on)) "analysis trace (smoothed)",
               if (is.null(cpc_row)) NULL else "CPC bounds")
  leg_col <- c(PQ_COL_RAW, PQ_COL_INPUT, PQ_COL_APEX, PQ_COL_EDGE,
               if (isTRUE(sm_on)) PQ_COL_SMOOTH,
               if (is.null(cpc_row)) NULL else PQ_COL_CPC)
  leg_lty <- c(1, 2, 1, 1, if (isTRUE(sm_on)) 1,
               if (is.null(cpc_row)) NULL else 3)
  leg_lwd <- c(1.6, 1.4, 1.6, 1.2, if (isTRUE(sm_on)) 2.4,
               if (is.null(cpc_row)) NULL else 1.1)
  graphics::legend("topright", bty = "n", cex = 0.7,
                   legend = leg_lab, col = leg_col,
                   lty = leg_lty, lwd = leg_lwd)

  if (isTRUE(show_fit) && !is.na(peak$start_index)) {
    slice <- pq_peak_slice(xa, peak)
    fit <- pq_display_fit(slice$rt, slice$intensity)
    if (!is.null(fit)) {
      graphics::lines(fit$rt, fit$fit * max(slice$intensity),
                      col = PQ_COL_APEX, lty = 4, lwd = 1.2)
    }
    if (add_residuals) {
      graphics::plot(fit$rt, fit$residuals, type = "l", col = PQ_COL_EDGE,
                     xlab = "Retention time (min)", ylab = "residual",
                     main = "display-only fit residuals (not used for scoring)")
    }
  }
  invisible(NULL)
}

# ============================================================
# Peak Quality - run log on disk / job-size estimate / disconnect snapshot
# ============================================================
# Why this layer exists:
#   `append_log()` only pushes text into a reactiveVal. As soon as the browser
#   drops the websocket (which is exactly what the greyed-out page means) that
#   string can never be read again, and nothing is on disk either -- a 28-minute
#   run would leave no trace. So every log line is also written to a file: one
#   file per Shiny session (the module server opens it when the session starts),
#   with RUN START / RUN END delimiting each run.
# ============================================================

PQ_LOG_DIR <- file.path(".workbuddy", "logs", "peak_quality")
PQ_RUN_DIR <- file.path(".workbuddy", "runs")

# Logs from hundreds of runs on one machine must not pile up forever
PQ_LOG_KEEP_DAYS <- 14

pq_log_open <- function(dir = PQ_LOG_DIR, tag = "peak_quality") {
  ok <- dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  if (!dir.exists(dir)) return(NULL)
  path <- file.path(dir, sprintf("%s_%s_pid%d.log", tag,
                                 format(Sys.time(), "%Y%m%d_%H%M%S"),
                                 Sys.getpid()))
  pq_log_write(path, "INFO", sprintf(
    "log opened | R %s.%s | pid %d", R.version$major, R.version$minor,
    Sys.getpid()))
  pq_log_prune(dir, keep_days = PQ_LOG_KEEP_DAYS)
  path
}

pq_log_write <- function(path, level = "INFO", msg) {
  if (is.null(path) || !nzchar(path)) return(invisible(NULL))
  line <- sprintf("[%s] %-5s %s\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                  level, paste(msg, collapse = " "))
  try(cat(line, file = path, append = TRUE), silent = TRUE)
  invisible(NULL)
}

pq_log_prune <- function(dir, keep_days = PQ_LOG_KEEP_DAYS) {
  f <- list.files(dir, pattern = "[.]log$", full.names = TRUE)
  if (length(f) == 0) return(invisible(NULL))
  age <- (as.numeric(Sys.time()) - as.numeric(file.info(f)$mtime)) / 86400
  old <- f[!is.na(age) & age > keep_days]
  if (length(old) > 0) invisible(file.remove(old))
  invisible(NULL)
}

# ------------------------------------------------------------
# Job size / duration estimate
# ------------------------------------------------------------
# Measured calibration (2026-10-22, P173.raw 54 MB, 10 ppm, 0.3 min half-window):
#   * read_ms_file() reads one .raw and builds the MS1 index: ~34 s warm, ~55 s cold
#   * one row (XIC -> bounds -> presence -> author score): ~9 ms
# Trustworthy only as an order of magnitude; its purpose is to stop a 69,000-row
# job from looking like a two-minute chore.
PQ_EST_ROW_MS <- 9
PQ_EST_FILE_S <- 40
PQ_LONG_JOB_S <- 600      # beyond this the warning is explicit

pq_estimate_job <- function(n_rows, n_files,
                            row_ms = PQ_EST_ROW_MS, file_s = PQ_EST_FILE_S) {
  n_rows <- as.numeric(n_rows); n_files <- as.numeric(n_files)
  read_s <- n_files * file_s
  row_s  <- n_rows * row_ms / 1000
  list(n_rows = n_rows, n_files = n_files,
       read_s = read_s, row_s = row_s, total_s = read_s + row_s,
       label = pq_format_duration(read_s + row_s),
       long = (read_s + row_s) > PQ_LONG_JOB_S)
}

pq_format_duration <- function(sec) {
  if (is.null(sec) || !is.finite(sec)) return("unknown")
  if (sec < 90) return(sprintf("%.0f s", sec))
  if (sec < 5400) return(sprintf("%.0f min", sec / 60))
  sprintf("%.1f h", sec / 3600)
}

# ------------------------------------------------------------
# Write results to disk on disconnect or page close
# ------------------------------------------------------------
# Auto-save only for large jobs: dumping a pile of CSV from a small demo run is pointless.
PQ_AUTOSAVE_MIN_ROWS <- 2000L
PQ_RUN_KEEP <- 3L
# `detail` is what makes a big run heavy: 1.3 GB for 69000 rows, because every
# row keeps its XIC and its candidate table. Writing that at session end would
# take minutes and fill the disk, so it is only kept when it is small.
PQ_SNAPSHOT_DETAIL_MAX <- 200 * 1024^2

pq_save_run <- function(rows, detail = NULL, meta = list(),
                        dir = PQ_RUN_DIR, stamp = NULL,
                        detail_max = PQ_SNAPSHOT_DETAIL_MAX) {
  if (is.null(rows) || !is.data.frame(rows) || nrow(rows) == 0) return(NULL)
  ok <- dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  if (!dir.exists(dir)) return(NULL)
  if (is.null(stamp)) stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  out <- file.path(dir, stamp)
  dir.create(out, showWarnings = FALSE, recursive = TRUE)

  if (!is.null(detail) &&
      as.numeric(utils::object.size(detail)) > detail_max) {
    meta$detail_dropped <- TRUE
    meta$detail_mb <- round(as.numeric(utils::object.size(detail)) / 1024^2, 1)
    detail <- NULL
  }

  csv <- file.path(out, "peak_quality_rows.csv")
  try(utils::write.csv(rows, csv, row.names = FALSE, fileEncoding = "UTF-8"),
      silent = TRUE)
  try(saveRDS(list(rows = rows, detail = detail, meta = meta),
              file.path(out, "peak_quality_result.rds")), silent = TRUE)
  pq_run_prune(dir, keep = PQ_RUN_KEEP)
  out
}

pq_run_prune <- function(dir, keep = PQ_RUN_KEEP) {
  d <- list.files(dir, full.names = TRUE, include.dirs = TRUE)
  d <- d[dir.exists(d)]
  if (length(d) <= keep) return(invisible(NULL))
  info <- file.info(d)
  d <- d[order(info$mtime, decreasing = TRUE)]
  old <- d[seq.int(keep + 1L, length(d))]
  unlink(old, recursive = TRUE, force = TRUE)
  invisible(NULL)
}

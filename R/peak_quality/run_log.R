# ============================================================
# Peak Quality - 运行日志落盘 / 任务规模预估 / 断线快照
# ============================================================
# 为什么有这一层：
#   `append_log()` 只是把文本塞进一个 reactiveVal。浏览器一旦丢掉
#   websocket（页面整片变灰就是这件事），那个字符串就再也读不到了，
#   磁盘上也没有任何记录 —— 一次 28 分钟的运行等于没跑过。
#   所以每一行日志同时写一份到文件；一个 Shiny 会话一个文件
#   （模块 server 每次建会话时打开），用 RUN START / RUN END 切分每次运行。
# ============================================================

PQ_LOG_DIR <- file.path(".workbuddy", "logs", "peak_quality")
PQ_RUN_DIR <- file.path(".workbuddy", "runs")

# 一台机器上百次运行后的日志不该无限堆积
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
# 任务规模 / 时长预估
# ------------------------------------------------------------
# 实测标定（2026-10-22，P173.raw 54 MB，10 ppm，0.3 min 半窗）：
#   * read_ms_file() 读一个 .raw 并建 MS1 索引：热态 ~34 s，冷态 ~55 s
#   * 一行（XIC -> 边界 -> presence -> 作者打分）：~9 ms
# 只在同一个数量级上可信；它的用途是让 69000 行别看起来像 2 分钟的小活。
PQ_EST_ROW_MS <- 9
PQ_EST_FILE_S <- 40
PQ_LONG_JOB_S <- 600      # 超过这个就明确警告

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
# 断线/关闭页面时把结果写到磁盘
# ------------------------------------------------------------
# 只在大任务上自动落盘：小演示跑一次就写一堆 CSV 没有意义。
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

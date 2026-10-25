# ============================================================
# test_19 - 运行日志落盘 / 时长预估 / 断线快照
# ============================================================
# 这一组锁的是 2026-10-22 那次「跑久了整个页面变灰」暴露出的三个缺口：
#   * 日志只在 reactiveVal 里，浏览器一断就什么都不剩 -> 必须同时写磁盘
#   * 69000 行看起来像两分钟的小活 -> 运行前必须给出量级预估
#   * 断线/关页面后结果只在内存里 -> 大任务必须在会话结束时落盘
# 不锁具体文案，只锁「有这个行为」。
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))
pq_source_project()

tmp <- file.path(tempdir(), paste0("pq_log_test_", Sys.getpid()))
dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
on.exit(unlink(tmp, recursive = TRUE, force = TRUE), add = TRUE)

pq_section("job size estimate")

e_big <- pq_estimate_job(69000, 20)
pq_assert_true(e_big$total_s > 1200,
               "69000 rows / 20 files is estimated at more than 20 minutes")
pq_assert_true(isTRUE(e_big$long), "that job is flagged as long")
pq_assert_equal(round(e_big$total_s), round(e_big$read_s + e_big$row_s),
                "total is read + row time")
pq_assert_true(grepl("min|h", e_big$label), "label is human readable")

e_small <- pq_estimate_job(160, 2)
pq_assert_true(!isTRUE(e_small$long), "160 rows in 2 files is not flagged as long")
pq_assert_true(e_small$total_s < e_big$total_s, "smaller job, smaller estimate")
# a 20-file cohort is long even with few rows: the reading alone is ~13 min
pq_assert_true(isTRUE(pq_estimate_job(160, 20)$long),
               "20 files alone already count as a long job")

pq_assert_equal(pq_format_duration(45), "45 s", "seconds below 90 s")
pq_assert_equal(pq_format_duration(600), "10 min", "minutes between 90 s and 1.5 h")
pq_assert_equal(pq_format_duration(7200), "2.0 h", "hours above 1.5 h")

pq_section("log file")

p <- file.path(tmp, "run.log")
pq_log_write(p, "INFO", "first line")
pq_log_write(p, "WARN", "second line")
pq_assert_true(file.exists(p), "log file is created on first write")
lines <- readLines(p, warn = FALSE)
pq_assert_equal(length(lines), 2L, "two writes -> two lines")
pq_assert_contains(lines[1], "first line", "message is stored")
# pq_assert_contains() is fixed-string; check the timestamp shape separately
pq_assert_true(grepl("^\\[\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\] INFO", lines[1]),
               "line carries a full timestamp and level")
pq_assert_contains(lines[2], "WARN", "level is stored")
pq_assert_true(is.null(pq_log_write(NULL, "INFO", "x")),
               "a NULL path is a no-op, never an error")

pq_section("result snapshot")

rows <- data.frame(feature_id = sprintf("F%05d", 1:2500),
                   sample_id = "P173", mz = 300, input_rt = 5,
                   stringsAsFactors = FALSE)
out <- pq_save_run(rows, detail = NULL, meta = list(note = "test"),
                   dir = file.path(tmp, "runs"), stamp = "20261022_120000")
pq_assert_true(!is.null(out) && dir.exists(out), "snapshot directory is created")
pq_assert_true(file.exists(file.path(out, "peak_quality_rows.csv")),
               "rows are written as CSV")
pq_assert_true(file.exists(file.path(out, "peak_quality_result.rds")),
               "rows + detail are written as RDS")
back <- readRDS(file.path(out, "peak_quality_result.rds"))
pq_assert_equal(nrow(back$rows), 2500L, "RDS round-trips every row")
pq_assert_equal(back$meta$note, "test", "meta travels with the snapshot")
csv <- utils::read.csv(file.path(out, "peak_quality_rows.csv"),
                       stringsAsFactors = FALSE)
pq_assert_equal(nrow(csv), 2500L, "CSV round-trips every row")

pq_assert_true(is.null(pq_save_run(NULL, dir = tmp)), "no rows, no snapshot")
pq_assert_true(is.null(pq_save_run(rows[0, , drop = FALSE], dir = tmp)),
               "an empty table is not worth a snapshot")

# detail is the heavy part of a big run: it must be dropped, not written
big_detail <- rep(list(seq_len(20000)), 20)     # ~3 MB
out2 <- pq_save_run(rows, detail = big_detail, meta = list(),
                    dir = file.path(tmp, "runs_big"), stamp = "20261022_130000",
                    detail_max = 1024 * 1024)
back2 <- readRDS(file.path(out2, "peak_quality_result.rds"))
pq_assert_true(is.null(back2$detail), "an oversized detail list is not written")
pq_assert_true(isTRUE(back2$meta$detail_dropped), "the snapshot says detail was dropped")
pq_assert_true(!is.null(back2$meta$detail_mb), "the size that was dropped is recorded")
pq_assert_equal(nrow(back2$rows), 2500L, "rows are still complete without detail")

pq_section("snapshot rotation")

for (i in 1:6) {
  Sys.sleep(0.01)
  pq_save_run(rows, dir = file.path(tmp, "runs2"), stamp = sprintf("20261022_12000%d", i))
}
kept <- list.files(file.path(tmp, "runs2"))
pq_assert_equal(length(kept), PQ_RUN_KEEP, "only the last few snapshots are kept")

pq_section("server wiring (static)")

srv <- readLines(file.path(pq_proj_root(), "R/peak_quality/peak_quality_server.R"),
                 warn = FALSE, encoding = "UTF-8")
txt <- paste(srv, collapse = "\n")
pq_assert_true(grepl("session$onSessionEnded", txt, fixed = TRUE),
               "the server registers an onSessionEnded handler")
pq_assert_true(grepl("pq_save_run", txt, fixed = TRUE),
               "the handler writes the result snapshot")
pq_assert_true(grepl("pq_log_write(log_path", txt, fixed = TRUE),
               "every log line is mirrored to disk")
pq_assert_true(grepl("pq_estimate_job", txt, fixed = TRUE),
               "the run handler estimates the job before starting")
pq_assert_true(grepl('level = "RUN"', txt, fixed = TRUE),
               "runs are delimited in the log")
pq_assert_true(PQ_DISPLAY_ROWS <= 5000L,
               "the browser table cap stays at a size a tab can actually hold")

# ------------------------------------------------------------
# The module must survive being started for real.
# Reading a reactiveVal at init time (log_text() outside a reactive context)
# aborts the whole session and looks exactly like the grey page this file is
# about, so it is worth one real session rather than a static grep.
# ------------------------------------------------------------
pq_section("module starts inside a real session")

suppressMessages({
  library(shiny); library(DT); library(plotly); library(openxlsx)
})
source(file.path(pq_proj_root(), "R/peak_quality/peak_quality_ui.R"), encoding = "UTF-8")
source(file.path(pq_proj_root(), "R/peak_quality/peak_quality_server.R"), encoding = "UTF-8")

started <- tryCatch({
  shiny::testServer(peak_quality_server, args = list(id = "pq"), {
    pq_assert_contains(log_text(), "Run log:", "the session starts and names its log file")
    pq_assert_true(!is.null(output$method_choices_ui),
                   "the method panel renders in a real session")
    pq_assert_true(!is.null(output$method_status_ui),
                   "the method status panel renders in a real session")
  })
  TRUE
}, error = function(e) {
  pq_fail(paste("the module did not start:", conditionMessage(e)))
  FALSE
})
pq_assert_true(started, "peak_quality_server() starts without an R error")

pq_summary()

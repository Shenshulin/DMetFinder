# ============================================================
# cli/lib/progress.R -- 长任务进度回写与 job 查询
# ------------------------------------------------------------
# msg-extract / msg-match / rt-apex 要读谱图，几十个文件跑几十分钟。
# agent 侧的同步调用一定会超时，所以这些命令必须在运行过程中把状态落到
# 盘上，由另一个进程（job status）读取。
#
# 落盘位置：<out>/progress.json（原子写，随时可读，不会读到半个 JSON）
# 追加流水：<out>/progress.log（一行一次关键状态，事后可复盘）
#
# 约定 state 取值：running / done / failed。job 的退出码由 state 推导，
# 与信封同一原则——盘上的事实优先于进程状态。
# ============================================================

PROG_STATE <- c(running = "running", done = "done", failed = "failed")

#' 创建进度写入器
#'
#' @param out_dir  输出目录（与信封同一目录）
#' @param command  子命令名，仅用于 job status 展示
#' @param total    总步数（样品数/行数分块数），未知传 NA
#' @param quiet    静默时不打控制台，但仍然落盘
prog_new <- function(out_dir, command, total = NA_integer_, quiet = FALSE,
                     min_interval = 1.0) {
  st <- new.env(parent = emptyenv())
  st$out_dir  <- out_dir
  st$command  <- command
  st$total    <- total
  st$quiet    <- isTRUE(quiet)
  st$interval <- min_interval
  st$t0       <- Sys.time()
  st$last_t   <- NULL
  st$last_pct <- -1L
  st$state    <- "running"
  st$percent  <- 0L
  st$phase    <- "start"
  st$detail   <- ""
  st$done     <- 0L

  util_ensure_dir(out_dir)

  st$write <- function(force = FALSE) {
    now <- Sys.time()
    if (!isTRUE(force)) {
      elapsed <- as.numeric(difftime(now, st$last_t, units = "secs"))
      if (!is.null(st$last_t) && elapsed < st$interval &&
          identical(st$percent, st$last_pct)) {
        return(invisible(NULL))
      }
    }
    st$last_t   <- now
    st$last_pct <- st$percent

    obj <- list(
      command    = st$command,
      state      = st$state,
      percent    = as.integer(st$percent),
      phase      = st$phase,
      detail     = st$detail,
      done       = as.integer(st$done),
      total      = if (is.na(st$total)) NULL else as.integer(st$total),
      started_at = format(st$t0, "%Y-%m-%dT%H:%M:%S%z"),
      updated_at = format(now, "%Y-%m-%dT%H:%M:%S%z"),
      elapsed_s  = round(as.numeric(difftime(now, st$t0, units = "secs")), 1),
      pid        = Sys.getpid()
    )
    txt <- tryCatch(
      as.character(jsonlite::toJSON(obj, auto_unbox = TRUE, null = "null",
                                    na = "null", digits = NA)),
      error = function(e) NULL
    )
    if (is.null(txt)) return(invisible(NULL))
    try(util_atomic_write(file.path(st$out_dir, "progress.json"), txt),
        silent = TRUE)
    invisible(NULL)
  }

  st$set <- function(frac = NULL, detail = NULL, phase = NULL, done = NULL) {
    if (!is.null(frac)) st$percent <- max(0L, min(100L, as.integer(round(frac * 100))))
    if (!is.null(phase)) st$phase <- as.character(phase)
    if (!is.null(done)) st$done <- as.integer(done)
    if (!is.null(detail)) {
      st$detail <- as.character(detail)
      if (!st$quiet) {
        cat(sprintf("\r[%3d%%] %-56s", st$percent, substr(st$detail, 1, 56)),
            file = stderr())
        utils::flush.console()
      }
    }
    st$write()
    invisible(NULL)
  }

  st$log <- function(line) {
    try(cat(sprintf("%s %s\n", format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), line),
            file = file.path(st$out_dir, "progress.log"), append = TRUE,
            sep = ""), silent = TRUE)
    invisible(NULL)
  }

  st$finish <- function(state = "done", detail = NULL) {
    st$state  <- state
    if (!is.na(st$total) && identical(state, "done")) st$done <- st$total
    st$percent <- if (identical(state, "done")) 100L else st$percent
    if (!is.null(detail)) st$detail <- as.character(detail)
    if (!st$quiet && identical(state, "done")) cat("\n", file = stderr())
    st$write(force = TRUE)
    st$log(sprintf("state=%s percent=%d", state, st$percent))
    invisible(NULL)
  }

  st$write(force = TRUE)
  st$log(sprintf("state=running command=%s total=%s", command,
                 if (is.na(total)) "?" else as.character(total)))
  st
}

#' 读取 <out>/progress.json；不存在返回 NULL
prog_read <- function(out_dir) {
  p <- file.path(out_dir, "progress.json")
  if (!file.exists(p)) return(NULL)
  tryCatch(
    jsonlite::fromJSON(p, simplifyVector = TRUE),
    error = function(e) NULL
  )
}

#' job status：优先看 progress.json；没有它才看 run.json（已完成的老作业）
job_snapshot <- function(out_dir) {
  pr <- prog_read(out_dir)
  rj_path <- file.path(out_dir, "run.json")
  rj <- if (file.exists(rj_path)) {
    tryCatch(jsonlite::fromJSON(rj_path, simplifyVector = TRUE),
             error = function(e) NULL)
  } else NULL

  if (is.null(pr)) {
    if (is.null(rj)) {
      return(list(found = FALSE))
    }
    return(list(
      found = TRUE, state = if (isTRUE(rj$ok)) "done" else "failed",
      percent = if (isTRUE(rj$ok)) 100L else NA_integer_,
      phase = "finished", detail = "",
      elapsed_s = rj$duration_s, done = NA_integer_, total = NA_integer_,
      updated_at = rj$started_at,
      has_run_json = TRUE
    ))
  }

  list(
    found = TRUE,
    state = as.character(pr$state),
    percent = as.integer(pr$percent),
    phase = as.character(pr$phase),
    detail = if (is.null(pr$detail)) "" else as.character(pr$detail),
    elapsed_s = as.numeric(pr$elapsed_s),
    done = if (is.null(pr$done)) NA_integer_ else as.integer(pr$done),
    total = if (is.null(pr$total)) NA_integer_ else as.integer(pr$total),
    updated_at = as.character(pr$updated_at),
    has_run_json = !is.null(rj)
  )
}

#' job wait：轮询到非 running，或超时
job_wait <- function(out_dir, timeout_s = 1800, interval_s = 2,
                     quiet = FALSE) {
  t0 <- Sys.time()
  last_pct <- -1L
  repeat {
    snap <- job_snapshot(out_dir)
    if (!isTRUE(snap$found)) {
      return(list(snap = snap, timed_out = FALSE))
    }
    if (!identical(snap$state, "running")) {
      return(list(snap = snap, timed_out = FALSE))
    }
    if (!isTRUE(quiet) && !is.na(snap$percent) && !identical(snap$percent, last_pct)) {
      last_pct <- snap$percent
      cat(sprintf("\r[%3d%%] %-56s", snap$percent,
                  substr(paste(snap$phase, snap$detail), 1, 56)), file = stderr())
      utils::flush.console()
    }
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) >= timeout_s) {
      return(list(snap = snap, timed_out = TRUE))
    }
    Sys.sleep(interval_s)
  }
}

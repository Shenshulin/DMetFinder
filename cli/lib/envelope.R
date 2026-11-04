# ============================================================
# cli/lib/envelope.R -- 统一返回信封与退出码
# ------------------------------------------------------------
# 每个命令都产出同一个信封结构，写入 <out>/run.json 并在 --json 时
# 打到 stdout。字段只增不改，保证合作者脚本长期可用。
# ============================================================

DMF_EXIT <- list(
  ok          = 0L,
  usage       = 1L,   # 参数错误
  input       = 2L,   # 输入文件/格式错误
  runtime     = 3L,   # 运行期异常
  warn        = 4L    # 成功但有警告
)

env_new <- function(command, version, commit = NA_character_) {
  e <- new.env(parent = emptyenv())
  e$command    <- command
  e$version    <- version
  e$git_commit <- commit
  e$started_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  e$t0         <- Sys.time()
  e$ok         <- TRUE
  e$params     <- list()
  e$params_hash <- NA_character_
  e$inputs     <- list()
  e$outputs    <- list()
  e$warnings   <- list()
  e$metrics    <- list()
  e$extra      <- list()
  e$error      <- NULL
  e
}

env_set_params <- function(e, params) {
  e$params <- params
  txt <- tryCatch(
    jsonlite::toJSON(params, auto_unbox = TRUE, null = "null", na = "null", digits = NA),
    error = function(err) NULL
  )
  if (!is.null(txt)) {
    e$params_hash <- paste0("sha256:", digest::digest(charToRaw(enc2utf8(as.character(txt))),
                                                     algo = "sha256"))
  }
  invisible(e)
}

#' @param hash 是否计算 sha256。对几 GB 的谱图文件，哈希是唯一的耗时项
#'   （约 0.5 GB/s）；默认开启以保证可复现，--no-input-hash 可关掉。
env_add_input <- function(e, role, path, hash = TRUE) {
  path <- util_norm_path(path)
  e$inputs[[length(e$inputs) + 1L]] <- list(
    role   = role,
    path   = if (is.na(path)) NA_character_ else path,
    exists = !is.na(path) && file.exists(path),
    bytes  = util_file_size(path),
    sha256 = if (isTRUE(hash)) util_sha256(path) else NA_character_
  )
  invisible(e)
}

env_add_output <- function(e, role, path, sheet = NULL, rows = NULL, cols = NULL) {
  path <- util_norm_path(path)
  e$outputs[[length(e$outputs) + 1L]] <- list(
    role   = role,
    sheet  = if (is.null(sheet)) NA_character_ else sheet,
    path   = if (is.na(path)) NA_character_ else path,
    rows   = if (is.null(rows)) NA_integer_ else as.integer(rows),
    cols   = if (is.null(cols)) NA_integer_ else as.integer(cols),
    bytes  = util_file_size(path),
    sha256 = util_sha256(path)
  )
  invisible(e)
}

env_add_warning <- function(e, code, message, n = 1L) {
  e$warnings[[length(e$warnings) + 1L]] <- list(
    code    = code,
    message = as.character(message),
    count   = as.integer(n)
  )
  invisible(e)
}

env_add_metric <- function(e, name, value) {
  e$metrics[[name]] <- value
  invisible(e)
}

env_set_extra <- function(e, name, value) {
  e$extra[[name]] <- value
  invisible(e)
}

env_set_error <- function(e, code, message, hint = NULL) {
  e$ok <- FALSE
  e$error <- list(
    code    = code,
    message = as.character(message),
    hint    = if (is.null(hint)) NA_character_ else as.character(hint)
  )
  invisible(e)
}

env_has_errors <- function(e) length(e$warnings) > 0L && !e$ok

env_status <- function(e) {
  if (!isTRUE(e$ok)) return("failed")
  if (length(e$warnings) > 0L) return("ok_with_warnings")
  "ok"
}

env_exit_code <- function(e) {
  if (!isTRUE(e$ok)) {
    code <- if (!is.null(e$error)) e$error$code else "runtime"
    return(switch(code,
      usage   = DMF_EXIT$usage,
      input   = DMF_EXIT$input,
      runtime = DMF_EXIT$runtime,
      DMF_EXIT$runtime))
  }
  if (length(e$warnings) > 0L) return(DMF_EXIT$warn)
  DMF_EXIT$ok
}

env_to_list <- function(e) {
  duration <- as.numeric(difftime(Sys.time(), e$t0, units = "secs"))
  c(
    list(
      ok          = isTRUE(e$ok),
      command     = e$command,
      status      = env_status(e),
      version     = e$version,
      git_commit  = e$git_commit,
      started_at  = e$started_at,
      duration_s  = round(duration, 3L),
      params_hash = e$params_hash,
      params      = e$params,
      inputs      = e$inputs,
      outputs     = e$outputs,
      warnings    = e$warnings,
      metrics     = e$metrics
    ),
    if (!is.null(e$error)) list(error = e$error) else list(),
    e$extra
  )
}

env_json <- function(e) {
  x <- env_to_list(e)
  jsonlite::toJSON(x, auto_unbox = TRUE, pretty = TRUE,
                   null = "null", na = "null", digits = NA)
}

env_write <- function(e, dir) {
  util_ensure_dir(dir)
  path <- file.path(dir, "run.json")
  util_atomic_write(path, as.character(env_json(e)))
  invisible(path)
}

#' 人读摘要（不加 --json 时打到 stdout）
env_render <- function(e) {
  x <- env_to_list(e)
  out <- c(
    sprintf("命令      %s", x$command),
    sprintf("状态      %s", x$status),
    sprintf("版本      %s%s", x$version,
            if (is.na(x$git_commit)) "" else paste0(" (", x$git_commit, ")")),
    sprintf("耗时      %.1f s", x$duration_s)
  )
  if (length(x$outputs) > 0L) {
    out <- c(out, sprintf("输出      %d 个文件", length(x$outputs)))
    for (o in x$outputs) {
      out <- c(out, sprintf("          %s", basename(o$path)))
    }
  }
  if (length(x$warnings) > 0L) {
    out <- c(out, sprintf("警告      %d 条", length(x$warnings)))
    for (w in x$warnings) {
      out <- c(out, sprintf("  [%s] %s%s", w$code, w$message,
                            if (is.na(w$count)) "" else sprintf(" (n=%d)", w$count)))
    }
  }
  if (!is.null(x$error)) {
    out <- c(out, sprintf("错误      [%s] %s", x$error$code, x$error$message))
    if (!is.na(x$error$hint)) out <- c(out, sprintf("提示      %s", x$error$hint))
  }
  paste(out, collapse = "\n")
}

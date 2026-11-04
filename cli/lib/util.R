# ============================================================
# cli/lib/util.R -- 路径、哈希、编码、原子写
# ------------------------------------------------------------
# 只放无副作用的工具函数，不依赖 DMetFinder 的任何分析代码。
# ============================================================

#' 取当前脚本路径（Rscript 调用时由 --file= 传入）
util_script_path <- function() {
  a <- commandArgs(trailingOnly = FALSE)
  f <- grep("^--file=", a, value = TRUE)
  if (length(f) == 0L) return(NA_character_)
  sub("^--file=", "", f[[1L]])
}

#' 项目根目录 = cli/ 的上一级
util_project_root <- function() {
  p <- util_script_path()
  if (is.na(p)) stop("无法确定脚本路径（请用 Rscript 运行 cli/dmf.R）", call. = FALSE)
  normalizePath(file.path(dirname(p), ".."), winslash = "/", mustWork = TRUE)
}

#' 统一成正斜杠的绝对路径；不存在的输出目录按父目录规范化
util_norm_path <- function(p) {
  if (is.null(p) || length(p) == 0L || is.na(p) || !nzchar(p)) return(NA_character_)
  p <- path.expand(as.character(p)[[1L]])
  if (file.exists(p)) {
    return(normalizePath(p, winslash = "/", mustWork = FALSE))
  }
  parent <- dirname(p)
  if (dir.exists(parent)) {
    return(file.path(normalizePath(parent, winslash = "/", mustWork = FALSE), basename(p)))
  }
  gsub("\\\\", "/", p)
}

util_file_size <- function(path) {
  if (!file.exists(path)) return(NA_integer_)
  as.integer(file.info(path)$size)
}

#' sha256（论文可复现所需）。digest 已在 doctor 中检查。
util_sha256 <- function(path) {
  if (!file.exists(path)) return(NA_character_)
  tryCatch(digest::digest(file = path, algo = "sha256"),
           error = function(e) NA_character_)
}

util_ensure_dir <- function(path) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE, showWarnings = FALSE)
  }
  dir.exists(path)
}

#' 真正探测可写性，而不是只看 dir.exists()
util_can_write <- function(dir) {
  if (!util_ensure_dir(dir)) return(FALSE)
  probe <- file.path(dir, paste0(".probe_", Sys.getpid()))
  ok <- tryCatch({
    writeLines("probe", probe, useBytes = TRUE)
    TRUE
  }, error = function(e) FALSE, warning = function(w) FALSE)
  if (file.exists(probe)) unlink(probe)
  isTRUE(ok)
}

#' 原子写：写临时文件再 rename，避免中途失败留下半个文件
util_atomic_write <- function(path, text) {
  util_ensure_dir(dirname(path))
  tmp <- paste0(path, ".tmp", Sys.getpid())
  con <- file(tmp, open = "wb")
  writeBin(charToRaw(enc2utf8(paste0(text, collapse = "\n"))), con)
  close(con)
  if (!file.rename(tmp, path)) {
    file.copy(tmp, path, overwrite = TRUE)
    unlink(tmp)
  }
  invisible(path)
}

#' 抛出"输入有问题"的错误（区别于运行期异常）
#' 在 cmd_* 的 tryCatch 里用 inherits(err, "dmf_input_error") 判定，
#' 这样退出码才是 2（input）而不是 3（runtime）——agent 靠这个区分
#' "我传错了" 与 "程序炸了"。
dmf_stop_input <- function(...) {
  msg <- paste0(...)
  stop(structure(class = c("dmf_input_error", "error", "condition"),
                 list(message = msg, call = NULL)))
}

#' 文件系统安全名：只替换非法字符，不截断（31 字符限制只属于 Excel）
util_safe_filename <- function(x) {
  x <- as.character(x)
  x <- gsub("[\\\\/:*?\"<>|]", "_", x)
  x <- gsub("[\r\n\t]+", " ", x)
  x <- trimws(x)
  x[!nzchar(x)] <- "unnamed"
  x
}

#' 包是否可用
util_has_pkg <- function(pkg) {
  isTRUE(requireNamespace(pkg, quietly = TRUE))
}

#' 一次性取得已装包列表，避免重复扫描
util_installed_pkgs <- function() {
  ip <- tryCatch(rownames(utils::installed.packages()), error = function(e) character(0))
  ip
}

#' 右填充到指定长度
util_pad <- function(x, n, fill = NA_character_) {
  x <- as.character(x)
  if (length(x) < n) x <- c(x, rep(fill, n - length(x)))
  x[seq_len(n)]
}

#' 两位序号
util_seq2 <- function(i) sprintf("%02d", as.integer(i))

# ============================================================
# cli/lib/args.R -- 手写参数解析
# ------------------------------------------------------------
# 不引入 optparse（未安装，且会给合作者增加一个安装步骤）。
# 支持：--key value / --key=value / --flag
# 未知参数不静默忽略，而是收集起来由调用方报错并给出建议。
# ============================================================

args_value <- function(default = NULL, help = "", optional = TRUE) {
  list(type = "value", default = default, help = help, optional = optional)
}

args_flag <- function(default = FALSE, help = "") {
  list(type = "flag", default = default, help = help)
}

args_spec <- function(...) {
  spec <- list(...)
  if (is.null(names(spec)) || any(!nzchar(names(spec)))) {
    stop("args_spec(): 每一项都必须命名", call. = FALSE)
  }
  spec
}

args_parse <- function(argv, spec) {
  vals <- lapply(spec, function(s) s$default)
  names(vals) <- names(spec)
  positional <- character(0)
  unknown <- character(0)
  missing_value <- character(0)

  i <- 1L
  n <- length(argv)
  while (i <= n) {
    a <- argv[[i]]

    if (grepl("^--[A-Za-z0-9_.-]+=", a)) {
      key <- sub("^--([^=]+)=.*$", "\\1", a)
      val <- sub("^[^=]+=", "", a)
      key <- gsub("-", "_", key)
      if (!key %in% names(spec)) {
        unknown <- c(unknown, paste0("--", key))
      } else if (identical(spec[[key]]$type, "flag")) {
        vals[[key]] <- !identical(tolower(val), "false") && !identical(val, "0")
      } else {
        vals[[key]] <- val
      }
      i <- i + 1L
      next
    }

    if (grepl("^--?[A-Za-z0-9_.-]+$", a)) {
      key <- gsub("-", "_", sub("^--?", "", a))
      if (!key %in% names(spec)) {
        unknown <- c(unknown, a)
        i <- i + 1L
        next
      }
      if (identical(spec[[key]]$type, "flag")) {
        vals[[key]] <- TRUE
        i <- i + 1L
        next
      }
      if (i + 1L > n || grepl("^--?[A-Za-z]", argv[[i + 1L]])) {
        missing_value <- c(missing_value, paste0("--", key))
        i <- i + 1L
        next
      }
      vals[[key]] <- argv[[i + 1L]]
      i <- i + 2L
      next
    }

    positional <- c(positional, a)
    i <- i + 1L
  }

  list(values = vals, positional = positional,
       unknown = unique(unknown), missing_value = unique(missing_value))
}

#' 最接近的合法参数名（编辑距离 <= 2）
args_suggest <- function(bad, spec_names) {
  bare <- gsub("^-+", "", bad)
  bare <- gsub("-", "_", bare)
  d <- utils::adist(bare, spec_names)[1L, ]
  hit <- spec_names[d <= 2L]
  if (length(hit) == 0L) return(NA_character_)
  hit[which.min(d[d <= 2L])]
}

args_as_int <- function(x, default = NULL) {
  if (is.null(x) || length(x) == 0L || is.na(x) || !nzchar(as.character(x))) return(default)
  v <- suppressWarnings(as.integer(as.character(x)))
  if (is.na(v)) return(default)
  v
}

args_as_num <- function(x, default = NULL) {
  if (is.null(x) || length(x) == 0L || is.na(x) || !nzchar(as.character(x))) return(default)
  v <- suppressWarnings(as.numeric(as.character(x)))
  if (is.na(v)) return(default)
  v
}

#' 生成 --help 文本
args_usage <- function(command, spec, header = NULL, examples = NULL) {
  # 按显示宽度补空格：中文占两列，sprintf 的 %-Ns 按字符数算会歪
  pad <- function(x, n) {
    x <- as.character(x)
    paste0(x, strrep(" ", pmax(0L, n - nchar(x, type = "width"))))
  }
  lines <- c(header, "", sprintf("用法：Rscript cli/dmf.R %s [选项]", command), "", "选项：")
  for (nm in names(spec)) {
    s <- spec[[nm]]
    label <- paste0("--", gsub("_", "-", nm),
                    if (identical(s$type, "flag")) "" else " <值>")
    def <- if (is.null(s$default) || identical(s$default, FALSE)) "" else
      sprintf("  [默认: %s]", paste(s$default, collapse = ","))
    lines <- c(lines, sprintf("  %s %s%s", pad(label, 22), s$help, def))
  }
  if (!is.null(examples)) lines <- c(lines, "", "示例：", paste0("  ", examples))
  paste(lines, collapse = "\n")
}

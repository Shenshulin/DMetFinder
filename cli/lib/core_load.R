# ============================================================
# cli/lib/core_load.R -- 装载计算层，并注入写盘接缝
# ------------------------------------------------------------
# 只 source 与界面无关的两个文件。已核实 R/dmetfinder_functions.R 的外部
# 依赖仅 openxlsx:: / readxl:: / stats::，不含 dplyr、data.table 的裸调用，
# 因此 diff 这条路径对合作者的环境要求很低。第三页（peak_quality）不接入。
#
# ---- 关于下面的"注入" --------------------------------------
# dmetfinder_run() 内部写盘只经过一个函数 dmf_write_sheets()，全文件仅一处
# 调用（局部函数 w()）。我们在 core 这个 environment 里重新绑定它，让
# dmetfinder_run() 解析到我们的版本。这不是猴子补丁：R 的词法作用域规定
# 函数在其定义环境中查找自由变量，core 就是 dmetfinder_run 的定义环境，
# 所以这是标准的依赖注入。
#
# 注入版本什么都不写。CSV 全部由 csv_write_all() 在 run 结束后从返回值
# $sheets 生成——返回值与写盘内容由构造保证一致（见 csv_collect 的注释），
# 因此不必"写 xlsx 再读回来"，也就避开了 48 万行表的二次读写与浮点风险。
#
# 要产出 xlsx 时（--xlsx）不注入，让原版照常写。
# ------------------------------------------------------------

DMF_CORE_FILES <- c(
  "R/config.R",
  "R/dmetfinder_functions.R"
)

dmf_core_load <- function(root, suppress_writes = TRUE) {
  core <- new.env(parent = globalenv())

  for (rel in DMF_CORE_FILES) {
    path <- file.path(root, rel)
    if (!file.exists(path)) {
      stop(sprintf("缺少核心文件：%s（项目根目录是否正确？）", rel), call. = FALSE)
    }
    sys.source(path, envir = core, keep.source = FALSE)
  }

  needed <- c("dmetfinder_run", "dmf_write_sheets", "dmf_merge_config")
  absent <- needed[!vapply(needed, exists, logical(1L), envir = core, inherits = FALSE)]
  if (length(absent) > 0L) {
    stop(sprintf("核心文件已加载，但缺少函数：%s", paste(absent, collapse = ", ")),
         call. = FALSE)
  }

  if (isTRUE(suppress_writes)) {
    core$dmf_write_sheets <- function(sheets, path) invisible(path)
  }

  attr(core, "root") <- root
  core
}

#' 把 CLI 的进度回调适配成 dmetfinder_run 需要的 progress(frac, detail)
dmf_progress_printer <- function(quiet = FALSE, jsonl = FALSE) {
  last <- -1
  function(frac, detail) {
    if (isTRUE(quiet)) return(invisible(NULL))
    pct <- max(0L, min(100L, as.integer(round(frac * 100))))
    if (pct == last) return(invisible(NULL))
    last <<- pct
    if (isTRUE(jsonl)) {
      cat(sprintf('{"progress":%d,"detail":%s}\n', pct,
                  jsonlite::toJSON(as.character(detail), auto_unbox = TRUE)),
          file = stderr())
    } else {
      cat(sprintf("\r[%3d%%] %-52s", pct, substr(as.character(detail), 1, 52)),
          file = stderr())
      if (pct >= 100L) cat("\n", file = stderr())
    }
    utils::flush.console()
    invisible(NULL)
  }
}

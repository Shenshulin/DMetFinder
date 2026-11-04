# ============================================================
# cli/lib/ms_core.R -- 装载 MSGeter 计算层（只读复用，不搬家）
# ------------------------------------------------------------
# 三个 *_server.R 里的计算函数都定义在文件顶层，shiny 调用全部落在
# moduleServer() 的函数体内（FeatureGeter 509 / Ms2Geter 157 / RtGeter 609）。
# 因此 source() 进一个独立 environment 就能直接调用，不会触发任何界面逻辑。
#
# 这个 environment 的父环境是 globalenv()，所以：
#   * 文件内互相引用（read_ms_file -> clean_spectrum_keep_max）走词法作用域
#   * 需要的包仍能在 search path 里找到
#
# source 顺序有硬约束：FeatureGeter_server.R 第 12 行定义 MS1_SCAN_TYPE，
# 而 RtGeter_server.R 的 rtg_ms1_index() 会用它兜底判断 MS1。反过来 source
# 会让 .raw 路径的 MS1 判定静默退化成默认分支。
# ============================================================

MS_CORE_FILES <- c(
  "shiny_app/server/FeatureGeter_server.R",
  "shiny_app/server/Ms2Geter_server.R",
  "shiny_app/server/RtGeter_server.R"
)

#' 载入 MSGeter 计算层
#'
#' @param root  项目根目录
#' @param quiet TRUE 时把 mem_probe 换成空实现（它默认往 stderr 打 [MEM] 行）
ms_core_load <- function(root, quiet = TRUE) {
  env <- new.env(parent = globalenv())

  for (rel in MS_CORE_FILES) {
    path <- file.path(root, rel)
    if (!file.exists(path)) {
      stop(sprintf("缺少 MSGeter 源文件：%s（项目根目录是否正确？）", rel),
           call. = FALSE)
    }
    sys.source(path, envir = env, keep.source = FALSE)
  }

  needed <- c("read_ms_file", "clean_spectrum_keep_max",
              "rtg_read_table", "rtg_detect_cols", "rtg_norm_colname",
              "rtg_list_ms_files", "rtg_run_batch")
  absent <- needed[!vapply(needed, exists, logical(1L), envir = env,
                           inherits = FALSE)]
  if (length(absent) > 0L) {
    stop(sprintf(paste0("MSGeter 源文件已加载，但缺少函数：%s。",
                        "这通常意味着上游文件结构变了，请同步更新 ms_core.R"),
                 paste(absent, collapse = ", ")), call. = FALSE)
  }

  if (isTRUE(quiet)) {
    # 同名注入：read_ms_file 内部调 mem_probe 时会解析到这一版（词法作用域）
    env$mem_probe <- function(tag) invisible(NA_real_)
  }

  attr(env, "root") <- root
  env
}

#' 按扩展名检查读取所需的包，缺了给出可直接执行的一句话
ms_core_check_reader <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (identical(ext, "raw")) {
    if (!util_has_pkg("rawrr")) {
      stop(paste0("读取 .raw 需要 rawrr 包（还需要 .NET 6 运行时）。\n",
                  "  install.packages('rawrr')\n",
                  "  或改用 .mzML：msconvert 转换后再跑，CLI 对两种格式结果一致。"),
           call. = FALSE)
    }
    if (!util_has_pkg("stringr")) {
      stop("读取 .raw 需要 stringr 包（上游 read_ms_file 用它解析扫描类型）：\n",
           "  install.packages('stringr')", call. = FALSE)
    }
  } else if (ext %in% c("mzml", "mzxml")) {
    if (!util_has_pkg("mzR")) {
      stop(paste0("读取 .mzML/.mzXML 需要 mzR 包：\n",
                  "  BiocManager::install('mzR')"), call. = FALSE)
    }
  } else {
    stop(sprintf("不支持的质谱格式：.%s（支持 .raw / .mzML / .mzXML）", ext),
         call. = FALSE)
  }
  invisible(TRUE)
}

#' 列出目录下的质谱文件（与 Ms1Geter 的扫描规则一致）
ms_core_list_files <- function(dir) {
  if (!dir.exists(dir)) return(character(0))
  list.files(path = dir, pattern = "\\.(raw|mzml|mzxml)$",
             full.names = TRUE, ignore.case = TRUE)
}

#' 样品 ID = 去掉扩展名的文件名（与 Ms1Geter / RtGeter 一致）
ms_core_sample_id <- function(path) tools::file_path_sans_ext(basename(path))

#' 同一 ID 出现在多种格式时保留第一个，其余记入跳过清单
ms_core_dedupe <- function(files) {
  ids <- vapply(files, ms_core_sample_id, character(1), USE.NAMES = FALSE)
  keep <- !duplicated(ids)
  list(files = files[keep], ids = ids[keep],
       skipped = files[!keep], skipped_ids = ids[!keep])
}

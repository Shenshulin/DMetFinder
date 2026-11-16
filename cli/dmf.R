#!/usr/bin/env Rscript
# ============================================================
# DMetFinder CLI -- agent 调用层的唯一入口
# ------------------------------------------------------------
# 用法：Rscript cli/dmf.R <command> [options]
#       cli\run-dmf.bat <command> [options]    (Windows，自动处理环境)
#
# 设计约束：不修改 DMetFinder 现有任何文件。本层只调用 R/config.R 与
# R/dmetfinder_functions.R 中的函数，并通过注入 dmf_write_sheets() 阻止
# 写 xlsx，改由 csv_out.R 从返回值生成 CSV。
# ============================================================

DMF_VERSION <- "1.0.4"

# ---- 定位项目根并载入 lib ----
# 刻意写成平铺形式而不是 local({...})：嵌套一层会让 R 在进程收尾阶段
# 更易触发访问违例（见 DMF_HEAVY 的注释）。
.dmf_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
if (length(.dmf_file_arg) == 0L) {
  stop("请用 Rscript 运行本脚本（需要 --file= 参数定位项目根目录）", call. = FALSE)
}
DMF_SCRIPT <- normalizePath(sub("^--file=", "", .dmf_file_arg[[1L]]),
                            winslash = "/", mustWork = TRUE)
DMF_ROOT <- normalizePath(file.path(dirname(DMF_SCRIPT), ".."),
                          winslash = "/", mustWork = TRUE)

for (.dmf_mod in c("util", "args", "envelope", "csv_out", "core_load",
                   "inspect_xlsx", "doctor", "progress", "ms_core",
                   "msg_extract", "msg_match", "rt_apex")) {
  .dmf_path <- file.path(DMF_ROOT, "cli", "lib", paste0(.dmf_mod, ".R"))
  if (!file.exists(.dmf_path)) stop(sprintf("缺少 CLI 模块：%s", .dmf_path), call. = FALSE)
  sys.source(.dmf_path, envir = globalenv(), keep.source = FALSE)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L || is.na(a)) b else a

# ---- 版本信息 ----
# 直接读 .git/HEAD，不调用 git 命令：合作者拿到的是 zip，既没有 .git 也
# 未必装了 git；而且在分析过程中 spawn 子进程没有必要。
dmf_git_commit <- function() {
  head <- file.path(DMF_ROOT, ".git", "HEAD")
  if (!file.exists(head)) return(NA_character_)
  h <- tryCatch(readLines(head, n = 1L, warn = FALSE), error = function(e) NA_character_)
  if (length(h) == 0L || is.na(h)) return(NA_character_)
  h <- trimws(h)

  if (!grepl("^ref:", h)) return(substr(h, 1L, 7L))

  ref <- trimws(sub("^ref:", "", h))
  loose <- file.path(DMF_ROOT, ".git", ref)
  if (file.exists(loose)) {
    s <- tryCatch(readLines(loose, n = 1L, warn = FALSE), error = function(e) NA_character_)
    if (length(s) == 1L && !is.na(s)) return(substr(trimws(s), 1L, 7L))
  }
  packed <- file.path(DMF_ROOT, ".git", "packed-refs")
  if (file.exists(packed)) {
    ln <- tryCatch(readLines(packed, warn = FALSE), error = function(e) character(0))
    hit <- grep(paste0(" ", ref, "$"), ln, value = TRUE)
    if (length(hit) > 0L) return(substr(trimws(sub(" .*$", "", hit[[1L]])), 1L, 7L))
  }
  NA_character_
}

# ============================================================
# 各命令的参数定义
# ============================================================

spec_common <- function() list(
  json = args_flag(help = "输出 JSON 信封"),
  quiet = args_flag(help = "不打印进度"),
  help = args_flag(help = "显示帮助")
)

spec_version <- function() c(spec_common())
spec_doctor  <- function() c(spec_common())

spec_inspect <- function() c(list(
  input = args_value(help = "待检查的 xlsx 路径"),
  out = args_value(help = "报告输出目录（默认与输入同级）"),
  block_width = args_value(default = "auto", help = "每样品块宽（列）；auto = 按表头识别（含 RT_apex 时 7，否则 6）"),
  overwrite = args_flag(help = "允许写入非空输出目录")
), spec_common())

spec_diff <- function() c(list(
  a = args_value(help = "A 组输入 xlsx"),
  b = args_value(help = "B 组输入 xlsx"),
  out = args_value(help = "输出目录"),
  groups = args_value(default = "Group A,Group B", help = "组名，逗号分隔"),
  params = args_value(help = "参数 JSON 文件（键名同 R/config.R）"),
  keep_empty_cols = args_flag(help = "保留全空列"),
  bom = args_flag(help = "CSV 带 UTF-8 BOM（Excel 直接打开时需要）"),
  xlsx = args_flag(help = "额外产出原版 xlsx"),
  overwrite = args_flag(help = "允许写入非空输出目录")
), spec_common())

spec_msg_extract <- function() c(list(
  ms_dir = args_value(help = "质谱文件目录（.raw / .mzML / .mzXML）"),
  samples = args_value(help = "分组文件（csv/xlsx，含 Sample 与 Group 两列）"),
  out = args_value(help = "输出目录"),
  rt_min = args_value(default = "1",
                      help = "实际采集时间下限（分钟）。输出 RT = 该值 + 1，故 1 对应 RT 2"),
  rt_max = args_value(default = "18",
                      help = "实际采集时间上限（分钟）。输出 RT = 该值 + 1，故 18 对应 RT 19"),
  max_mz = args_value(default = "1500", help = "去卷积 m/z 上限"),
  min_intensity = args_value(default = "10000", help = "去卷积后强度下限"),
  ppm = args_value(default = "10",
                   help = "去卷积窗口（ppm，相对质量容差）。同桶内按此归簇取最强；profile 数据也按同一窗口折叠"),
  ms2_gap = args_value(default = "0.9", help = "MS2 前体 m/z 分组间隔"),
  slow_deconv = args_flag(help = "用上游 R 循环去卷积（结果相同，约慢 100 倍）"),
  no_input_hash = args_flag(help = "不计算输入文件的 sha256（几 GB 数据可省时间）"),
  bom = args_flag(help = "CSV 带 UTF-8 BOM"),
  xlsx = args_flag(help = "额外写出界面同款 Clean_MS1_Data_Group*.xlsx"),
  overwrite = args_flag(help = "允许写入非空输出目录")
), spec_common())

spec_msg_match <- function() c(list(
  features = args_value(help = "峰表（csv/xlsx/tsv，需含 sample、m/z、RT）"),
  ms2_info = args_value(help = "msg-extract 产出的 01_MS2_Group_Info.csv"),
  msp_dir = args_value(help = "msg-extract 产出的 ms2_msp 目录"),
  out = args_value(help = "输出目录"),
  mz_tol = args_value(default = "0.01", help = "前体 m/z 窗口（Da）"),
  rt_tol = args_value(help = "RT 窗口（分钟）；默认不限，与界面一致"),
  sample_col = args_value(help = "峰表里样品列的名称或列号"),
  mz_col = args_value(help = "峰表里 m/z 列的名称或列号"),
  rt_col = args_value(help = "峰表里 RT 列的名称或列号"),
  bom = args_flag(help = "CSV 带 UTF-8 BOM"),
  overwrite = args_flag(help = "允许写入非空输出目录")
), spec_common())

spec_rt_apex <- function() c(list(
  features = args_value(help = "峰表（csv/xlsx/tsv，需含 ID、样品、m/z、RT）"),
  ms_dir = args_value(help = "质谱文件目录（.raw / .mzML / .mzXML）"),
  out = args_value(help = "输出目录"),
  tol = args_value(default = "10", help = "取峰窗口"),
  unit = args_value(default = "ppm", help = "窗口单位：ppm 或 da"),
  id_col = args_value(help = "峰 ID 列"),
  sample_col = args_value(help = "样品列"),
  mz_col = args_value(help = "m/z 列"),
  rt_col = args_value(help = "RT 列"),
  bom = args_flag(help = "CSV 带 UTF-8 BOM"),
  overwrite = args_flag(help = "允许写入非空输出目录")
), spec_common())

spec_job <- function() c(list(
  out = args_value(help = "作业输出目录（含 progress.json / run.json）"),
  wait = args_flag(help = "阻塞直到作业结束"),
  timeout = args_value(default = "1800", help = "wait 的超时秒数"),
  interval = args_value(default = "2", help = "轮询间隔秒数")
), spec_common())

# ============================================================
# 命令实现
# ============================================================

cmd_version <- function(p) {
  e <- env_new("version", DMF_VERSION, dmf_git_commit())
  env_add_metric(e, "r_version", paste(R.version$major, R.version$minor, sep = "."))
  env_add_metric(e, "platform", R.version$platform)
  env_add_metric(e, "project_root", DMF_ROOT)
  e
}

cmd_doctor <- function(p) {
  e <- env_new("doctor", DMF_VERSION, dmf_git_commit())
  res <- doctor_run(DMF_ROOT)
  env_set_extra(e, "checks", lapply(res$checks, function(c)
    list(name = c$name, status = c$status, detail = c$detail,
         fix = if (is.null(c$fix)) NA_character_ else c$fix)))
  env_add_metric(e, "n_fail", res$n_fail)
  env_add_metric(e, "n_warn", res$n_warn)
  if (!res$ok) {
    env_set_error(e, "runtime", "环境自检未通过，见 checks",
                  "按 fix 字段逐项处理")
  }
  if (isTRUE(p$values$json)) return(e)
  cat(doctor_render(res), sep = "\n")
  cat("\n")
  e
}

cmd_inspect <- function(p) {
  input <- p$values$input
  if (is.null(input)) {
    e <- env_new("inspect", DMF_VERSION, dmf_git_commit())
    env_set_error(e, "usage", "缺少 --input", "例：--input demo_data/groupA.xlsx")
    return(e)
  }
  out <- p$values$out %||% file.path(dirname(input), "inspect")
  out <- util_norm_path(out)

  e <- env_new("inspect", DMF_VERSION, dmf_git_commit())
  env_set_extra(e, "job_dir", out)
  env_add_input(e, "xlsx", input)
  env_set_params(e, list(block_width = args_as_int(p$values$block_width, NA_integer_)))

  if (!isTRUE(p$values$overwrite) && dir.exists(out) && length(list.files(out)) > 0L) {
    env_set_error(e, "input", sprintf("输出目录非空：%s", out), "加 --overwrite 覆盖")
    return(e)
  }

  res <- inspect_xlsx(input, args_as_int(p$values$block_width, NA_integer_))
  files <- inspect_write_csv(res, file.path(out, "tables"))
  for (f in files) env_add_output(e, "table", f)

  env_set_extra(e, "summary", res$summary)
  for (fd in res$findings) {
    env_add_warning(e, fd$code, fd$message)
  }
  if (!isTRUE(res$ok)) {
    env_set_error(e, "input",
                  sprintf("发现问题：%d 个错误，%d 个警告",
                          res$summary$errors, res$summary$warnings),
                  "详见 tables/inspect_findings.csv")
  }
  e
}

cmd_diff <- function(p) {
  a <- p$values$a
  b <- p$values$b
  out <- p$values$out

  e <- env_new("diff", DMF_VERSION, dmf_git_commit())
  if (is.null(a) || is.null(b) || is.null(out)) {
    env_set_error(e, "usage", "缺少 --a / --b / --out",
                  "例：--a demo_data/groupA.xlsx --b demo_data/groupB.xlsx --out out/run1")
    return(e)
  }
  if (!file.exists(a)) {
    env_set_error(e, "input", sprintf("A 组文件不存在：%s", a))
    return(e)
  }
  if (!file.exists(b)) {
    env_set_error(e, "input", sprintf("B 组文件不存在：%s", b))
    return(e)
  }

  out <- util_norm_path(out)
  env_set_extra(e, "job_dir", out)
  if (!isTRUE(p$values$overwrite) && dir.exists(out) && length(list.files(out)) > 0L) {
    env_set_error(e, "input", sprintf("输出目录非空：%s", out), "加 --overwrite 覆盖")
    return(e)
  }
  if (!util_can_write(out)) {
    env_set_error(e, "runtime", sprintf("输出目录不可写：%s", out))
    return(e)
  }

  groups <- trimws(strsplit(p$values$groups %||% "Group A,Group B", ",")[[1L]])
  if (length(groups) != 2L || any(!nzchar(groups))) {
    env_set_error(e, "usage", "--groups 需要两个组名（逗号分隔）")
    return(e)
  }

  # ---- 参数：默认值 + 可选 JSON 覆盖 ----
  core <- dmf_core_load(DMF_ROOT, suppress_writes = is.null(p$values$xlsx) || !isTRUE(p$values$xlsx))
  cfg <- list()
  if (!is.null(p$values$params)) {
    if (!file.exists(p$values$params)) {
      env_set_error(e, "input", sprintf("参数文件不存在：%s", p$values$params))
      return(e)
    }
    cfg <- tryCatch(
      jsonlite::fromJSON(p$values$params, simplifyVector = TRUE),
      error = function(err) {
        env_set_error(e, "input", sprintf("参数文件不是合法 JSON：%s", conditionMessage(err)))
        NULL
      }
    )
    if (is.null(cfg)) return(e)
  }
  merged <- core$dmf_merge_config(cfg)
  env_set_params(e, merged)

  env_add_input(e, "group_a", a)
  env_add_input(e, "group_b", b)

  # ---- 运行 ----
  work_dir <- if (isTRUE(p$values$xlsx)) file.path(out, "xlsx") else
    file.path(tempdir(), "dmf_nowrite")
  util_ensure_dir(work_dir)

  progress <- dmf_progress_printer(quiet = isTRUE(p$values$quiet))
  res <- core$dmetfinder_run(
    file_a = a, file_b = b, output_dir = work_dir,
    config = cfg, group_names = groups,
    verbose = FALSE, progress = progress
  )
  if (!isTRUE(p$values$quiet)) cat("\n", file = stderr())

  # ---- CSV（19 个 sheet 拆表） ----
  ctx <- csv_ctx_new(out, keep_empty = isTRUE(p$values$keep_empty_cols),
                     bom = isTRUE(p$values$bom))
  written <- csv_write_all(res, ctx, groups, e)

  if (isTRUE(p$values$xlsx)) {
    for (f in res$files) env_add_output(e, "xlsx", f)
  }

  env_add_metric(e, "n_tables", length(written$outputs))
  env_add_metric(e, "n_rows_a", nrow(res$groups$A$ions))
  env_add_metric(e, "n_rows_b", nrow(res$groups$B$ions))
  env_add_metric(e, "n_diff_ab", nrow(res$diff$ab))
  env_add_metric(e, "n_diff_ba", nrow(res$diff$ba))
  env_add_metric(e, "n_diff_union", if (is.null(res$diff$union)) 0L else nrow(res$diff$union$df))
  env_add_metric(e, "p80_label", as.character(res$p80_str))
  env_add_metric(e, "dropped_empty_cols", sum(vapply(written$outputs,
                                                     function(o) o$dropped_cols, integer(1L))))

  # 见文件末尾的收尾注释：这些大对象一旦在函数返回后变成垃圾，随后的写盘与
  # 哈希会让进程在退出阶段 segfault（exit 139）。显式保留引用到进程退出。
  assign(".dmf_keep", list(res = res, core = core), envir = globalenv())
  e
}

# ============================================================
# P1：MSGeter 三个子命令 + 作业查询
# ============================================================

#' 输出目录的公共前置检查，返回规范化后的路径；失败返回 NULL 并写好信封
dmf_check_out <- function(e, out, overwrite) {
  out <- util_norm_path(out)
  env_set_extra(e, "job_dir", out)
  if (!isTRUE(overwrite) && dir.exists(out) && length(list.files(out)) > 0L) {
    env_set_error(e, "input", sprintf("输出目录非空：%s", out), "加 --overwrite 覆盖")
    return(NULL)
  }
  if (!util_can_write(out)) {
    env_set_error(e, "runtime", sprintf("输出目录不可写：%s", out))
    return(NULL)
  }
  out
}

cmd_msg_extract <- function(p) {
  v <- p$values
  e <- env_new("msg-extract", DMF_VERSION, dmf_git_commit())

  if (is.null(v$ms_dir) || is.null(v$out)) {
    env_set_error(e, "usage", "缺少 --ms-dir / --out",
                  "例：--ms-dir raw --out out/msg1")
    return(e)
  }
  if (!dir.exists(v$ms_dir)) {
    env_set_error(e, "input", sprintf("质谱目录不存在：%s", v$ms_dir))
    return(e)
  }

  files <- ms_core_list_files(v$ms_dir)
  if (length(files) == 0L) {
    env_set_error(e, "input",
                  sprintf("目录里没有 .raw / .mzML / .mzXML：%s", v$ms_dir),
                  "支持 .raw（需 rawrr）与 .mzML/.mzXML（需 mzR）")
    return(e)
  }

  out <- dmf_check_out(e, v$out, v$overwrite)
  if (is.null(out)) return(e)

  dd <- ms_core_dedupe(files)
  ids <- dd$ids
  if (length(dd$skipped) > 0L) {
    env_add_warning(e, "duplicate_format_skipped",
                    sprintf("%d 个文件因同名样品已处理而跳过：%s",
                            length(dd$skipped),
                            paste(basename(dd$skipped), collapse = ", ")),
                    n = length(dd$skipped))
  }

  # ---- 分组 ----
  group_of <- stats::setNames(rep("All", length(ids)), ids)
  if (!is.null(v$samples)) {
    if (!file.exists(v$samples)) {
      env_set_error(e, "input", sprintf("分组文件不存在：%s", v$samples))
      return(e)
    }
    grp <- tryCatch(msx_read_groups(v$samples),
                    error = function(err) {
                      env_set_error(e, "input", conditionMessage(err))
                      NULL
                    })
    if (is.null(grp)) return(e)
    env_add_input(e, "samples", v$samples)

    no_file <- setdiff(grp$Sample, ids)
    if (length(no_file) > 0L) {
      env_add_warning(e, "sample_without_file",
                      sprintf("分组文件里的 %d 个样品没有对应谱图：%s",
                              length(no_file), paste(no_file, collapse = ", ")),
                      n = length(no_file))
    }
    no_grp <- setdiff(ids, grp$Sample)
    if (length(no_grp) > 0L) {
      env_add_warning(e, "sample_without_group",
                      sprintf("%d 个谱图未在分组文件里，已归入 Ungrouped：%s",
                              length(no_grp), paste(no_grp, collapse = ", ")),
                      n = length(no_grp))
    }

    m <- stats::setNames(grp$Group, grp$Sample)
    group_of <- stats::setNames(
      ifelse(ids %in% names(m), m[match(ids, names(m))], "Ungrouped"), ids)
  }

  # ---- 参数 ----
  prm <- msx_default_params()
  prm$rt_min        <- args_as_num(v$rt_min, prm$rt_min)
  prm$rt_max        <- args_as_num(v$rt_max, prm$rt_max)
  prm$max_mz        <- args_as_num(v$max_mz, prm$max_mz)
  prm$min_intensity <- args_as_num(v$min_intensity, prm$min_intensity)
  prm$ppm           <- args_as_num(v$ppm, prm$ppm)
  prm$ms2_group_gap <- args_as_num(v$ms2_gap, prm$ms2_group_gap)
  if (prm$rt_max <= prm$rt_min) {
    env_set_error(e, "usage", sprintf("--rt-max (%s) 必须大于 --rt-min (%s)",
                                      prm$rt_max, prm$rt_min))
    return(e)
  }
  if (!is.finite(prm$ppm) || prm$ppm <= 0) {
    env_set_error(e, "usage", sprintf("--ppm (%s) 必须是正数（相对质量窗口，单位 ppm）",
                                      prm$ppm))
    return(e)
  }
  env_set_params(e, prm)

  # ---- 输入指纹 ----
  do_hash <- !isTRUE(v$no_input_hash)
  for (f in dd$files) env_add_input(e, "ms", f, hash = do_hash)
  if (!do_hash) {
    env_add_warning(e, "input_hash_skipped",
                    "按 --no-input-hash 跳过了输入文件的 sha256，run.json 无法用于复核原始数据")
  }

  core <- tryCatch(ms_core_load(DMF_ROOT), error = function(err) {
    env_set_error(e, "runtime", conditionMessage(err)); NULL
  })
  if (is.null(core)) return(e)

  prog <- prog_new(out, "msg-extract", total = length(ids),
                   quiet = isTRUE(v$quiet))

  res <- tryCatch(
    msx_run(core, dd$files, ids, group_of, prm, out, prog, e,
            slow = isTRUE(v$slow_deconv),
            write_xlsx = isTRUE(v$xlsx),
            bom = isTRUE(v$bom)),
    error = function(err) {
      prog$finish("failed", conditionMessage(err))
      env_set_error(e, "runtime", conditionMessage(err),
                    "进度与失败点见 progress.log；已写出的 CSV 可能不完整")
      NULL
    }
  )
  if (is.null(res)) return(e)
  prog$finish("done")

  env_add_metric(e, "n_samples", length(ids))
  env_add_metric(e, "n_ms2_scans", res$ms2_rows)
  env_add_metric(e, "n_ms1_peaks", sum(res$summary$N_MS1_peaks))
  env_add_metric(e, "groups", paste(unique(group_of[ids]), collapse = ","))
  env_add_metric(e, "tab_files", length(list.files(file.path(out, "tables"))))

  assign(".dmf_keep", list(core = core, res = res), envir = globalenv())
  e
}

cmd_msg_match <- function(p) {
  v <- p$values
  e <- env_new("msg-match", DMF_VERSION, dmf_git_commit())

  need <- c("features", "ms2_info", "msp_dir", "out")
  miss <- need[vapply(need, function(k) is.null(v[[k]]), logical(1L))]
  if (length(miss) > 0L) {
    env_set_error(e, "usage",
                  sprintf("缺少 %s", paste(sprintf("--%s", gsub("_", "-", miss)),
                                          collapse = " / ")),
                  "例：--features peaks.csv --ms2-info out/msg1/tables/01_MS2_Group_Info.csv --msp-dir out/msg1/ms2_msp --out out/match1")
    return(e)
  }
  if (!file.exists(v$features)) {
    env_set_error(e, "input", sprintf("峰表不存在：%s", v$features))
    return(e)
  }
  if (!file.exists(v$ms2_info)) {
    env_set_error(e, "input", sprintf("MS2 扫描表不存在：%s", v$ms2_info))
    return(e)
  }
  if (!dir.exists(v$msp_dir)) {
    env_set_error(e, "input", sprintf("MSP 目录不存在：%s", v$msp_dir))
    return(e)
  }

  out <- dmf_check_out(e, v$out, v$overwrite)
  if (is.null(out)) return(e)

  core <- tryCatch(ms_core_load(DMF_ROOT), error = function(err) {
    env_set_error(e, "runtime", conditionMessage(err)); NULL
  })
  if (is.null(core)) return(e)

  features <- tryCatch(core$rtg_read_table(v$features), error = function(err) {
    env_set_error(e, "input", conditionMessage(err)); NULL
  })
  if (is.null(features)) return(e)

  all_ms2 <- tryCatch(
    data.table::fread(v$ms2_info, data.table = FALSE, encoding = "UTF-8"),
    error = function(err) {
      env_set_error(e, "input",
                    sprintf("MS2 扫描表读取失败：%s", conditionMessage(err)))
      NULL
    })
  if (is.null(all_ms2)) return(e)

  cols <- tryCatch(
    msm_resolve_cols(features, list(sample = v$sample_col, mz = v$mz_col,
                                    rt = v$rt_col)),
    error = function(err) {
      env_set_error(e, "input", conditionMessage(err),
                    "也可用 --sample-col / --mz-col / --rt-col 指定")
      NULL
    })
  if (is.null(cols)) return(e)

  prm <- msm_default_params()
  prm$mz_tol <- args_as_num(v$mz_tol, prm$mz_tol)
  prm$rt_tol <- args_as_num(v$rt_tol, Inf)
  if (!is.finite(prm$mz_tol) || prm$mz_tol <= 0) {
    env_set_error(e, "usage", "--mz-tol 必须是正数（单位 Da）")
    return(e)
  }
  env_set_params(e, c(prm, list(cols = as.list(cols$names),
                                col_resolution = as.list(cols$how))))

  env_add_input(e, "features", v$features)
  env_add_input(e, "ms2_info", v$ms2_info)

  prog <- prog_new(out, "msg-match", total = NA_integer_, quiet = isTRUE(v$quiet))
  res <- tryCatch(
    msm_run(features, cols, all_ms2, v$msp_dir, out, prm, e, prog,
            bom = isTRUE(v$bom)),
    error = function(err) {
      prog$finish("failed", conditionMessage(err))
      # dmf_input_error 表示"调用方传的东西不对"，退出码必须是 2 而不是 3
      env_set_error(e, if (inherits(err, "dmf_input_error")) "input" else "runtime",
                    conditionMessage(err))
      NULL
    })
  if (is.null(res)) return(e)
  prog$finish("done")

  env_add_metric(e, "n_features", res$n_features)
  env_add_metric(e, "n_matched", res$n_matched)
  env_add_metric(e, "match_rate", round(res$n_matched / max(1L, res$n_features), 4))
  env_add_metric(e, "n_msp_files", res$n_msp_files)

  assign(".dmf_keep", list(core = core, res = res), envir = globalenv())
  e
}

cmd_rt_apex <- function(p) {
  v <- p$values
  e <- env_new("rt-apex", DMF_VERSION, dmf_git_commit())

  need <- c("features", "ms_dir", "out")
  miss <- need[vapply(need, function(k) is.null(v[[k]]), logical(1L))]
  if (length(miss) > 0L) {
    env_set_error(e, "usage",
                  sprintf("缺少 %s", paste(sprintf("--%s", gsub("_", "-", miss)),
                                          collapse = " / ")),
                  "例：--features peaks.csv --ms-dir raw --out out/apex1")
    return(e)
  }
  if (!file.exists(v$features)) {
    env_set_error(e, "input", sprintf("峰表不存在：%s", v$features))
    return(e)
  }
  if (!dir.exists(v$ms_dir)) {
    env_set_error(e, "input", sprintf("质谱目录不存在：%s", v$ms_dir))
    return(e)
  }

  unit <- tolower(v$unit %||% "ppm")
  if (!unit %in% c("ppm", "da")) {
    env_set_error(e, "usage", "--unit 只能是 ppm 或 da")
    return(e)
  }
  tol <- args_as_num(v$tol, 10)
  if (is.null(tol) || tol <= 0) {
    env_set_error(e, "usage", "--tol 必须是正数")
    return(e)
  }

  out <- dmf_check_out(e, v$out, v$overwrite)
  if (is.null(out)) return(e)

  core <- tryCatch(ms_core_load(DMF_ROOT), error = function(err) {
    env_set_error(e, "runtime", conditionMessage(err)); NULL
  })
  if (is.null(core)) return(e)

  env_add_input(e, "features", v$features)
  env_set_params(e, list(tol = tol, unit = unit))

  prog <- prog_new(out, "rt-apex", quiet = isTRUE(v$quiet))
  res <- tryCatch(
    rta_run(core, v$features, v$ms_dir, out,
            list(tol = tol, unit = unit),
            overrides = list(id = v$id_col, sample = v$sample_col,
                             mz = v$mz_col, rt_min = v$rt_col),
            env = e, prog = prog, bom = isTRUE(v$bom)),
    error = function(err) {
      prog$finish("failed", conditionMessage(err))
      # dmf_input_error 表示"调用方传的东西不对"，退出码必须是 2 而不是 3
      env_set_error(e, if (inherits(err, "dmf_input_error")) "input" else "runtime",
                    conditionMessage(err))
      NULL
    })
  if (is.null(res)) return(e)
  prog$finish("done")

  env_set_params(e, c(list(tol = tol, unit = unit),
                      list(cols = as.list(res$cols$names))))
  env_add_metric(e, "n_rows", res$n_rows)
  env_add_metric(e, "n_ok", res$n_ok)
  env_add_metric(e, "n_ms_files", res$n_files)

  assign(".dmf_keep", list(core = core, res = res), envir = globalenv())
  e
}

cmd_job <- function(p) {
  v <- p$values
  e <- env_new("job", DMF_VERSION, dmf_git_commit())

  if (is.null(v$out)) {
    env_set_error(e, "usage", "缺少 --out", "例：job --out out/msg1")
    return(e)
  }
  out <- util_norm_path(v$out)
  if (!dir.exists(out)) {
    env_set_error(e, "input", sprintf("目录不存在：%s", out))
    return(e)
  }

  snap <- job_snapshot(out)
  if (!isTRUE(snap$found)) {
    env_set_error(e, "input",
                  sprintf("目录里既没有 progress.json 也没有 run.json：%s", out),
                  "作业还没开始写盘，或 --out 指向了别处")
    return(e)
  }

  timed_out <- FALSE
  if (isTRUE(v$wait) && identical(snap$state, "running")) {
    r <- job_wait(out, args_as_num(v$timeout, 1800),
                  args_as_num(v$interval, 2), quiet = isTRUE(v$quiet))
    snap <- r$snap
    timed_out <- isTRUE(r$timed_out)
    if (!isTRUE(v$quiet)) cat("\n", file = stderr())
  }

  env_set_extra(e, "job", snap)
  env_add_metric(e, "state", snap$state)
  env_add_metric(e, "percent", snap$percent)
  env_add_metric(e, "elapsed_s", snap$elapsed_s)

  if (isTRUE(timed_out)) {
    env_set_error(e, "runtime",
                  sprintf("等待超时（%s s），作业仍在运行", v$timeout %||% "1800"),
                  "稍后再查，或调大 --timeout")
  } else if (identical(snap$state, "failed")) {
    env_set_error(e, "runtime", "作业失败", "详见该目录 run.json 的 error 字段")
  }

  if (!isTRUE(v$json)) {
    cat(sprintf("目录   %s\n状态   %s%s\n", out, snap$state,
                if (is.na(snap$percent)) "" else
                  sprintf("（%d%%）", snap$percent)))
    if (!is.na(snap$elapsed_s)) {
      cat(sprintf("耗时   %.1f s\n", snap$elapsed_s))
    }
    if (nzchar(snap$phase %||% "")) {
      cat(sprintf("阶段   %s %s\n", snap$phase, snap$detail %||% ""))
    }
    cat("\n")
  }
  e
}



# ============================================================
# 分发
# ============================================================

COMMANDS <- list(
  version     = list(fn = cmd_version,     spec = spec_version(),
                     desc = "版本与运行环境"),
  doctor      = list(fn = cmd_doctor,      spec = spec_doctor(),
                     desc = "环境自检（合作者第一步）"),
  inspect     = list(fn = cmd_inspect,     spec = spec_inspect(),
                     desc = "检查 xlsx 结构，不运行分析"),
  diff        = list(fn = cmd_diff,        spec = spec_diff(),
                     desc = "A/B 差异筛选 -> 19 个 CSV"),
  `msg-extract` = list(fn = cmd_msg_extract, spec = spec_msg_extract(),
                     desc = "MS1/MS2 抽取 + MSP（MSGeter 第 1 页）"),
  `msg-match` = list(fn = cmd_msg_match,   spec = spec_msg_match(),
                     desc = "峰表匹配 MS2 扫描号 + 导出 MSP（第 2 页）"),
  `rt-apex`   = list(fn = cmd_rt_apex,     spec = spec_rt_apex(),
                     desc = "回原始 MS1 找 apex，重算 RT（第 3 页）"),
  job         = list(fn = cmd_job,         spec = spec_job(),
                     desc = "查询长任务状态 / 等待结束")
)

# 需要放到子进程里跑的命令。
# 实测（R 4.6.0 / Windows，demo_data 全量 56 s、235 MB 输出）：diff 做完、
# run.json 与 JSON 信封都写完之后，R 在进程收尾阶段会 access violation
# （bash 里是 139，cmd.exe 里是 0xC0000005）。同一套流程平铺成脚本跑则不崩，
# 说明与调用栈深度和大对象生命周期有关，不是算法问题。
# 因此把重活放进子进程：父进程只做转发与退出码判定，本身很轻，退出干净。
DMF_HEAVY <- c("diff", "inspect", "msg-extract", "msg-match", "rt-apex")

dmf_extract_out <- function(argv) {
  for (i in seq_along(argv)) {
    if (identical(argv[[i]], "--out") && i < length(argv)) return(argv[[i + 1L]])
    if (grepl("^--out=", argv[[i]])) return(sub("^--out=", "", argv[[i]]))
  }
  NULL
}

run_as_child <- function(argv, cmd) {
  rscript <- if (.Platform$OS.type == "windows") {
    file.path(R.home("bin"), "Rscript.exe")
  } else {
    file.path(R.home("bin"), "Rscript")
  }
  if (!file.exists(rscript)) rscript <- "Rscript"

  out_file <- tempfile("dmf_child_", fileext = ".json")
  on.exit(unlink(out_file), add = TRUE)

  # 注意：不要给 system2() 传 env=。实测在 Windows 上只要带 env 参数，
  # 调用就返回 status 5 且子进程根本没起来；改成本进程先 Sys.setenv，
  # 子进程自然继承。
  Sys.setenv(DMF_CHILD = "1")

  args <- ifelse(grepl(" ", argv, fixed = TRUE),
                 shQuote(argv, type = "cmd"), argv)

  status <- suppressWarnings(tryCatch(
    system2(rscript, c(shQuote(DMF_SCRIPT, type = "cmd"), args),
            stdout = out_file, stderr = ""),
    error = function(e) 3L
  ))

  txt <- if (file.exists(out_file)) {
    readLines(out_file, warn = FALSE, encoding = "UTF-8")
  } else character(0)

  parsed <- if (length(txt) > 0L) {
    tryCatch(jsonlite::fromJSON(paste(txt, collapse = "\n")), error = function(e) NULL)
  } else NULL

  if (is.null(parsed)) {
    out <- dmf_extract_out(argv)
    rj <- if (!is.null(out)) file.path(out, "run.json") else NULL
    if (!is.null(rj) && file.exists(rj)) {
      parsed <- tryCatch(jsonlite::fromJSON(rj), error = function(e) NULL)
    }
  }

  if (length(txt) > 0L) {
    cat(txt, sep = "\n")
  } else if (!is.null(parsed)) {
    cat(as.character(jsonlite::toJSON(parsed, auto_unbox = TRUE, pretty = TRUE,
                                      null = "null", na = "null", digits = NA)), "\n")
  }

  final <- as.integer(status)
  note <- FALSE

  if (!is.null(parsed)) {
    # 信封才是契约：退出码由信封推导，进程状态只用来发现异常。
    final <- if (isTRUE(parsed$ok)) {
      if (length(parsed$warnings) > 0L) DMF_EXIT$warn else DMF_EXIT$ok
    } else {
      ec <- parsed$error$code
      if (identical(ec, "usage")) DMF_EXIT$usage
      else if (identical(ec, "input")) DMF_EXIT$input
      else DMF_EXIT$runtime
    }
    note <- !identical(as.integer(status), as.integer(final))
  } else if (!identical(as.integer(status), 0L)) {
    # 没有信封时（例如纯用法错误，子进程没写 run.json），直接沿用子进程退出码；
    # 只有落在 1..4 之外的（崩溃码）才归一到 3。
    st <- as.integer(status)
    final <- if (st %in% 1:4) st else DMF_EXIT$runtime
    note <- !identical(st, final)
  }

  if (isTRUE(note)) {
    cat(sprintf(paste0("\n[note] R 子进程收尾异常退出（status %s）；",
                       "run.json 与产物完整，按 status=%d 返回。",
                       "这是 R 收尾阶段的已知问题，详见 docs/agent/CLI_CONTRACT.md\n"),
                status, final), file = stderr())
  }

  if (length(txt) == 0L && is.null(parsed) && "--json" %in% argv) {
    e <- env_new(cmd, DMF_VERSION, NA_character_)
    env_set_error(e, "runtime",
                  sprintf("子进程异常退出（status %s），且没有留下 run.json", status),
                  "产物可能不完整，请检查磁盘空间与内存")
    cat(as.character(env_json(e)), "\n")
  }

  final
}

print_toplevel_help <- function() {
  cat("DMetFinder CLI ", DMF_VERSION, "\n\n", sep = "")
  cat("用法：Rscript cli/dmf.R <command> [options]\n\n命令：\n")
  w <- max(nchar(names(COMMANDS))) + 2L
  for (nm in names(COMMANDS)) {
    cat(sprintf("  %-*s%s\n", w, nm, COMMANDS[[nm]]$desc))
  }
  cat("\n每个命令加 --help 查看选项。\n")
}

main <- function() {
  argv <- commandArgs(trailingOnly = TRUE)

  if (length(argv) == 0L || argv[[1L]] %in% c("-h", "--help", "help")) {
    print_toplevel_help()
    return(0L)
  }

  cmd <- argv[[1L]]
  rest <- argv[-1L]

  if (!cmd %in% names(COMMANDS)) {
    e <- env_new(cmd, DMF_VERSION, NA_character_)
    env_set_error(e, "usage", sprintf("未知命令：%s", cmd),
                  sprintf("可用命令：%s", paste(names(COMMANDS), collapse = ", ")))
    cat(env_render(e), "\n")
    return(DMF_EXIT$usage)
  }

  entry <- COMMANDS[[cmd]]

  # 重活交给子进程，父进程只负责转发与退出码（原因见 DMF_HEAVY 注释）
  if (cmd %in% DMF_HEAVY && !nzchar(Sys.getenv("DMF_CHILD"))) {
    return(run_as_child(argv, cmd))
  }

  parsed <- args_parse(rest, entry$spec)

  if (isTRUE(parsed$values$help)) {
    cat(args_usage(cmd, entry$spec, header = sprintf("DMetFinder CLI %s -- %s",
                                                    DMF_VERSION, entry$desc)),
        "\n")
    return(0L)
  }

  if (length(parsed$unknown) > 0L) {
    e <- env_new(cmd, DMF_VERSION, NA_character_)
    hints <- vapply(parsed$unknown, function(u) {
      s <- args_suggest(u, names(entry$spec))
      if (is.na(s)) sprintf("%s 不是已知选项", u)
      else sprintf("%s 不是已知选项，是否想写 --%s ？", u, gsub("_", "-", s))
    }, character(1L))
    env_set_error(e, "usage", paste(hints, collapse = "; "))
    cat(env_render(e), "\n")
    return(DMF_EXIT$usage)
  }
  if (length(parsed$missing_value) > 0L) {
    e <- env_new(cmd, DMF_VERSION, NA_character_)
    env_set_error(e, "usage", sprintf("选项缺少值：%s", paste(parsed$missing_value, collapse = ", ")))
    cat(env_render(e), "\n")
    return(DMF_EXIT$usage)
  }

  e <- tryCatch(
    entry$fn(parsed),
    error = function(err) {
      ee <- env_new(cmd, DMF_VERSION, dmf_git_commit())
      env_set_error(ee, "runtime", conditionMessage(err),
                    "加 --json 查看结构化错误；完整堆栈见 stderr")
      ee
    }
  )

  job_dir <- e$extra$job_dir
  if (!is.null(job_dir) && dir.exists(job_dir)) {
    try(env_write(e, job_dir), silent = TRUE)
  }

  if (isTRUE(parsed$values$json)) {
    cat(as.character(env_json(e)), "\n")
  } else if (!cmd %in% c("doctor", "job")) {
    # doctor 与 job 自己渲染人读文本，避免再套一层信封摘要
    cat(env_render(e), "\n")
  }

  env_exit_code(e)
}

# ---- 收尾 ----------------------------------------------------
# 实测（demo_data，56 s，19 个 CSV + 235 MB）：
#   平铺脚本跑同一流程          -> 退出码 0
#   放进 main()/cmd_diff() 里跑 -> 退出码 139（产物全部完好）
# 差异在于大对象在函数返回后变垃圾，之后仍有大量写盘与哈希。因此 cmd_diff
# 把 res/core 挂到 .dmf_keep 上保留到退出，这里也只清理其余绑定。
# 若将来 R 版本修复了该问题，删掉 .dmf_keep 即可，不影响任何产物。
.dmf_status <- main()
q(save = "no", status = .dmf_status)

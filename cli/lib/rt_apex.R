# ============================================================
# cli/lib/rt_apex.R -- rt-apex：回到原始 MS1 找真实 apex，重算 RT/强度
# ------------------------------------------------------------
# 对应界面：MSGeter › RtGeter（RtGeter_server.R）
# 计算入口 rtg_run_batch() 是完整的顶层函数，签名干净，直接复用。
#
# 唯一需要显式化的是"列怎么认"：界面里 rtg_detect_cols() 认不出四列时会
# 静默回退到"前四列"，在 GUI 上人能立刻看到结果不对，在命令行则会产出一张
# 看起来正常、实际全错的表。所以这里改成：认不出就报错，要求显式指定。
# ============================================================

rta_default_params <- function() {
  list(tol = 10, unit = "ppm")
}

#' 把用户给的列名/列号解析成下标；失败即报错，不回退
rta_resolve_one <- function(core, df, spec, key, fallback) {
  if (is.null(spec) || !nzchar(spec)) {
    if (is.na(fallback)) {
      dmf_stop_input(sprintf(
        "无法自动识别 %s 列。实际列名：%s。用 --%s-col 显式指定。",
        key, paste(names(df), collapse = ", "), key))
    }
    return(as.integer(fallback))
  }
  if (grepl("^[0-9]+$", spec)) {
    idx <- as.integer(spec)
    if (idx < 1L || idx > ncol(df)) {
      dmf_stop_input(sprintf("--%s-col 给的是第 %d 列，但表只有 %d 列",
                             key, idx, ncol(df)))
    }
    return(idx)
  }
  hit <- which(names(df) == spec)
  if (length(hit) == 0L) {
    hit <- which(core$rtg_norm_colname(names(df)) == core$rtg_norm_colname(spec))
  }
  if (length(hit) == 0L) {
    dmf_stop_input(sprintf("--%s-col 指定的列不存在：%s（实际列名：%s）",
                           key, spec, paste(names(df), collapse = ", ")))
  }
  as.integer(hit[1L])
}

#' 补一层别名表。
#' 上游 .rtg_col_alias$rt_min 里没有裸 "rt"（只有 rtmin / rt分钟 / 分钟），
#' 而 "RT" 恰恰是最常见的列名——所以界面版对 (ID, Sample, m/z, RT) 这种表
#' 其实认不全，只是靠"恰好在前四列"蒙对了。命令行不能靠蒙。
.rta_alias <- list(
  id     = c("id", "峰id", "峰编号", "峰序号", "峰号", "peakid", "featureid",
             "peakno", "编号", "序号"),
  sample = c("sample", "样品", "样本", "样品名称", "样本名称", "样品名", "样本名",
             "samplename", "sampleid", "name", "filename", "文件名称"),
  mz     = c("mz", "mz值", "母离子mz", "母离子", "precursormz", "质荷比", "mass"),
  rt_min = c("rt", "rtmin", "rt分钟", "保留时间", "保留时间分钟", "rt值", "分钟")
)

#' 按别名唯一命中解析一列；命中 0 个或多个都返回 NA（歧义不猜）
.rta_pick <- function(nn, keys) {
  h <- which(nn %in% keys)
  if (length(h) == 1L) h else NA_integer_
}

#' 解析四列，返回与 rtg_detect_cols() 同构的 list
rta_cols <- function(core, df, overrides = list()) {
  if (ncol(df) < 4L) {
    dmf_stop_input(sprintf(
      "峰表至少需要 4 列（ID / 样品 / m/z / RT），实际 %d 列：%s",
      ncol(df), paste(names(df), collapse = ", ")))
  }
  auto <- core$rtg_detect_cols(df)
  if (is.null(auto)) {
    dmf_stop_input("峰表列数不足，无法识别 ID/样品/m/z/RT 四列。")
  }

  given <- vapply(overrides[c("id", "sample", "mz", "rt_min")],
                  function(x) !is.null(x) && nzchar(x), logical(1L))

  fallback <- c(id = auto$id, sample = auto$sample,
                mz = auto$mz, rt_min = auto$rt_min)
  by_name <- isTRUE(auto$auto)

  # 上游认不全时，先用自己的别名层再试一次（明确按列名命中，不是按位置）
  if (!by_name) {
    nn <- msm_norm_name(names(df))
    alt <- c(id     = .rta_pick(nn, .rta_alias$id),
             sample = .rta_pick(nn, .rta_alias$sample),
             mz     = .rta_pick(nn, .rta_alias$mz),
             rt_min = .rta_pick(nn, .rta_alias$rt_min))
    if (!anyNA(alt) && !anyDuplicated(alt)) {
      fallback <- alt
      by_name <- TRUE
    }
  }

  # 仍然认不全，且没有把四列全部显式指定 -> 拒绝猜测。
  # 界面上人一眼能看出结果不对，命令行会安静地产出一张全错的表。
  if (!by_name && !all(given)) {
    dmf_stop_input(sprintf(paste0(
      "无法自动识别 峰ID / 样品 / m/z / RT 四列。\n",
      "  实际列名：%s\n",
      "  界面版此时会静默按前四列（%s）处理；命令行不猜，请显式指定：\n",
      "  --id-col --sample-col --mz-col --rt-col"),
      paste(names(df), collapse = ", "),
      paste(names(df)[fallback], collapse = ", ")))
  }

  idx <- c(
    id     = rta_resolve_one(core, df, overrides$id,     "id",     fallback[["id"]]),
    sample = rta_resolve_one(core, df, overrides$sample, "sample", fallback[["sample"]]),
    mz     = rta_resolve_one(core, df, overrides$mz,     "mz",     fallback[["mz"]]),
    rt_min = rta_resolve_one(core, df, overrides$rt_min, "rt",     fallback[["rt_min"]])
  )

  if (anyDuplicated(idx)) {
    dmf_stop_input(sprintf(
      "解析出的四列有重复（%s）。请用 --id-col / --sample-col / --mz-col / --rt-col 逐个指定。",
      paste(names(df)[idx], collapse = ", ")))
  }

  list(id = unname(idx[["id"]]), sample = unname(idx[["sample"]]),
       mz = unname(idx[["mz"]]), rt_min = unname(idx[["rt_min"]]),
       names = c(id = names(df)[idx[["id"]]],
                 sample = names(df)[idx[["sample"]]],
                 mz = names(df)[idx[["mz"]]],
                 rt_min = names(df)[idx[["rt_min"]]]),
       auto = by_name && !any(given))
}

#' 主流程
rta_run <- function(core, table_path, ms_dir, out_dir, prm, overrides = list(),
                    env = NULL, prog = NULL, bom = FALSE) {
  tables_dir <- file.path(out_dir, "tables")
  util_ensure_dir(tables_dir)

  if (!is.null(prog)) prog$set(frac = 0.02, phase = "read", detail = "读取峰表")
  df <- core$rtg_read_table(table_path)
  if (nrow(df) == 0L) {
    dmf_stop_input("峰表里没有数据行：", basename(table_path))
  }

  cols <- rta_cols(core, df, overrides)

  files <- core$rtg_list_ms_files(ms_dir)
  if (nrow(files) == 0L) {
    dmf_stop_input("目录里没有 .raw / .mzML / .mzXML 文件：", ms_dir)
  }
  for (ext in unique(files$ext)) ms_core_check_reader(paste0("x.", ext))

  if (!is.null(prog)) prog$set(frac = 0.05, phase = "apex", detail = "扫描 MS1")

  cb <- function(done, total, detail) {
    if (is.null(prog)) return(invisible(NULL))
    prog$set(frac = 0.05 + 0.90 * done / max(1L, total),
             phase = "apex",
             detail = if (is.null(detail)) "" else detail,
             done = done)
  }

  res <- core$rtg_run_batch(df, cols, files, prm$tol, prm$unit, progress = cb)

  if (!is.null(prog)) prog$set(frac = 0.96, phase = "export", detail = "写结果")

  p1 <- file.path(tables_dir, "01_rt_apex_result.csv")
  csv_write_one(res$result, p1, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", p1, sheet = "rt_apex_result",
                   rows = nrow(res$result), cols = ncol(res$result))
  }

  p2 <- file.path(tables_dir, "02_rt_apex_diag.csv")
  csv_write_one(res$diag, p2, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", p2, sheet = "rt_apex_diag",
                   rows = nrow(res$diag), cols = ncol(res$diag))
  }

  # 状态分布：ok / 未命中 / 各种前置校验失败
  st <- table(res$diag$Status, useNA = "ifany")
  summary <- data.frame(
    status = names(st),
    n = as.integer(st),
    stringsAsFactors = FALSE
  )
  p3 <- file.path(tables_dir, "03_rt_apex_summary.csv")
  csv_write_one(summary, p3, bom)
  if (!is.null(env)) {
    env_add_output(env, "table", p3, sheet = "rt_apex_summary",
                   rows = nrow(summary), cols = ncol(summary))
  }

  log_path <- file.path(out_dir, "rt_apex.log")
  util_atomic_write(log_path, paste(enc2utf8(res$log), collapse = "\n"))
  if (!is.null(env)) env_add_output(env, "log", log_path)

  if (!is.null(prog)) prog$set(frac = 0.99, phase = "export", detail = "完成")

  n_ok <- sum(!is.na(res$diag$RT))
  list(n_rows = nrow(res$diag), n_ok = n_ok, status = st,
       cols = cols, n_files = nrow(files))
}

#!/usr/bin/env Rscript
# ============================================================
# tests/agent/test_msg_equiv.R -- P1 三条命令与界面版算法的等价性验收
# ------------------------------------------------------------
# 目标不是"能跑通"，而是"跑出来的数与界面版一致"。每一项都对着
# shiny_app/server/*.R 里的具体实现比，不比自己。
#
# 用法：
#   Rscript tests/agent/test_msg_equiv.R [项目根]
#
# 需要 tests/agent/fixtures/ 下的夹具（见 tests/agent/README.md）。
# 缺夹具时对应小项报 SKIP 并计入汇总，绝不假装通过。
#
# 关于退出码：R 4.6.0 在 Windows 上处理完大对象后，进程收尾可能 access
# violation（详见 docs/agent/CLI_CONTRACT.md）。这里沿用 CLI 的办法——
# 子进程干活，父进程按"汇总行"判定退出码，否则 CI 会看到一个假的 139。
# ============================================================

.script <- sub("^--file=", "",
               grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1])

# 界面端源文件（shiny_app/server/*.R）里有中文标识符，必须在 UTF-8 locale 下
# 解析；CI / Git Bash 默认 C locale 会直接 parse 失败（报 unexpected invalid
# token）。父进程读子进程输出、按"汇总行"判定退出码也依赖同一 locale，
# 所以这段必须放在最前面，两个进程都要先跑到。
if (!isTRUE(l10n_info()$`UTF-8`)) {
  for (loc in c("Chinese_China.utf8", "Chinese (Simplified)_China.utf8",
                "en_US.UTF-8", "C.UTF-8")) {
    ok <- tryCatch(!is.null(Sys.setlocale("LC_ALL", loc)),
                   error = function(e) FALSE, warning = function(w) FALSE)
    if (ok && isTRUE(l10n_info()$`UTF-8`)) break
  }
}

if (!nzchar(Sys.getenv("DMF_TEST_CHILD"))) {
  rscript <- file.path(R.home("bin"),
                       if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  Sys.setenv(DMF_TEST_CHILD = "1")
  out <- tempfile("dmf_test_", fileext = ".txt")
  status <- suppressWarnings(system2(rscript, c(shQuote(.script), shQuote(".")),
                                     stdout = out, stderr = ""))
  txt <- if (file.exists(out)) readLines(out, warn = FALSE, encoding = "UTF-8") else character(0)
  cat(txt, sep = "\n")
  cat("\n")
  unlink(out)

  summary_line <- grep("^== 汇总：", txt, value = TRUE)
  if (length(summary_line) == 0L) {
    cat(sprintf("[note] 子进程退出码 %s 且没有汇总行；产物可能不完整\n", status))
    quit(save = "no", status = 3L, runLast = FALSE)
  }
  n_fail <- as.integer(sub("^== 汇总：([0-9]+) 通过，([0-9]+) 失败.*$", "\\2",
                           summary_line[1]))
  quit(save = "no", status = if (is.na(n_fail) || n_fail > 0L) 1L else 0L,
       runLast = FALSE)
}

args <- commandArgs(trailingOnly = TRUE)
root <- if (length(args) >= 1L) {
  normalizePath(args[[1L]], winslash = "/", mustWork = TRUE)
} else if (nzchar(.script)) {
  normalizePath(file.path(dirname(.script), "../.."), winslash = "/", mustWork = TRUE)
} else {
  normalizePath(getwd(), winslash = "/")
}

for (m in c("util", "args", "envelope", "csv_out", "progress", "ms_core",
            "msg_extract", "msg_match", "rt_apex")) {
  sys.source(file.path(root, "cli/lib", paste0(m, ".R")), envir = globalenv(),
             keep.source = FALSE)
}

fail <- 0L
ok <- 0L
skip <- 0L

chk <- function(label, cond, detail = "") {
  if (isTRUE(cond)) {
    ok <<- ok + 1L
    cat(sprintf("[PASS] %s\n", label))
  } else {
    fail <<- fail + 1L
    cat(sprintf("[FAIL] %s %s\n", label, detail))
  }
  flush(stdout())
  invisible(NULL)
}

core <- ms_core_load(root, quiet = TRUE)

# ------------------------------------------------------------
# 1. 去卷积：向量化实现 vs 上游 clean_spectrum_keep_max
# ------------------------------------------------------------
cat("\n== 1. 去卷积等价性 ==\n")
set.seed(42)
mk <- function(n, lo, hi, jitter = 0) {
  mz <- sort(runif(n, lo, hi))
  if (jitter > 0) mz <- sort(pmax(mz + rnorm(n, 0, jitter), 1e-6))
  cbind(mz = mz, intensity = runif(n, 1, 1e5))
}
cases <- list(
  sparse  = mk(2000, 100, 1500),
  dense   = mk(50000, 100, 1500),
  crowded = mk(20000, 100, 120, 0.0005),
  narrow  = mk(5000, 60, 62, 0.00001),
  tiny    = mk(300, 100, 1500)
)
for (nm in names(cases)) {
  a <- core$clean_spectrum_keep_max(cases[[nm]], min_mz = 0, max_mz = 1500,
         noise_threshold = 0, min_ms2_difference_in_da = -1,
         min_ms2_difference_in_ppm = 10, max_peak_num = -1,
         normalize_intensity = FALSE)
  b <- msx_clean_fast(cases[[nm]], min_mz = 0, max_mz = 1500, ppm = 10)
  chk(sprintf("clean_spectrum_keep_max == msx_clean_fast（%s，%d 峰 -> %d）",
              nm, nrow(cases[[nm]]), nrow(a)),
      identical(dim(a), dim(b)) &&
        isTRUE(all.equal(unname(a), unname(b), tolerance = 0)))
}
rm(cases)
invisible(gc(verbose = FALSE))

# ------------------------------------------------------------
# 2. 夹具上的 MS1 表：快/慢两条去卷积路径必须给出同一张表
# ------------------------------------------------------------
cat("\n== 2. MS1 分钟桶（夹具） ==\n")
fx_dir <- file.path(root, "tests/agent/fixtures/ms")
fx <- if (dir.exists(fx_dir)) {
  list.files(fx_dir, pattern = "\\.(mzml|mzxml|raw)$", full.names = TRUE,
             ignore.case = TRUE)
} else character(0)

if (length(fx) == 0L) {
  skip <- skip + 1L
  cat("[SKIP] 没有夹具：", fx_dir, "\n",
      "       生成：msconvert <file>.mzML --mzML --outfile slice.mzML",
      " --filter \"index 1350-1700\"\n", sep = "")
} else {
  f <- fx[[1L]]
  ms_core_check_reader(f)
  ms <- core$read_ms_file(f)
  prm <- msx_default_params()
  prm$rt_min <- 0; prm$rt_max <- 100
  sid <- ms_core_sample_id(f)

  t0 <- Sys.time()
  fast <- msx_ms1_table(core, ms$scan_table, ms$spectra, prm, sid, slow = FALSE)
  t_fast <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  t0 <- Sys.time()
  slow <- msx_ms1_table(core, ms$scan_table, ms$spectra, prm, sid, slow = TRUE)
  t_slow <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  chk(sprintf("快/慢去卷积的 MS1 表逐元素相同（%d 行 vs %d 行）",
              nrow(fast), nrow(slow)),
      identical(dim(fast), dim(slow)) &&
        isTRUE(all.equal(fast, slow, tolerance = 0, check.attributes = FALSE)))
  cat(sprintf("       fast %.1f s / slow %.1f s（%.0f 倍）\n",
              t_fast, t_slow, t_slow / max(t_fast, 0.01)))

  # ---- 2b. 界面端 RT_apex 接回逻辑 == CLI 快路径 ----
  # FeatureGeter_server.R 里：分钟桶堆叠时带上 rt_scan，去卷积只喂 mz/intensity
  # 两列（上游实现会强行改列名），再按 (mz, intensity) 把扫描 RT 接回来。
  # 这里是那段的原样复刻，用来锁住"界面版输出的 RT_apex 与 CLI 一致"。
  st2 <- ms$scan_table
  merged_chunks <- list()
  for (i in seq_len(nrow(st2))) {
    if (st2$msLevel[i] != 1) next
    spec <- ms$spectra[[as.character(st2$scan[i])]]
    if (is.null(spec) || is.null(spec$mz) || length(spec$mz) == 0) next
    label <- as.character(floor(as.numeric(st2$StartTime[i])))
    d <- data.frame(mz = spec$mz, intensity = spec$intensity,
                    rt_scan = as.numeric(st2$StartTime[i]))
    merged_chunks[[label]][[length(merged_chunks[[label]]) + 1L]] <- d
  }
  merged_centroids <- lapply(merged_chunks, dplyr::bind_rows)

  gui_list <- list()
  for (label in names(merged_centroids)) {
    peaks <- merged_centroids[[label]]
    if (nrow(peaks) < 2L) next
    cleaned_mat <- core$clean_spectrum_keep_max(
      as.matrix(peaks[, c("mz", "intensity")]),
      min_mz = 0, max_mz = 1500, noise_threshold = 0,
      min_ms2_difference_in_da = -1,
      min_ms2_difference_in_ppm = prm$ppm,
      max_peak_num = -1, normalize_intensity = FALSE
    )
    cleaned_df <- as.data.frame(cleaned_mat)
    colnames(cleaned_df) <- c("mz", "intensity")
    cleaned_df <- cleaned_df[cleaned_df$intensity > prm$min_intensity, , drop = FALSE]
    if (nrow(cleaned_df) > 0L) {
      key_out <- paste(cleaned_df$mz, cleaned_df$intensity, sep = "|")
      key_in  <- paste(peaks$mz, peaks$intensity, sep = "|")
      cleaned_df$RT_apex <- peaks$rt_scan[match(key_out, key_in)]
    } else {
      cleaned_df$RT_apex <- numeric(0)
    }
    cleaned_df$RT <- as.numeric(label) + 1
    gui_list[[label]] <- cleaned_df
  }

  keep_bins <- intersect(ceiling(prm$rt_min):floor(prm$rt_max),
                         as.integer(names(gui_list)))
  gui_tab <- do.call(rbind, gui_list[as.character(sort(keep_bins))])
  gui_tab$mz <- round(gui_tab$mz, 4)
  gui_tab$intensity <- round(gui_tab$intensity, 0)
  gui_tab$RT_apex <- round(gui_tab$RT_apex, 4)
  cli_tab <- fast[, c("RT", "mz", "intensity", "RT_apex")]
  gui_tab <- gui_tab[, c("RT", "mz", "intensity", "RT_apex")]
  rownames(gui_tab) <- NULL; rownames(cli_tab) <- NULL
  chk(sprintf("界面端 RT_apex 接回逻辑 == CLI（%d 行，apex RT 中位 %.4f）",
              nrow(gui_tab), median(gui_tab$RT_apex, na.rm = TRUE)),
      identical(dim(gui_tab), dim(cli_tab)) &&
        isTRUE(all.equal(gui_tab, cli_tab, tolerance = 0, check.attributes = FALSE)))
  cat(sprintf("       RT_apex 缺失 %d 行；与桶号 RT 的差中位 %.4f min\n",
              sum(is.na(gui_tab$RT_apex)),
              median(gui_tab$RT_apex - gui_tab$RT, na.rm = TRUE)))
  rm(merged_chunks, merged_centroids, gui_list, gui_tab, cli_tab, st2, d)

  # MS2 表：对着界面里那段 dplyr 管道重写一遍做参照
  st <- ms$scan_table
  ref <- st |>
    dplyr::filter(msLevel == 2) |>
    dplyr::arrange(ms2_value) |>
    dplyr::mutate(
      group = {
        v <- ms2_value
        g <- numeric(length(v))
        cur <- 1
        fv <- which(!is.na(v))
        thr <- if (length(fv) > 0L) v[fv[1]] + 0.9 else Inf
        for (i in seq_along(v)) {
          if (!is.na(v[i]) && v[i] > thr) { cur <- cur + 1; thr <- v[i] + 0.9 }
          g[i] <- cur
        }
        g
      },
      Sample = sid
    ) |>
    dplyr::select(scan, StartTime, scanType, ms2_value, group, Sample) |>
    as.data.frame()

  mine <- msx_ms2_table(st, sid, gap = 0.9)
  chk(sprintf("MS2 分组表与界面管道一致（%d 行）", nrow(ref)),
      identical(dim(ref), dim(mine)) &&
        isTRUE(all.equal(ref, mine, tolerance = 0, check.attributes = FALSE)))

  # 谱图是本节最大的对象，后面不再用，先放掉（否则退出阶段更容易崩）
  rm(ms, fast, slow, ref, mine, st)
  invisible(gc(verbose = FALSE))
}

# ------------------------------------------------------------
# 3. MSP 读取：自己写的 vs 上游 readMSP（后者依赖 stringr）
# ------------------------------------------------------------
cat("\n== 3. MSP 读取等价性 ==\n")
msp_dir <- file.path(root, "out/msg1/ms2_msp")
msp_files <- if (dir.exists(msp_dir)) list.files(msp_dir, "\\.msp$", full.names = TRUE)
if (length(msp_files) == 0L) {
  skip <- skip + 1L
  cat("[SKIP] 没有 msp 文件：先跑一次 msg-extract（见 tests/agent/README.md）\n")
} else if (!util_has_pkg("stringr")) {
  skip <- skip + 1L
  cat("[SKIP] 未安装 stringr，无法调用上游 readMSP 做对照\n")
} else {
  f <- msp_files[[1L]]
  a <- core$readMSP(f)
  b <- msm_msp_read(f)
  chk(sprintf("msm_msp_read == readMSP（%s，%d 张谱）", basename(f), length(a)),
      identical(names(a), names(b)) && isTRUE(all.equal(a, b, tolerance = 0)))
}

# ------------------------------------------------------------
# 4. 扫描号匹配：自己写的 vs 上游 matchScan（data.table NSE）
# ------------------------------------------------------------
cat("\n== 4. 扫描号匹配等价性 ==\n")
info_path <- file.path(root, "out/msg1/tables/01_MS2_Group_Info.csv")
feat_path <- file.path(root, "tests/agent/fixtures/peaks.csv")
if (!file.exists(info_path) || !file.exists(feat_path)) {
  skip <- skip + 1L
  cat("[SKIP] 缺少 ", info_path, " 或 ", feat_path, "\n", sep = "")
} else {
  all_ms2 <- data.table::fread(info_path, data.table = TRUE)
  feat <- data.table::fread(feat_path, data.table = FALSE)

  cols <- msm_resolve_cols(feat)
  mine <- msm_match(feat, as.data.frame(all_ms2), cols, mz_tol = 0.01)

  # matchScan() 有两条隐含契约，参照调用必须照它期待的输入准备：
  #   1) 样品列名写死为小写 sample，否则 demo_ms2$sample 是 NULL，
  #      Sample == NULL 直接报 "RHS of == is length 0"；
  #   2) 结尾的 demo_ms2[!is.na(scan)] 依赖 data.table 的 NSE，传 data.frame
  #      会把 scan 解析成 base::scan 函数，静默退化成"全部未匹配 + 警告"。
  # CLI 这边由 msm_resolve_cols() 显式解析列、用普通 data.frame 计算。
  feat_ref <- data.table::as.data.table(feat)
  names(feat_ref)[names(feat_ref) == "Sample"] <- "sample"
  ref <- core$matchScan(feat_ref, data.table::copy(all_ms2), mz_tol = 0.01)

  chk(sprintf("匹配结果与 matchScan 一致（双方命中 %d / %d 行）",
              sum(!is.na(mine$scan)), nrow(ref)),
      sum(!is.na(mine$scan)) == nrow(ref) &&
        identical(as.numeric(ref$scan),
                  as.numeric(mine$scan[!is.na(mine$scan)])))
  rm(all_ms2, feat, feat_ref, ref, mine)
  invisible(gc(verbose = FALSE))
}

# ------------------------------------------------------------
# 5. rt-apex 列解析：歧义必须报错，不许静默取前四列
# ------------------------------------------------------------
cat("\n== 5. rt-apex 列解析 ==\n")
df_ok <- data.frame(ID = "a", Sample = "s", `m/z` = 100, RT = 3,
                    check.names = FALSE, stringsAsFactors = FALSE)
cols <- rta_cols(core, df_ok)
chk("能按别名认出 ID/Sample/m/z/RT",
    identical(unname(unlist(cols[c("id", "sample", "mz", "rt_min")])),
              c(1L, 2L, 3L, 4L)))

df_bad <- data.frame(A = "a", B = "s", C = 100, D = 3, stringsAsFactors = FALSE)
bad <- tryCatch({ rta_cols(core, df_bad); NULL }, error = function(e) conditionMessage(e))
chk("认不出时抛错（而不是静默回退到前四列）", !is.null(bad))

# ------------------------------------------------------------
cat(sprintf("\n== 汇总：%d 通过，%d 失败，%d 跳过 ==\n", ok, fail, skip))
flush(stdout())
invisible(gc(verbose = FALSE))
quit(save = "no", status = if (fail > 0L) 1L else 0L, runLast = FALSE)

# ============================================================
# cli/lib/doctor.R -- 环境自检
# ------------------------------------------------------------
# 合作者第一件事就是跑这个。每条检查都给出明确的"怎么修"，而不是
# 只报一个 FALSE。
# ============================================================

doctor_check <- function(name, status, detail, fix = NA_character_) {
  list(name = name, status = status, detail = detail, fix = fix)
}

doctor_run <- function(root) {
  checks <- list()
  add <- function(...) checks[[length(checks) + 1L]] <<- doctor_check(...)

  # ---- R 版本 ----
  rv <- paste(R.version$major, R.version$minor, sep = ".")
  rnum <- as.numeric(R.version$major) + as.numeric(strsplit(R.version$minor, "\\.")[[1L]][1L]) / 100
  if (rnum >= 4.03) {
    add("R 版本", "ok", rv)
  } else {
    add("R 版本", "fail", sprintf("%s（需 >= 4.3）", rv),
        "升级 R：https://cloud.r-project.org/")
  }

  # ---- 必装包（P0：diff / inspect / 信封） ----
  need_p0 <- c("openxlsx", "readxl", "digest", "jsonlite", "data.table")
  installed <- util_installed_pkgs()
  for (p in need_p0) {
    if (p %in% installed) {
      v <- tryCatch(as.character(utils::packageVersion(p)), error = function(e) "?")
      add(sprintf("包 %s", p), "ok", v)
    } else {
      add(sprintf("包 %s", p), "fail", "未安装",
          sprintf('install.packages("%s")', p))
    }
  }

  # ---- 选装包（P1：MSGeter 需要） ----
  # mzR 读 .mzML/.mzXML；rawrr 读 .raw；stringr 只在 .raw 路径里被上游
  # read_ms_file() 用来解析扫描类型。三者缺任何一个都只影响对应格式。
  opt <- list(
    mzR = list(why = "msg-extract / rt-apex 读 .mzML/.mzXML",
               fix = 'BiocManager::install("mzR")'),
    rawrr = list(why = "msg-extract / rt-apex 读 .raw",
                 fix = 'BiocManager::install("rawrr")（还需 .NET Runtime）'),
    stringr = list(why = "上游 read_ms_file() 读 .raw 时用",
                   fix = 'install.packages("stringr")')
  )
  for (p in names(opt)) {
    if (p %in% installed) {
      add(sprintf("包 %s（选装）", p), "ok", "已安装")
    } else {
      add(sprintf("包 %s（选装）", p), "warn",
          paste0("未安装，", opt[[p]]$why, " 不可用"), opt[[p]]$fix)
    }
  }

  # ---- 项目文件 ----
  for (rel in DMF_CORE_FILES) {
    if (file.exists(file.path(root, rel))) {
      add(sprintf("文件 %s", rel), "ok", "存在")
    } else {
      add(sprintf("文件 %s", rel), "fail", "缺失", "确认在 DMetFinder 根目录下运行")
    }
  }

  # ---- 输出可写 ----
  tmp <- file.path(tempdir(), "dmf_doctor")
  if (util_can_write(tmp)) {
    add("临时目录可写", "ok", tmp)
  } else {
    add("临时目录可写", "fail", tmp, "检查磁盘空间与权限")
  }
  unlink(tmp, recursive = TRUE)

  # ---- 编码 ----
  enc <- l10n_info()
  utf8 <- isTRUE(enc$`UTF-8`)
  add("UTF-8 区域设置", if (utf8) "ok" else "warn",
      sprintf("UTF-8=%s, Latin-1=%s", utf8, isTRUE(enc$`Latin-1`)),
      if (utf8) NA_character_ else
        "Windows 控制台请先执行 chcp 65001；run-dmf.bat 已自动处理")

  # ---- sha256 可用性 ----
  probe <- file.path(tempdir(), "dmf_sha_probe.txt")
  writeLines("probe", probe)
  h <- util_sha256(probe)
  unlink(probe)
  if (!is.na(h) && nchar(h) == 64L) {
    add("sha256", "ok", substr(h, 1, 16))
  } else {
    add("sha256", "fail", "无法计算（digest 异常）", 'install.packages("digest")')
  }

  status <- vapply(checks, function(c) c$status, character(1L))
  list(
    checks = checks,
    ok = !any(status == "fail"),
    n_fail = sum(status == "fail"),
    n_warn = sum(status == "warn")
  )
}

doctor_render <- function(res) {
  icon <- c(ok = "[ok]  ", warn = "[warn]", fail = "[FAIL]")
  # 按显示宽度补空格：中文占两列，sprintf 的 %-Ns 按字符数算，会歪。
  # 宽度取 30：最长的一项 "文件 R/dmetfinder_functions.R" 是 28 列。
  pad <- function(x, n = 30L) {
    x <- as.character(x)
    paste0(x, strrep(" ", pmax(0L, n - nchar(x, type = "width"))))
  }
  lines <- vapply(res$checks, function(c)
    sprintf("%s %s %s", icon[[c$status]], pad(c$name), c$detail), character(1L))
  fixes <- vapply(res$checks, function(c) {
    if (is.null(c$fix) || length(c$fix) == 0L || is.na(c$fix)) NA_character_
    else as.character(c$fix)[[1L]]
  }, character(1L))
  fixes <- fixes[!is.na(fixes)]
  fix_lines <- if (length(fixes) > 0L) c("", "修复建议：", sprintf("       -> %s", fixes)) else NULL
  c(lines, fix_lines,
    "", sprintf("结论：%s（%d 项失败，%d 项警告）",
                if (isTRUE(res$ok)) "可以运行" else "需要修复",
                res$n_fail, res$n_warn))
}

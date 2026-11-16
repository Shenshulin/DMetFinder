## 验证 rtg_file_logger：脱离 shiny 直接调用
e <- new.env()

# 项目根：从根目录运行时就是 getwd()；用 Rscript tests/xxx.R 运行时
# 反推脚本自身的上一级。路径不要写死成某台机器的绝对路径。
.dmf_root <- function() {
  if (file.exists("app.R")) return(normalizePath(getwd()))
  a <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(a)) {
    p <- normalizePath(sub("^--file=", "", a[1]), mustWork = FALSE)
    return(dirname(dirname(p)))
  }
  getwd()
}
rtg_src <- file.path(.dmf_root(), "shiny_app", "server", "RtGeter_server.R")

owd <- setwd(tempdir())
source(rtg_src, local = e, encoding = "UTF-8")
cat("objects:", length(ls(e)), " has logger:", exists("rtg_file_logger", envir = e), "\n")

lg <- e$rtg_file_logger()
lg(c("[10:00:01] 第一行", "[10:00:02] 第二行"))
lg("[10:00:03] 第三行")
d <- file.path(".workbuddy", "logs", "rgeter")
cat("files:", paste(list.files(d, full.names = TRUE), collapse = " | "), "\n")
f <- list.files(d, full.names = TRUE)[1]
cat("--- 内容 ---\n")
cat(readLines(f, warn = FALSE), sep = "\n")
cat("\n--- 行数:", length(readLines(f, warn = FALSE)), "---\n")
setwd(owd)

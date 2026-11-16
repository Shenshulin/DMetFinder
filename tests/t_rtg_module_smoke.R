## RtGeter 模块冒烟测试：确认改过的 server（日志落盘 + Save log 下载器）
## 在 testServer 里能正常构建 session，不抛错。
suppressPackageStartupMessages({
  library(shiny); library(DT); library(shinyWidgets)
})

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
owd <- setwd(.dmf_root())
on.exit(setwd(owd), add = TRUE)

source("shiny_app/server/RtGeter_server.R", encoding = "UTF-8")

ok <- tryCatch({
  testServer(RtGeter_server, {
    cat("session 建立成功，输出对象数:", length(names(output)), "\n")
  }, args = list(id = "RtGeter"))
  TRUE
}, error = function(e) {
  cat("FAILED:", conditionMessage(e), "\n"); FALSE
})
cat(if (ok) "SMOKE OK\n" else "SMOKE FAIL\n")

## RtGeter 模块冒烟测试：确认改过的 server（日志落盘 + Save log 下载器）
## 在 testServer 里能正常构建 session，不抛错。
suppressPackageStartupMessages({
  library(shiny); library(DT); library(shinyWidgets)
})
owd <- setwd("D:/ms_soft/DMetFinder")
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

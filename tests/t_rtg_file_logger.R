## 验证 rtg_file_logger：脱离 shiny 直接调用
e <- new.env()
owd <- setwd(tempdir())
source("D:/ms_soft/DMetFinder/shiny_app/server/RtGeter_server.R", local = e, encoding = "UTF-8")
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

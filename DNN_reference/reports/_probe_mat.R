invisible(suppressWarnings(Sys.setlocale("LC_ALL","Chinese (Simplified)_China.utf8")))
suppressPackageStartupMessages(library(rhdf5))
f <- "source_data/EDML_trainTestCalData15.mat"
cat("== file:", f, "==\n")
h5ls(f, all = TRUE)
cat("\n== 顶层对象 ==\n")
top <- h5ls(f, recursive = FALSE)
print(top[, c("name","otype","dclass","dim")])

# ============================================================
# tools/run_web.R -- start the DMetFinder / MSGeter Shiny app
# ============================================================
# Usage (from the project root):
#     Rscript tools/run_web.R            # default port 7788
#     Rscript tools/run_web.R 3838       # pick another port
#
# Runs app.R unchanged; this file only supplies the port / host so the
# address is predictable. Logs go to the console, so redirect when
# starting it in the background.
# ============================================================

args <- commandArgs(trailingOnly = TRUE)

port <- if (length(args) >= 1L && nzchar(args[1])) {
  as.integer(args[1])
} else {
  7788L
}
if (is.na(port) || port < 1024L || port > 65535L) {
  stop("port must be an integer between 1024 and 65535", call. = FALSE)
}

host <- if (length(args) >= 2L && nzchar(args[2])) args[2] else "127.0.0.1"

root <- getwd()
if (!file.exists(file.path(root, "app.R"))) {
  stop("app.R not found in ", root, " -- run this from the project root",
       call. = FALSE)
}

message("[run_web] root = ", root)
message("[run_web] http://", host, ":", port)
message("[run_web] started at ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))

# launch.browser = FALSE: the caller decides how to open the page, and a
# background start should not pop a browser it cannot manage.
shiny::runApp(
  appDir         = root,
  port           = port,
  host           = host,
  launch.browser = FALSE,
  quiet          = TRUE
)

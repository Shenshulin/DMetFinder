# ============================================================
# Main Server
# ============================================================

server <- function(input, output, session) {

  # 断线自动重连。
  # Shiny 默认不允许恢复：浏览器与服务端的 WebSocket 一断（标签页被系统挂起、
  # 笔记本休眠唤醒、Chrome 回收后台标签），页面就永久停在灰罩上，只能手动刷新；
  # 而手刷会新建 session，已上传的峰表 / 已跑出的结果全部丢。
  # 打开这个开关后客户端会自己重连，服务端进程还活着时能拿回原 session。
  session$allowReconnect(TRUE)

  # ============ DMetFinder Server ============
  dmetfinder_server(input, output, session)
  
  # ============ MSGeter Server ============
  FeatureGeter_server("FeatureGeter")
  Ms2Geter_server("Ms2Geter")
  RtGeter_server("RtGeter")

  # ============ Peak Quality Server ============
  peak_quality_server("PeakQuality")
}
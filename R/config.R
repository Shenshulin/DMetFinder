# ============================================================
# DMetFinder Default Configuration Parameters (corresponds to DMetFinder.app.cfg.json)
# ============================================================
default_config <- list(
  ErrorRange = 0.002,           # Ion matching error range
  ErrorRangeInGroups = 0.003,   # Within-group matching error range
  FloatCount = 7,               # Number of decimal places for floating point numbers
  NullCellValue = 0,            # Null cell value
  countRange = c(1, 3, 5, 10),  # Count scoring ranges
  countValue = c(10, 3, 2, 1),  # Count scoring values
  intensityRange = c(0, 5000, 10000, 50000, 100000, 500000, 1000000),  # Intensity scoring ranges
  intensityValue = c(1, 2, 5, 6, 8, 9, 10),  # Intensity scoring values
  m1 = 1.00335,                 # M+1 isotope mass difference
  m2 = 2.0067,                  # M+2 isotope mass difference
  m3 = 3.01005,                 # M+3 isotope mass difference
  mergeRows = FALSE,            # Whether to merge duplicate rows
  p50IonPercent = 0.5,          # 50% filter threshold
  p80IonPercent = 0.8,          # 80% filter threshold
  relativeIntensityRange1 = c(0, 1, 2, 3, 4, 5),
  relativeIntensityRange2 = c(0, 2, 3, 4, 5),
  relativeIntensitySplit = 5,
  relativeIntensityValue1 = c(0.5, 1, 2, 3, 5, 10),
  relativeIntensityValue2 = c(1, 2, 3, 5, 10),
  # 50% 离子打分是原版独立的一套打分表（p50IntensityRange… 等），
  # 默认值与全离子那套完全相同，界面上未单独暴露时沿用这里的值。
  p50IntensityRange = c(0, 5000, 10000, 50000, 100000, 500000, 1000000),
  p50IntensityValue = c(1, 2, 5, 6, 8, 9, 10),
  p50RelativeIntensitySplit = 5,
  p50RelativeIntensityRange1 = c(0, 1, 2, 3, 4, 5),
  p50RelativeIntensityValue1 = c(0.5, 1, 2, 3, 5, 10),
  p50RelativeIntensityRange2 = c(0, 2, 3, 4, 5),
  p50RelativeIntensityValue2 = c(1, 2, 3, 5, 10),
  p50CountRange = c(1, 3, 5, 10),
  p50CountValue = c(10, 3, 2, 1),
  # 同一离子在自己窗口（±ErrorRange，同一 RT 桶）里对同一样品命中多个质心时取哪一个：
  #   "max"   取强度最大者（默认）。一条特征被切成多支 m/z 时选支不再抖动，
  #           组内 CV 与定量准确率都明显更好（TOF 基准 QAR 45.2% -> 78.9%）；
  #   "first" 取原始下标最小者，即原版 Java 的「同一样品先到先得」，复现原版用。
  MatrixPick = "max",
  # 组内匹配时额外施加的时间容差（分钟）。
  #   0   = 只用原版键「同一整数分钟桶 + ±ErrorRange」；
  #   >0  = 改为「±ErrorRange 且 apex RT 相差不超过该值」，需要 Ms1Geter
  #        输出 RT_apex 列。1 min 桶会把跨桶 / 多支的同一条离子拆开，
  #        放行后这部分会被重新归到一起，组内 CV 与定量准确率显著变好。
  ClusterRtTol = 0.3
)

# ============================================================
# UI switches
# ============================================================
# Peak Quality module visibility.
# FALSE -> the tab is not added to the navbar and its server is not attached;
#           every source() and the whole R/peak_quality/ tree stay in place, so
#           flipping this to TRUE restores the module with no other change.
ui_show_peak_quality <- FALSE
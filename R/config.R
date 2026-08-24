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
  relativeIntensityValue2 = c(1, 2, 3, 5, 10)
)
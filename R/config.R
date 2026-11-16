# ============================================================
# DMetFinder Default Configuration Parameters (corresponds to DMetFinder.app.cfg.json)
# ============================================================
default_config <- list(
  # ---- Unit of the mass tolerance ----
  # "ppm" (default): the tolerance is converted to Da per ion from that ion's own
  #   m/z, tol_i = mz_i * ppm * 1e-6. The same ppm value maps to a different
  #   absolute window width at different m/z, which is what mass accuracy
  #   actually behaves like (absolute error grows with m/z).
  # "Da": a fixed absolute tolerance, i.e. the convention of the original Java
  #   implementation. Reproducing old results, or comparing cell by cell against
  #   another implementation, requires switching to this unit together with
  #   ErrorRange = 0.002 / ErrorRangeInGroups = 0.003.
  #
  # Why the default had to change: on the demo data the old fixed 0.002 Da is
  #   equivalent to 19 ppm at the low-m/z end (p1 = 105) -- far too wide, it
  #   merges neighbouring but distinct ions; and to only 2 ppm at the high-m/z
  #   end (p95 = 990) -- far too narrow, so one feature breaks apart as soon as
  #   its mass drifts. With ppm both ends agree and the criterion no longer
  #   shifts systematically with m/z.
  ErrorRangeUnit = "ppm",
  ErrorRange = 5,               # Ion matching error range (unit: see above)
  ErrorRangeInGroups = 10,      # Within-group matching error range (unit: see above)
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
  # 50% ion scoring uses its own score table in the original implementation
  # (p50IntensityRange etc.). The defaults are identical to the all-ion table,
  # and these values apply whenever the UI does not expose them separately.
  p50IntensityRange = c(0, 5000, 10000, 50000, 100000, 500000, 1000000),
  p50IntensityValue = c(1, 2, 5, 6, 8, 9, 10),
  p50RelativeIntensitySplit = 5,
  p50RelativeIntensityRange1 = c(0, 1, 2, 3, 4, 5),
  p50RelativeIntensityValue1 = c(0.5, 1, 2, 3, 5, 10),
  p50RelativeIntensityRange2 = c(0, 2, 3, 4, 5),
  p50RelativeIntensityValue2 = c(1, 2, 3, 5, 10),
  p50CountRange = c(1, 3, 5, 10),
  p50CountValue = c(10, 3, 2, 1),
  # When the same ion hits more than one centroid for the same sample inside its
  # own window (+/- ErrorRange, same RT bin), which one to take:
  #   "max"   take the most intense one (default). When one feature is split into
  #           several m/z branches the chosen branch stops flickering, and both
  #           within-group CV and quantitative accuracy improve markedly
  #           (TOF benchmark QAR 45.2% -> 78.9%);
  #   "first" take the smallest original row index, i.e. the original Java rule
  #           of "first come, first served per sample". Use this to reproduce
  #           the original implementation.
  MatrixPick = "max",
  # Extra retention-time tolerance applied during within-group matching (minutes).
  #   0   = use only the original key "same integer minute bin + +/- ErrorRange";
  #   >0  = use "+/- ErrorRange AND apex RT differs by no more than this value",
  #         which requires the RT_apex column written by Ms1Geter. A 1-minute bin
  #         splits one ion that crosses bin boundaries or has several branches;
  #         letting those through re-merges them, and within-group CV and
  #         quantitative accuracy improve substantially.
  ClusterRtTol = 0.3,
  # ---- Verdict thresholds for the "merged" differential-ion table ----
  # (only affect the third merged sheet, no other output)
  # Rules for the Verdict column of the merged table:
  #   ion count of one group = 0                              -> A only / B only
  #   P < PValueThreshold and fold >= FoldChangeThreshold      -> Higher in A
  #   P < PValueThreshold and fold <= 1/FoldChangeThreshold    -> Higher in B
  #   otherwise                                                -> No change
  FoldChangeThreshold = 2,
  PValueThreshold = 0.05
)

# ============================================================
# UI switches
# ============================================================
# Peak Quality module visibility.
# FALSE -> the tab is not added to the navbar and its server is not attached;
#           every source() and the whole R/peak_quality/ tree stay in place, so
#           flipping this to TRUE restores the module with no other change.
ui_show_peak_quality <- FALSE
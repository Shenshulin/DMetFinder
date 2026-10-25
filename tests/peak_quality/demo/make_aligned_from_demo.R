# Build an MS-DIAL-aligned-shaped demo table from the already derived features
# (same real m/z and RT, but ONE ROW PER FEATURE, no sample column).
d <- utils::read.csv("G:/method_ms2/MSDIAL_TEST/peak_quality_demo_features.csv",
                     stringsAsFactors = FALSE)
u <- unique(d[, c("feature_id", "mz", "rt")])
al <- data.frame(`Alignment ID`    = seq_len(nrow(u)),
                 `Average Rt(min)` = u$rt,
                 `Average Mz`      = u$mz,
                 `Metabolite name` = paste0("demo_", seq_len(nrow(u))),
                 check.names = FALSE)
utils::write.csv(al, "G:/method_ms2/MSDIAL_TEST/peak_quality_demo_aligned.csv",
                 row.names = FALSE)
cat("aligned rows:", nrow(al), "\n")
print(al)

# ============================================================
# Test 04: peak-table reading, column mapping, sample matching
# ============================================================
# Covers: CSV / TSV / XLSX reading, MZmine- and MS-DIAL-style headers,
# RT seconds -> minutes conversion, invalid rows, duplicate rows,
# manual sample maps, and five sample<->file matching outcomes.
# ============================================================

args_full <- commandArgs(trailingOnly = FALSE)
this_file <- sub("^--file=", "", args_full[grep("^--file=", args_full)])
here <- if (length(this_file) == 1) dirname(normalizePath(this_file)) else getwd()
source(file.path(here, "helpers.R"))

ROOT <- normalizePath(file.path(here, "../.."), winslash = "/")
pq_source_project(ROOT)
source(file.path(here, "fixtures/make_fixtures.R"))

fx <- pq_fixture_make(file.path(tempdir(), "pq_fix_table"))

pq_section("column-name guessing is only a suggestion")
mz_cols <- names(pq_fixture_features_mzmine())
g1 <- pq_guess_mapping(mz_cols)
pq_assert_equal(g1$feature_id, "row ID", "MZmine: 'row ID' -> feature_id")
pq_assert_equal(g1$mz, "row m/z", "MZmine: 'row m/z' -> mz")
pq_assert_equal(g1$rt, "row retention time", "MZmine: 'row retention time' -> rt")
pq_assert_equal(g1$sample_id, "", "MZmine: no sample column -> empty mapping")

msd_cols <- names(pq_fixture_features_msdial())
g2 <- pq_guess_mapping(msd_cols)
pq_assert_equal(g2$feature_id, "Alignment ID", "MS-DIAL: 'Alignment ID' -> feature_id")
pq_assert_equal(g2$mz, "Average Mz", "MS-DIAL: 'Average Mz' -> mz")
pq_assert_equal(g2$rt, "Average Rt(min)", "MS-DIAL: 'Average Rt(min)' -> rt")

pq_assert_equal(pq_guess_mapping(c("mz", "rt", "feature_id", "sample_id"))$mz, "mz",
                "canonical headers map to themselves")

pq_section("CSV / TSV / XLSX reading")
df_csv <- pq_read_table(fx$features_min)
pq_assert(nrow(df_csv) == 10 && "mz" %in% names(df_csv), "CSV read")

tsv <- file.path(tempdir(), "pq_t.tsv")
utils::write.table(pq_fixture_features("min"), tsv, sep = "\t", row.names = FALSE)
pq_assert(nrow(pq_read_table(tsv)) == 10, "TSV read (tab detected)")

xlsx <- file.path(tempdir(), "pq_t.xlsx")
writexl::write_xlsx(pq_fixture_features("min"), xlsx)
pq_assert(nrow(pq_read_table(xlsx)) == 10, "XLSX read")

pq_section("standardisation and RT units")
mapping <- list(feature_id = "feature_id", mz = "mz", rt = "rt",
                sample_id = "sample_id", area = "", height = "", polarity = "",
                charge = "", software = "", original_id = "")
s_min <- pq_standardize_features(pq_fixture_features("min"), mapping, "min")
pq_assert(length(s_min$errors) == 0, "no validation error for a valid table")
pq_assert(nrow(s_min$ok) == 10, "all 10 rows accepted")
pq_assert_equal(s_min$ok$rt_min[1], 6.00, "RT minutes kept as-is")

s_sec <- pq_standardize_features(pq_fixture_features("sec"), mapping, "sec")
pq_assert_equal(s_sec$ok$rt_min[1], 6.00, "RT seconds converted to minutes (360 s -> 6 min)")
pq_assert_equal(s_sec$ok$rt_input[1], 360, "original RT value preserved for the report")

pq_section("validation rejects bad rows instead of guessing")
bad_df <- data.frame(feature_id = c("A", "A", "", "C", "D"),
                     mz = c(300, 300, 400, NA, 500),
                     rt = c(6, 6.1, 7, 8, -1),
                     sample_id = c("S1", "S1", "S1", "S1", "S1"),
                     stringsAsFactors = FALSE)
s_bad <- pq_standardize_features(bad_df, mapping, "min")
pq_assert(nrow(s_bad$ok) == 1, "only the single valid row survives")
pq_assert(nrow(s_bad$bad) == 4, "four rows reported as rejected")
pq_assert(any(grepl("feature_id is empty", s_bad$bad$reason)), "empty id reported")
pq_assert(any(grepl("mz is missing", s_bad$bad$reason)), "missing mz reported")
pq_assert(any(grepl("rt is missing or negative", s_bad$bad$reason)), "negative rt reported")
pq_assert(any(grepl("duplicated", s_bad$bad$reason)), "duplicate feature x sample reported")

pq_section("missing required mapping is a hard error")
s_err <- pq_standardize_features(pq_fixture_features("min"),
                                 list(feature_id = "feature_id", mz = "", rt = "rt"),
                                 "min")
pq_assert(length(s_err$errors) > 0, "unmapped mz -> error, not silent skip")
pq_assert_contains(s_err$errors, "mz", "error names the missing field")

pq_section("sample <-> file matching")
files <- c("/data/S1.mzML", "/data/S2.mzML", "/data/Sample_S3_final.mzXML")
m <- pq_match_samples(c("S1", "S2", "S3", "S9"), files)
pq_assert_equal(m$match[m$sample_id == "S1"], "exact", "exact name match")
pq_assert_equal(m$match[m$sample_id == "S2"], "exact", "second exact match")
pq_assert_equal(m$match[m$sample_id == "S3"], "contains",
                "sample id contained in the file name")
pq_assert_equal(m$match[m$sample_id == "S9"], "none", "unknown sample reported as none")
pq_assert_equal(m$n_candidates[m$sample_id == "S9"], 0L, "no candidate counted")

m_amb <- pq_match_samples(c("S"), files)
pq_assert_equal(m_amb$match[1], "ambiguous", "ambiguous prefix reported as ambiguous")
pq_assert_equal(m_amb$n_candidates[1], 3L, "three candidates counted")

manual <- data.frame(sample_id = "S9", file = "S2.mzML", stringsAsFactors = FALSE)
m_man <- pq_match_samples(c("S9"), files, manual)
pq_assert_equal(m_man$match[1], "manual", "manual override accepted")
pq_assert_contains(m_man$file[1], "S2.mzML", "manual override resolves the file")

map_csv <- file.path(tempdir(), "pq_map.csv")
write.csv(data.frame(sample_id = "S9", file = "S1.mzML"), map_csv, row.names = FALSE)
mm <- pq_read_sample_map(map_csv)
pq_assert(nrow(mm) == 1 && mm$sample_id == "S9", "manual map file parsed")

ok <- pq_summary()
if (!ok) quit(save = "no", status = 1)

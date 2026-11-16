## Integration test: the "merged" differential-ion table -- the union of the two
## group tables, one ion per row.
##
## Covered:
##   1. Row set = A80 U B80, nothing lost and nothing duplicated
##      (shared + A-only = |A80|, shared + B-only = |B80|)
##   2. All five Verdict branches are hit exactly once: higher in A, higher in B,
##      A only, B only, no change
##   3. Fold change: recorded as 0 when either side has an ion count of 0, so no
##      division by zero
##   4. Header row length equals the number of data columns (otherwise the sheet
##      is written shifted by a whole block)
##   5. After writing, the workbook really holds 3 sheets and the merged table is
##      the last one
suppressWarnings(source("R/config.R", encoding = "UTF-8"))
suppressWarnings(source("R/dmetfinder_functions.R", encoding = "UTF-8"))

samples_a <- c("11", "12", "13", "14", "15")
samples_b <- c("21", "22", "23", "24", "25")

mk <- function(rt, mz, avg, count, b_avg, b_count, s1, s2, i1, i2) {
  data.frame(rt = rt, mz = mz, avg = avg, count = count,
             b_avg = b_avg, b_count = b_count, a_b = NA_real_,
             score_one = s1, score_avg = s2, stringsAsFactors = FALSE)
}

## ---- Group A: four 80% ions ----
a_rt <- c(2, 2, 2, 2)
a_mz <- c(100.0000, 200.0000, 300.0000, 400.0000)
a_avg <- c(100, 400, 500, 100)
a_cnt <- c(5, 5, 5, 5)
a_bavg <- c(200, 100, 0, 100)      # the third one is absent from group B
a_bcnt <- c(5, 5, 0, 5)
a_i1 <- rbind(c(90, 100, 110, 100, 100),
              c(400, 410, 390, 405, 395),
              c(500, 510, 490, 505, 495),
              c(100, 105, 95, 102, 98))
a_i2 <- rbind(c(190, 200, 210, 200, 200),
              c(100, 102, 98, 101, 99),
              c(0, 0, 0, 0, 0),
              c(100, 103, 97, 101, 99))

diff_ab <- mk(a_rt, a_mz, a_avg, a_cnt, a_bavg, a_bcnt, 30, 40, a_i1, a_i2)
diff_ab$idx <- 1:4
diff_ab$no_int <- 11L
diff_ab$rt_mz <- 1000 + a_mz
diff_ab$inten1 <- a_i1
diff_ab$inten2 <- a_i2
diff_ab$b_rt <- c(2, 2, NA, 2)
diff_ab$rt_no_mz <- 11000 + a_mz
diff_ab$b_rt_mz <- c(1100.0001, 1200.0001, NA, 1400.0001)
diff_ab$m1_iso <- 0; diff_ab$m2_iso <- 0; diff_ab$m3_iso <- 0

## A1->B1, A2->B2, A3->none, A4->B3
cmp_ab <- data.frame(idx = 1:4, b_idx = c(1L, 2L, NA_integer_, 3L))

## ---- Group B: four 80% ions (the fourth one has no partner in group A) ----
diff_ba <- mk(c(2, 2, 2, 2), c(100.0001, 200.0001, 400.0001, 500.0000),
              c(200, 100, 100, 300), c(5, 5, 5, 5),
              c(100, 400, 100, 0), c(5, 5, 5, 0),
              35, 45, NULL, NULL)
diff_ba$idx <- 1:4
diff_ba$no_int <- 21L
diff_ba$rt_mz <- 1000 + diff_ba$mz
diff_ba$inten1 <- rbind(c(190, 200, 210, 200, 200), c(100, 102, 98, 101, 99),
                        c(100, 103, 97, 101, 99), c(300, 310, 290, 305, 295))
diff_ba$inten2 <- rbind(c(90, 100, 110, 100, 100), c(400, 410, 390, 405, 395),
                        c(100, 105, 95, 102, 98), c(0, 0, 0, 0, 0))
diff_ba$b_rt <- c(2, 2, 2, NA)
diff_ba$rt_no_mz <- 21000 + diff_ba$mz
diff_ba$b_rt_mz <- c(1100.0000, 1200.0000, 1400.0000, NA)
diff_ba$m1_iso <- 0; diff_ba$m2_iso <- 0; diff_ba$m3_iso <- 0

cmp_ba <- data.frame(idx = 1:4, b_idx = c(1L, 2L, 4L, NA_integer_))

## ---- Minimal stand-ins for the group results (only the fields dmf_score_at() reads) ----
fake_group <- function(rt, mz, samples) {
  ions <- data.frame(rt_mz = 1000 + mz, mz = mz, rt = rt, stringsAsFactors = FALSE)
  list(sample_names = samples,
       ions = ions,
       p80_idx = seq_along(mz),
       p50_ions = data.frame(rt_mz = 1000 + mz, stringsAsFactors = FALSE),
       p50_score = list(total = seq_along(mz) * 10,
                        avg_score_by_rt = seq_along(mz) * 5))
}
ga <- fake_group(a_rt, a_mz, samples_a)
gb <- fake_group(rep(2, 4), c(100.0001, 200.0001, 400.0001, 500), samples_b)

cfg <- dmf_merge_config(list(FoldChangeThreshold = 2, PValueThreshold = 0.05))
u <- dmf_union_diff(diff_ab, cmp_ab, diff_ba, cmp_ba, ga, gb, cfg)
stopifnot(!is.null(u))

d <- u$df
cat("merged rows:", nrow(d),
    " source:", paste(names(table(d$src)), table(d$src), sep = "=", collapse = ", "), "\n")
cat("verdict:", paste(names(table(d$tag)), table(d$tag), sep = "=", collapse = ", "), "\n")

## 1. The union neither loses nor duplicates a row
stopifnot(nrow(d) == 5L)
stopifnot(sum(d$src == "Shared") == 3L)
stopifnot(sum(d$src == "A 80% only") == 1L)
stopifnot(sum(d$src == "B 80% only") == 1L)
stopifnot(sum(d$src == "Shared") + sum(d$src == "A 80% only") == nrow(diff_ab))
stopifnot(sum(d$src == "Shared") + sum(d$src == "B 80% only") == nrow(diff_ba))
stopifnot(!any(duplicated(paste(d$rt, round(d$mz, 3)))))

## 2. Each of the five Verdict branches appears exactly once
for (tg in c("Higher in A", "Higher in B", "A only", "B only", "No change")) {
  if (sum(d$tag == tg) != 1L) stop("wrong number of rows for verdict: ", tg)
}

## 3. Fold change: 0 when one side is absent, otherwise A/B
r_a_hi <- d$a_b[d$tag == "Higher in A"]; stopifnot(abs(r_a_hi - 4) < 1e-6)
r_b_hi <- d$a_b[d$tag == "Higher in B"]; stopifnot(abs(r_b_hi - 0.5) < 1e-6)
stopifnot(all(d$a_b[d$tag %in% c("A only", "B only")] == 0))

## 4. Header length == number of data columns
sh <- .dmf_sheet_diff_merged("Group A", "Group B", u, samples_a, samples_b)
n_col <- length(sh$cols)
cat("columns:", n_col,
    " header row length:", paste(vapply(sh$header, length, integer(1)), collapse = "/"), "\n")
stopifnot(all(vapply(sh$header, length, integer(1)) == n_col))
stopifnot(all(vapply(sh$cols, length, integer(1)) == nrow(d)))

## 5. After writing there are exactly 3 sheets and the merged table is the last one
f <- file.path(tempdir(), "diff_union.xlsx")
dmf_write_sheets(list(.dmf_sheet_diff("Group A", "Group B", " 80%", diff_ab, samples_a, samples_b),
                      .dmf_sheet_diff("Group B", "Group A", " 80%", diff_ba, samples_b, samples_a),
                      sh), f)
ex <- file.path(tempdir(), "diff_union_unzip")
unlink(ex, recursive = TRUE); dir.create(ex)
utils::unzip(f, exdir = ex)
wbx <- paste(readLines(file.path(ex, "xl", "workbook.xml"), warn = FALSE), collapse = "")
nm <- regmatches(wbx, gregexpr('name="[^"]*"', wbx))[[1]]
nm <- sub('^name="', "", sub('"$', "", nm))
cat("sheets:", paste(nm, collapse = " | "), "\n")
stopifnot(length(nm) == 3L, grepl("merged ions", nm[3]))

## 6. Empty input returns NULL (no empty table, so no extra empty sheet in the xlsx)
stopifnot(is.null(dmf_union_diff(NULL, data.frame(), NULL, data.frame(), ga, gb, cfg)))

cat("\nOK: row set, verdict branches, fold-change rule, header alignment and sheet order all pass.\n")

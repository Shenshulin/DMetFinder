# ============================================================
# DMetFinder core algorithms
# ------------------------------------------------------------
# This file is a faithful port of the original Java program DMetFinder.exe
# (corvida.core.*).
#
# Basis for parity: the decompiled source of the embedded jar recovered from
# the exe4j overlay. Key classes:
#   corvida.core.io.AnalysisIonListener   (data reading, key construction)
#   corvida.core.collection.impl.IonsManager2 / Helper (window search, dedup.)
#   corvida.core.calc.IonCalculator       (filtering, scoring, isotopes,
#                                          cross-group comparison)
#   corvida.core.utils.BigDecimalHelper / CalcTools (precision, score semantics)
#
# Fundamental differences from the earlier R implementation, which was a
# simplified approximation and produced results off by orders of magnitude:
#   1. The ion object carries two concatenated keys, noMz and rtNoMz. In the
#      original every deduplication and scoring step is built on those two
#      keys; the old version had neither.
#   2. After the 50% / 80% threshold filter, distinctIons() must run again
#      (at most two rounds). The old version skipped this step.
#   3. count / averageIntensity are aggregated by MatrixRow keyed on sample
#      number (duplicate hits inside one sample are deduplicated first, then
#      averaged). The old version expanded per reference sample and counted
#      afterwards, which is a different convention.
#   4. 50% ion scoring and all-ion scoring are two independent score tables
#      (the latter has both a noMz and an rtMz dimension). The old version
#      implemented only one simplified 5-column score.
#
# Numeric semantics reproduce BigDecimal with double:
#   truncate(x)  = (x + 1e-10) truncated toward zero to 8 decimals
#   divideD(a,b) = a / b rounded half up (HALF_UP) to FloatCount (= 7) digits
# The window search reproduces Helper.binarySearch: the window is the open
# interval [target-e+1e-9, target+e-1e-9], hits come back in ascending order of
# the original row index, and findIon takes the first of them.
# ============================================================


# ============================================================
# 0. Constants (identical to the original literals)
# ============================================================

# fixOffset inside Helper.binarySearch = new BigDecimal("0.000000001")
.dmf_fix_offset <- 1e-9
# BigDecimalHelper.TRUNCATE_NUMBER = new BigDecimal("0.0000000001")
.dmf_truncate_num <- 1e-10
# setScale(8, DOWN) of BigDecimalHelper.truncate
.dmf_truncate_scale <- 1e8


# ============================================================
# 0b. Mass tolerance: the two units, Da and ppm
# ============================================================
# The original Java tolerance is a fixed 0.002 Da, which is unrealistic on real
# data: mass error in MS is roughly proportional to m/z, so a fixed Da window is
# relatively too wide at low m/z and too narrow at high m/z. In ppm mode the
# tolerance is converted from each ion's own m/z:
#     tol_i = mz_i * ppm * 1e-6
# so "how wide the match is" stays the same across the whole m/z range.
#
# In the implementation, Da mode still returns a **scalar** and
# window_bounds / argmin_in_window take the original path written to reproduce
# BigDecimal, not one character changed; ppm mode returns a vector as long as
# the ion table and takes .dmf_window_bounds_vec(). The two paths are kept
# independent on purpose: reproducing the original requires the Da path
# exactly, and any "convenient unification" breaks cell-by-cell parity.

#' Convert the configured tolerance into a per-row tolerance in Da
#'
#' @param mz ion m/z vector (one-to-one with the later target)
#' @param value tolerance value, unit given by \code{unit}
#' @param unit "ppm" or "Da"; case-insensitive, any other value means "Da"
#' @return with unit = "ppm" a numeric vector of length length(mz) holding the
#'   per-row Da tolerance; with unit = "Da" a length-1 numeric, preserving the
#'   scalar semantics of the original path
.dmf_tol_da <- function(mz, value, unit) {
  unit <- if (is.null(unit) || !length(unit)) "Da" else as.character(unit)[1L]
  val <- as.numeric(value)[1L]
  if (is.na(val) || !is.finite(val) || val <= 0) {
    stop("Mass tolerance must be a positive finite number, got: ", value)
  }
  if (identical(tolower(unit), "ppm")) {
    as.numeric(mz) * (val * 1e-6)
  } else {
    val
  }
}

#' Whether the tolerance takes the per-row (ppm) path
.dmf_vec_tol <- function(unit) {
  unit <- if (is.null(unit) || !length(unit)) "Da" else as.character(unit)[1L]
  identical(tolower(unit), "ppm")
}



# ============================================================
# 1. BigDecimal numeric semantics
# ============================================================

#' Reproduce BigDecimalHelper.truncate: add 1e-10, then truncate toward zero to
#' 8 decimals.
#'
#' The subtlety: the original BigDecimal is the **exact decimal expansion** of the
#' double (the semantics of new BigDecimal(double)), not the shortest round-trip
#' form. The actual double for 81132.26642 is 81132.266419999898..., and adding
#' 1e-10 still does not cross 81132.26642, so the original truncates to
#' 81132.26641999. Doing the +1e-10 arithmetic in double instead rounds the sum up
#' to the next double (= 81132.26642) and truncation yields a different value. So
#' we take a 20-decimal fixed-point string and decide in the decimal domain: the
#' part from the 9th decimal onward is rest, and rest + 0.01 >= 1 means adding
#' 1e-10 carries.
#'
#' @param x numeric vector (|x| < 9e15)
#' @return numeric vector with 8 decimal places
dmf_truncate <- function(x) {
  if (length(x) == 0L) return(numeric(0))
  out <- rep(NA_real_, length(x))
  ok <- !is.na(x)
  if (!any(ok)) return(out)
  if (any(abs(x[ok]) >= 9e15)) stop("Value exceeds the fixed-point range of truncate")

  ax <- abs(x[ok])
  # 19-digit integer part (zero padded) + '.' + 20 decimals: width 40, fixed
  s <- sprintf("%040.20f", ax)
  ip <- as.numeric(substr(s, 1L, 19L))
  f8 <- as.numeric(substr(s, 21L, 28L))
  rest <- as.numeric(substr(s, 29L, 40L)) / 1e12
  carry <- as.numeric(rest + 0.01 >= 1)
  v <- ip + (f8 + carry) / .dmf_truncate_scale
  v[x[ok] < 0] <- -v[x[ok] < 0]
  out[ok] <- v
  out
}

#' Vectorised BigDecimal.divide(..., digits, RoundingMode.HALF_UP)
#'
#' R's round()/sprintf() both use banker's rounding (round half to even), so
#' 13.23828125 to 7 decimals gives 13.2382812 while the original HALF_UP wants
#' 13.2382813. We expand to digits + 9 decimals and test by hand whether digit
#' digits+1 is >= 5 before carrying.
#' @param a,b numeric vectors (recycled)
#' @param digits decimal places, defaults to config$FloatCount
dmf_divide <- function(a, b, digits = 7L) {
  if (any(b == 0, na.rm = TRUE)) {
    stop("divideD divisor is 0: the original throws ArithmeticException here, ",
         "check the intensity used by the scoring statistics")
  }
  d <- as.integer(digits)
  q <- a / b
  out <- rep(NA_real_, length(q))
  ok <- !is.na(q)
  if (!any(ok)) return(out)

  s <- sprintf(paste0("%.", d + 9L, "f"), abs(q[ok]))
  ip <- sub("\\..*$", "", s)
  fr <- sub("^[^.]*\\.", "", s)
  keep <- substr(fr, 1L, d)
  up <- as.integer(substr(fr, d + 1L, d + 1L)) >= 5L
  v <- as.numeric(paste0(ip, ".", keep))
  if (any(up)) v[up] <- v[up] + 10^(-d)
  neg <- q[ok] < 0
  if (any(neg)) v[neg] <- -v[neg]
  out[ok] <- v
  out
}

#' CalcTools.Score: scan backwards for the first v >= range[i], return
#' scores[i], otherwise 0.
#'
#' range must be ascending; when several intervals match, the largest index wins
#' (the original scans in reverse).
#' @param v numeric vector
#' @param range ascending interval lower bounds
#' @param scores score values, same length as range
dmf_score <- function(v, range, scores) {
  if (length(range) != length(scores)) {
    stop("Score ranges and score values differ in length ",
         "(the original config validation rejects this too)")
  }
  idx <- findInterval(v, range)
  out <- numeric(length(v))
  hit <- !is.na(idx) & idx > 0L
  if (any(hit)) out[hit] <- scores[idx[hit]]
  out
}

#' Equivalent of BigDecimal.toString() for the integer case (used to build the
#' no / rt strings)
#' @param x numeric vector, all values must be integers
dmf_integer_string <- function(x) {
  if (any(is.na(x))) stop("Sample number / retention time is missing, ",
                          "cannot build the concatenated key the original requires")
  if (any(x != round(x))) {
    stop("The original builds the RT&No&m/z key by string concatenation ",
         "(rt.toString() + no + mz), which requires both RT and sample number ",
         "to be integers. The current data has non-integer values, so the ",
         "original would throw NumberFormatException here. Round RT first.")
  }
  if (any(abs(x) >= 1e15)) stop("Sample number / retention time exceeds the ",
                                "range of representable integers")
  sprintf("%.0f", x)
}

#' Split a fixed 8-decimal string into integer part + fraction * 1e8
#'
#' The assembled rt&no&mz key reaches 1e8, where the 8th decimal is no longer
#' reliable in double (ulp about 3e-8). The original compares exactly with
#' BigDecimal, so the key is split into two exact integers and the window
#' boundary test happens in the integer domain.
#'
#' @param s character vector of digits with an optional minus sign and dot
#' @param scale number of decimals, default 8 (same scale as dmf_truncate)
#' @return list(ip = integer part, f8 = fraction scaled by 10^scale as an integer)
dmf_decimal_parts <- function(s, scale = 8L) {
  if (length(s) == 0L) return(list(ip = numeric(0), f8 = numeric(0)))
  scale <- as.integer(scale)
  if (any(is.na(s))) stop("Decimal string is empty, cannot be split")

  neg <- startsWith(s, "-")
  body <- ifelse(neg, substring(s, 2L), s)
  ip_s <- sub("\\..*$", "", body)
  fr_s <- ifelse(grepl("\\.", body, fixed = FALSE),
                 sub("^[^.]*\\.", "", body), "")
  if (any(nchar(fr_s) > scale)) {
    stop("Decimal string has more than ", scale,
         " decimals, cannot be represented exactly as an integer")
  }
  fr_s <- gsub(" ", "0", sprintf(paste0("%-", scale, "s"), fr_s),
               fixed = TRUE)
  ip <- suppressWarnings(as.numeric(ip_s))
  f8 <- suppressWarnings(as.numeric(fr_s))
  if (any(is.na(ip)) || any(is.na(f8))) stop("Failed to parse decimal string")
  sign <- ifelse(neg, -1, 1)
  list(ip = ip * sign, f8 = f8 * sign)
}


# ============================================================
# 2. Window search (reproducing Helper.binarySearch + IonsManager2.findIons)
# ============================================================

#' Open-interval index bounds of each target inside an ascending key array
#'
#' The original window is targetMin = target - error + 1e-9 and
#' targetMax = target + error - 1e-9, and a key is a hit when key > targetMin
#' and key < targetMax.
#'
#' Note: concatenated keys such as `rt&no&m/z` reach 1e8, where the double ulp
#' (3e-8) is already larger than the original fixOffset (1e-9), so a boundary
#' computed straight from error wrongly admits a neighbour that differs by
#' exactly error. With `exact = TRUE` we switch to "coarse prefilter plus exact
#' boundary test in decimal integers (unit 1e-8)", which matches the BigDecimal
#' comparison.
#'
#' @param sorted_key ascending numeric vector
#' @param target vector of query values
#' @param error tolerance (ErrorRange or ErrorRangeInGroups)
#' @param exact use the exact decimal boundary test (mandatory once the key
#'   magnitude exceeds 1e7)
#' @param offset constant added to the query value during comparison (for
#'   example the 1.00335 isotope shift). In exact mode offset is not added to
#'   target; instead key - target is compared with offset, so the target + offset
#'   step cannot introduce another double rounding.
#' @param key_parts,target_parts results of dmf_decimal_parts() (integer part
#'   plus 8 decimals). When supplied the comparison runs in the integer domain,
#'   which is required once the key magnitude exceeds 1e7.
#' @param vec_tol TRUE means error is a **per-row tolerance as long as target**
#'   (ppm mode), handled by .dmf_window_bounds_vec(). FALSE (the default) keeps
#'   the original scalar semantics, i.e. the path that reproduces the original,
#'   with nothing changed.
#' @return list(lo, hi), closed-interval indices; lo > hi means no hit
dmf_window_bounds <- function(sorted_key, target, error, exact = FALSE, offset = 0,
                              key_parts = NULL, target_parts = NULL,
                              vec_tol = FALSE) {
  if (isTRUE(vec_tol)) {
    return(.dmf_window_bounds_vec(sorted_key, target, error, offset,
                                  key_parts = key_parts,
                                  target_parts = target_parts))
  }
  guard <- error - .dmf_fix_offset
  if (guard <= 0) stop("Mass tolerance must be greater than 1e-9 (the original fixOffset)")
  if (!isTRUE(exact)) {
    return(list(
      lo = findInterval(target + offset - guard, sorted_key) + 1L,
      hi = findInterval(target + offset + guard, sorted_key, left.open = TRUE)
    ))
  }

  # ---- Coarse prefilter: widened by 1e-6, far above the ulp of a 1e-8 key, so nothing is missed ----
  n <- length(sorted_key)
  q <- length(target)
  lo <- rep(1L, q)
  hi <- rep(0L, q)
  if (n == 0L || q == 0L) return(list(lo = lo, hi = hi))

  tgt <- target + offset
  pad <- 1e-6
  c_lo <- findInterval(tgt - (error + pad), sorted_key) + 1L - 4L
  c_hi <- findInterval(tgt + (error + pad), sorted_key, left.open = TRUE) + 4L
  c_lo <- pmin(pmax(c_lo, 1L), n + 1L)
  c_hi <- pmin(pmax(c_hi, 0L), n)

  id <- which(c_lo <= c_hi)
  if (!length(id)) return(list(lo = lo, hi = hi))

  len <- c_hi[id] - c_lo[id] + 1L
  qidx <- rep.int(id, len)
  pos <- sequence(len, from = c_lo[id])

  # Both key and target carry 8 decimals, so multiplying by 1e8 gives integers;
  # key - target is exact (Sterbenz), the only error comes from each double
  # representation, and for key magnitudes < 3.4e7 it stays below 0.5, so
  # rounding reproduces the original BigDecimal difference.
  e8 <- round(error * .dmf_truncate_scale)
  if (abs(error * .dmf_truncate_scale - e8) > 1e-6) {
    stop("Mass tolerance must be a multiple of 1e-8 (the original compares exactly in decimal)")
  }
  off8 <- round(offset * .dmf_truncate_scale)
  if (!is.null(key_parts) && !is.null(target_parts)) {
    # Integer domain: integer-part difference * 1e8 + fraction difference, all exact integers
    delta <- (key_parts$ip[pos] - target_parts$ip[qidx]) * .dmf_truncate_scale +
      (key_parts$f8[pos] - target_parts$f8[qidx]) - off8
  } else {
    # key - target is exact (Sterbenz); the only error comes from each double
    # representation, and for key magnitudes < 3.4e7 it stays below 0.5, so
    # rounding reproduces the original BigDecimal difference.
    delta <- round((sorted_key[pos] - target[qidx]) * .dmf_truncate_scale) - off8
  }
  keep <- delta >= (1 - e8) & delta <= (e8 - 1)
  qidx <- qidx[keep]
  pos <- pos[keep]
  if (!length(qidx)) return(list(lo = lo, hi = hi))

  first <- !duplicated(qidx)
  last <- !duplicated(qidx, fromLast = TRUE)
  lo[qidx[first]] <- pos[first]
  hi[qidx[last]] <- pos[last]
  list(lo = lo, hi = hi)
}

#' Per-row tolerance window test (ppm mode only)
#'
#' Exactly one thing differs from dmf_window_bounds(exact = TRUE): the tolerance
#' becomes a vector as long as target instead of a scalar, and the test
#'     |key - (target + offset)| < tol_i - 1e-9
#' runs pairwise against each target's own tol_i. Because tol varies with m/z a
#' single findInterval cannot finish the scan, so the prefilter is widened to
#' max(tol) and the expanded candidate pairs are then filtered exactly in the
#' integer domain -- nothing missed, nothing extra admitted.
#'
#' Accuracy: delta is in units of 1e-8 and comes from "integer-part difference
#' plus fraction difference" (exact integers when key_parts is supplied), while
#' tol is left unconverted. A ppm tolerance is not a multiple of 1e-8 to begin
#' with, so forcing it to one would only introduce a fixed bias.
#'
#' @inheritParams dmf_window_bounds
#' @return list(lo, hi), same as dmf_window_bounds
.dmf_window_bounds_vec <- function(sorted_key, target, error, offset = 0,
                                   key_parts = NULL, target_parts = NULL) {
  n <- length(sorted_key)
  q <- length(target)
  lo <- rep(1L, q)
  hi <- rep(0L, q)
  if (n == 0L || q == 0L) return(list(lo = lo, hi = hi))

  error <- as.numeric(error)
  if (length(error) != q) {
    stop("Per-row tolerance length (", length(error),
         ") must match the target length (", q, ")")
  }
  guard <- error - .dmf_fix_offset
  if (anyNA(guard) || any(!is.finite(guard))) {
    stop("Mass tolerance contains NA / non-finite values, cannot evaluate the window")
  }
  if (any(guard <= 0)) {
    stop("Mass tolerance must be greater than 1e-9 (the original fixOffset); ",
         "the smallest value is ", format(min(error), digits = 6),
         ", which is too small for the m/z in this snapshot")
  }

  # ---- Coarse prefilter: widened to the global widest tolerance + 1e-6 so nothing is missed; extra candidates are dropped exactly below ----
  tgt <- target + offset
  pad <- 1e-6
  emax <- max(guard)
  c_lo <- findInterval(tgt - (emax + pad), sorted_key) + 1L - 4L
  c_hi <- findInterval(tgt + (emax + pad), sorted_key, left.open = TRUE) + 4L
  c_lo <- pmin(pmax(c_lo, 1L), n + 1L)
  c_hi <- pmin(pmax(c_hi, 0L), n)

  id <- which(c_lo <= c_hi)
  if (!length(id)) return(list(lo = lo, hi = hi))

  len <- c_hi[id] - c_lo[id] + 1L
  qidx <- rep.int(id, len)
  pos <- sequence(len, from = c_lo[id])

  off8 <- round(offset * .dmf_truncate_scale)
  if (!is.null(key_parts) && !is.null(target_parts)) {
    delta <- (key_parts$ip[pos] - target_parts$ip[qidx]) * .dmf_truncate_scale +
      (key_parts$f8[pos] - target_parts$f8[qidx]) - off8
  } else {
    delta <- round((sorted_key[pos] - target[qidx]) * .dmf_truncate_scale) - off8
  }

  # delta is in units of 1e-8; the open interval as the integer form of |delta| < tol*1e8 - 1e-1
  e8 <- guard[qidx] * .dmf_truncate_scale
  keep <- delta >= (1 - e8) & delta <= (e8 - 1)
  qidx <- qidx[keep]
  pos <- pos[keep]
  if (!length(qidx)) return(list(lo = lo, hi = hi))

  first <- !duplicated(qidx)
  last <- !duplicated(qidx, fromLast = TRUE)
  lo[qidx[first]] <- pos[first]
  hi[qidx[last]] <- pos[last]
  list(lo = lo, hi = hi)
}

#' Take the "smallest index" element in the window (what findIon returns first)
#'
#' The original packs the hit set into a TreeMap<original index, Ion>, so get(0)
#' is the smallest original index. A sparse table answers range-minimum queries
#' in O(1) here: (rank, position) is encoded into one number, and taking the
#' minimum compares rank first and position second. rank must be unique, which
#' makes the result identical to an element-wise scan.
#' @param sorted_key ascending key
#' @param target query values
#' @param error tolerance
#' @param rank original indices, same length as sorted_key (all distinct)
#' @param exact whether the window boundary uses the exact decimal test
#' @param offset constant added during comparison (see dmf_window_bounds)
#' @param key_parts,target_parts exact decimal decomposition of the key
#'   (see dmf_window_bounds)
#' @param vec_tol whether error is a per-row tolerance (see dmf_window_bounds)
#' @return integer vector of hit positions in sorted_key; NA when nothing matched
dmf_argmin_in_window <- function(sorted_key, target, error, rank, exact = FALSE,
                                 offset = 0, key_parts = NULL,
                                 target_parts = NULL, vec_tol = FALSE) {
  n <- length(sorted_key)
  out <- rep(NA_integer_, length(target))
  if (n == 0L || length(target) == 0L) return(out)

  b <- dmf_window_bounds(sorted_key, target, error, exact = exact, offset = offset,
                         key_parts = key_parts, target_parts = target_parts,
                         vec_tol = vec_tol)
  ok <- b$lo <= b$hi
  if (!any(ok)) return(out)

  # Encoding: enc = rank * K + position; K > n makes decoding unambiguous; the maximum is about n*2^20 < 2^53
  K <- 2^ceiling(log2(n + 1))
  enc <- rank * K + seq_len(n)

  lo <- b$lo[ok]
  hi <- b$hi[ok]
  len <- hi - lo + 1L
  max_len <- max(len)

  # Sparse table: level j covers 2^(j-1) elements
  levels <- list(enc)
  step <- 1L
  while (step * 2 <= max_len) {
    prev <- levels[[length(levels)]]
    nxt <- pmin(prev, c(prev[(step + 1L):n], rep(Inf, step)))
    levels[[length(levels) + 1L]] <- nxt
    step <- step * 2L
  }

  j <- floor(log2(len)) + 1L
  m <- rep(Inf, length(len))
  for (jj in sort(unique(j))) {
    sel <- j == jj
    span <- 2^(jj - 1)
    m[sel] <- pmin(levels[[jj]][lo[sel]], levels[[jj]][hi[sel] - span + 1L])
  }
  out[ok] <- as.integer(m %% K)
  out
}

#' Sum by group, aligned to a length-n vector by group number (empty groups are 0)
.dmf_group_sum <- function(x, group, n) {
  rs <- rowsum(x, group, reorder = TRUE)
  out <- numeric(n)
  out[as.integer(rownames(rs))] <- as.numeric(rs)
  out
}

#' Recursive form of Helper.binarySearch (no tolerance, exact key match; mergeDiff)
#'
#' Reproduced line by line with 0-based indices: a key equal to mid returns
#' immediately, so when several elements share a key the one returned is not
#' necessarily the first, and the caller must still expand the equal-key range
#' backwards. That is what the original does; it is kept as is rather than
#' "corrected".
#' @return 1-based index
dmf_bsearch_java <- function(sorted_key, target) {
  n <- length(sorted_key)
  lo0 <- 0L
  hi0 <- n - 1L
  repeat {
    if (lo0 == hi0) return(lo0 + 1L)
    if (target < sorted_key[lo0 + 1L]) return(lo0 + 1L)
    if (target > sorted_key[hi0 + 1L]) return(hi0 + 1L)
    if (hi0 - lo0 == 1L) return(lo0 + 1L)
    mid <- (lo0 + hi0) %/% 2L
    if (target == sorted_key[mid + 1L]) return(mid + 1L)
    if (target < sorted_key[mid + 1L]) hi0 <- mid else lo0 <- mid
  }
}


# ============================================================
# 3. Data reading (AnalysisIonListener + IoHelper.ReadSamples)
# ============================================================

#' Read the raw-data Excel of one group
#'
#' Layout: six columns per sample (Sample(No), RT, RT&m/z, m/z, Intensity and one
#' empty column). The original slices blocks with EasyExcel on the cells that
#' appear in the first row and drops that row as a header; here the slicing uses
#' a fixed stride, with block existence likewise decided by the first row.
#'
#' Sample names come from Sample(No) of each block in the first row (as in the
#' original, the header text is not read), deduplicated with order preserved. The
#' ion list is ordered sample first (all ions of sample 1, then sample 2, ...);
#' that order affects the original's stable sort and findIon's tie-breaking, so
#' it must be preserved.
#'
#' @param path path to the Excel file
#' @param block_width columns per sample; NA (default) detects it: a header
#'   containing RT_apex means seven columns per block (new layout), otherwise six
#'   (old layout)
#' @return list(sample_names, ions) where ions is a data.frame with
#'   no (character), no_int, rt, rt_mz, no_mz, mz, rt_no_mz, intensity, col and
#'   rt_apex (sub-minute apex RT, new layout only; NA in the old layout)
dmf_read_samples <- function(path, block_width = NA) {
  if (!file.exists(path)) stop("Data file not found: ", path)

  raw <- readxl::read_excel(path, col_names = FALSE, .name_repair = "minimal")
  raw <- as.data.frame(raw, stringsAsFactors = FALSE)
  if (nrow(raw) < 2L) stop("Data file has no rows besides the header: ", path)

  # The first row readxl returns is the xlsx header text (data starts on the
  # second row, see below). RT_apex is the sub-minute RT column added by
  # Ms1Geter; when present there is one extra column, so the block width is 7
  # instead of 6.
  hdr <- trimws(as.character(raw[1L, ]))
  has_rt <- any(hdr == "RT_apex")
  if (is.na(block_width)) block_width <- if (has_rt) 7L else 6L

  # EasyExcel defaults to headRowNumber = 1: the first row is dropped as a header
  data <- raw[-1L, , drop = FALSE]
  n_col <- ncol(data)

  starts <- seq.int(1L, n_col, by = block_width)
  starts <- starts[starts + 4L <= n_col]
  if (length(starts) == 0L) stop("Data file has too few columns to slice into 6-column blocks per sample")

  first_no <- vapply(starts, function(s) suppressWarnings(as.numeric(data[[s]][1])), numeric(1))
  starts <- starts[!is.na(first_no)]
  first_no <- first_no[!is.na(first_no)]
  if (length(starts) == 0L) stop("No sample numbers in the first row, the file layout is not supported")

  blocks <- lapply(seq_along(starts), function(j) {
    s <- starts[j]
    no   <- suppressWarnings(as.numeric(data[[s]]))
    rt   <- suppressWarnings(as.numeric(data[[s + 1L]]))
    rtmz <- suppressWarnings(as.numeric(data[[s + 2L]]))
    mz   <- suppressWarnings(as.numeric(data[[s + 3L]]))
    inten <- suppressWarnings(as.numeric(data[[s + 4L]]))
    ok <- !is.na(no) & !is.na(rt) & !is.na(rtmz) & !is.na(mz) & !is.na(inten)
    if (!any(ok)) return(NULL)
    out <- data.frame(block = j, no_num = no[ok], rt = rt[ok], rt_mz_raw = rtmz[ok],
                      mz_raw = mz[ok], intensity = inten[ok], stringsAsFactors = FALSE)
    if (has_rt) {
      rtx <- suppressWarnings(as.numeric(data[[s + 5L]]))
      out$rt_apex <- rtx[ok]
    }
    out
  })
  blocks <- blocks[!vapply(blocks, is.null, logical(1))]
  if (length(blocks) == 0L) stop("No ion data could be read: ", path)
  ions <- do.call(rbind, blocks)
  rownames(ions) <- NULL

  # Sample names: Sample(No) of each block in the first row, deduplicated with order
  # preserved (the original's HashSet + ArrayList order)
  block_names <- dmf_integer_string(first_no)
  sample_names <- unique(block_names)
  col_of_block <- match(block_names, sample_names)

  # Key construction: identical to parseIon in the original
  no_str <- dmf_integer_string(ions$no_num)
  rt_str <- dmf_integer_string(ions$rt)
  mz <- dmf_truncate(ions$mz_raw)
  rt_mz <- dmf_truncate(ions$rt_mz_raw)
  mz_str <- sprintf("%.8f", mz)                       # BigDecimal(scale 8).toString()
  # truncate(no + mz): the concatenated string already has 8 decimals, so adding
  # 1e-10 and truncating to 8 decimals is the identity here. Running truncate on
  # the double again would drag in the double representation error (for example
  # 4491174.33184999979) and cut it to 4491174.33184999.
  no_concat <- paste0(no_str, mz_str)
  no_mz <- as.numeric(no_concat)
  concat <- paste0(rt_str, no_str, mz_str)
  rt_no_mz <- as.numeric(concat)                      # new BigDecimal(rt+no+mz)

  if (any(is.na(no_mz)) || any(is.na(rt_no_mz))) {
    stop("Failed to build the concatenated key: the sample number / RT / m/z ",
         "string concatenation does not parse as a number. As in the original, ",
         "the digit count of Sample(No) and the integer-only RT are binding ",
         "constraints")
  }

  # Both key families -- no&m/z (about 1e7) and rt&no&m/z (up to about 1.9e8) --
  # are at or beyond the resolution limit of double: once the ulp swallows the
  # original fixOffset (1e-9) the 8th decimal can no longer be resolved. The
  # original compares with BigDecimal in decimal, so the integer part and the
  # 8-decimal fraction are stored as two exact integers for the window test.
  no_parts <- dmf_decimal_parts(no_concat)
  parts <- dmf_decimal_parts(concat)

  list(
    sample_names = sample_names,
    ions = data.frame(
      no       = no_str,
      no_int   = as.integer(ions$no_num),
      rt       = ions$rt,
      rt_mz    = rt_mz,
      no_mz    = no_mz,
      no_mz_ip = no_parts$ip,
      no_mz_f8 = no_parts$f8,
      mz       = mz,
      rt_no_mz = rt_no_mz,
      rt_no_mz_ip = parts$ip,
      rt_no_mz_f8 = parts$f8,
      intensity = ions$intensity,
      col      = col_of_block[ions$block],
      rt_apex  = if (is.null(ions$rt_apex)) NA_real_ else ions$rt_apex,
      stringsAsFactors = FALSE
    )
  )
}


# ============================================================
# 4. Intensity matrix (IonsManager2.buildIntensityMatrix + MatrixRow)
# ============================================================

#' Build cross-sample intensity-matrix rows for every ion and derive
#' count / averageIntensity
#'
#' The original takes, for each ion, every ion within +/- ErrorRange of its rtMz
#' and puts them into a MatrixRow keyed on sample number (first come, first
#' served within a sample); count is the number of samples present and
#' averageIntensity is the summed intensity / count (7 digits, HALF_UP).
#'
#' `pick` selects which ion is taken when one sample has several hits in the
#' window:
#'   - "first" (default, matching the original Java): first by ascending
#'     original index;
#'   - "max": the most intense one in the window.
#' The two are equivalent when a given ion occupies only one branch of the
#' window. They differ only when one feature splits into several m/z branches,
#' where an unstable choice makes that sample's intensity jump between a strong
#' and a weak branch and biases both the group mean and the fold change, so
#' "max" is the steadier convention.
#'
#' @param ions ion table returned by dmf_read_samples()
#' @param n_samples number of samples
#' @param error_range within-group matching tolerance, unit given by unit
#' @param digits decimals of the mean
#' @param pick "first" or "max", see above
#' @param rt_tol extra tolerance on the time axis (minutes). 0 (default) uses
#'   only the rt_mz key, i.e. the original "same integer minute bin +/-
#'   ErrorRange"; >0 switches to "+/- ErrorRange and |apex RT difference| <=
#'   rt_tol", which requires the RT_apex column written by Ms1Geter and falls
#'   back to the 0 behaviour when that column is missing.
#' @param unit unit of error_range: "ppm" (converted per row from m/z) or "Da"
#' @return ions with count / avg / mat appended (n_ions x n_samples, NA where not
#'   measured)
dmf_create_matrix <- function(ions, n_samples, error_range, digits = 7L,
                              pick = c("first", "max"), rt_tol = 0,
                              unit = "Da") {
  pick <- match.arg(pick)
  n <- nrow(ions)
  ppm <- .dmf_vec_tol(unit)
  # Per-row tolerance in Da (ppm mode) or a scalar (Da mode); each branch below
  # subsets it in its own way
  tol_all <- .dmf_tol_da(ions$mz, error_range, unit)

  use_rt <- length(rt_tol) == 1L && is.numeric(rt_tol) && is.finite(rt_tol) &&
    rt_tol > 0 && !is.null(ions$rt_apex) && any(is.finite(ions$rt_apex))

  if (!use_rt) {
    o <- order(ions$rt_mz)
    ks <- ions$rt_mz[o]
    tol_k <- if (ppm) tol_all[o] else tol_all

    b <- dmf_window_bounds(ks, ks, tol_k, vec_tol = ppm)
    w <- b$hi - b$lo + 1L
    if (any(w < 1L)) stop("Empty matching window: the data or the error range is abnormal")

    ion_ion <- o[rep.int(seq_len(n), w)]
    mem_ion <- o[sequence(w, from = b$lo)]
  } else {
    # ---- Two-dimensional window: m/z (+/- ErrorRange) AND apex RT (+/- rt_tol) ----
    # key = floor(RT / rt_tol) * 1e8 + round(m/z * 1e4). After sorting by this
    # key, all members of one kind still form a contiguous run inside a given RT
    # bin (a bin is ordered by m/z), so findInterval still applies; query the
    # neighbouring bins as well and then filter on the true RT difference. The
    # bin width is rt_tol, so two rows within rt_tol of each other differ in bin
    # number by at most 1, which makes three queries exhaustive.
    rt <- ions$rt_apex
    bad <- !is.finite(rt)
    if (any(bad)) rt[bad] <- ions$rt[bad]      # rows without an apex RT fall back to the whole-minute bin
    mz4 <- round(ions$mz * 1e4)                # integer representation of m/z (1e-4 Da)
    off <- 1e8
    bnx <- floor(rt / rt_tol)
    k2  <- bnx * off + mz4

    o  <- order(k2)
    ks <- k2[o]
    # The key unit is 1e-4 Da, so the tolerance is converted the same way
    # (in ppm mode this is the per-row mz * ppm * 1e-2)
    err <- if (ppm) tol_all * 1e4 else error_range * 1e4

    grab <- function(target, check_rt) {
      bb <- dmf_window_bounds(ks, target, err, vec_tol = ppm)
      ww <- bb$hi - bb$lo + 1L
      # Finding nothing in a neighbouring bin is normal (that bin may hold no ion
      # with a similar m/z); the ion's own bin must at least hit itself.
      if (!check_rt && any(ww < 1L)) {
        stop("Empty matching window: the data or the error range is abnormal")
      }
      ii <- rep.int(seq_len(n), ww)
      mm <- o[sequence(ww, from = bb$lo)]
      if (check_rt) {
        keep <- abs(rt[mm] - rt[ii]) <= rt_tol + 1e-9
        ii <- ii[keep]
        mm <- mm[keep]
      }
      list(ii = ii, mm = mm)
    }
    e0 <- grab(k2, FALSE)                       # same bin: RT difference is necessarily < rt_tol, no filtering needed
    e1 <- grab((bnx + 1L) * off + mz4, TRUE)    # next bin
    e2 <- grab((bnx - 1L) * off + mz4, TRUE)    # previous bin
    ion_ion <- c(e0$ii, e1$ii, e2$ii)
    mem_ion <- c(e0$mm, e1$mm, e2$mm)
    rm(e0, e1, e2)
  }
  col_mem <- ions$col[mem_ion]

  # The sort key defines "first come, first served": first = ascending original
  # index; max = descending intensity
  ord <- if (identical(pick, "max")) {
    order(ion_ion, -ions$intensity[mem_ion], mem_ion)
  } else {
    order(ion_ion, mem_ion)
  }
  ion_ion <- ion_ion[ord]
  mem_ion <- mem_ion[ord]
  col_mem <- col_mem[ord]

  dup <- duplicated(ion_ion * (n_samples + 1L) + col_mem)
  ion_ion <- ion_ion[!dup]
  mem_ion <- mem_ion[!dup]
  col_mem <- col_mem[!dup]

  cnt <- tabulate(ion_ion, nbins = n)
  sums <- .dmf_group_sum(ions$intensity[mem_ion], ion_ion, n)

  mat <- matrix(NA_real_, nrow = n, ncol = n_samples)
  mat[cbind(ion_ion, col_mem)] <- ions$intensity[mem_ion]

  ions$count <- cnt
  ions$avg <- dmf_divide(sums, cnt, digits)
  ions$mat <- mat
  ions
}


# ============================================================
# 5. Threshold filtering and deduplication (IonCalculator.filterIons + distinctIons)
# ============================================================

#' IonsManager2.sortByCount: descending by count, stable sort
dmf_sort_by_count <- function(count) {
  order(count, seq_along(count), decreasing = c(TRUE, FALSE))
}

#' One deduplication round
#'
#' The original distinctIons(ions, iStd, errorRange): walk ions (descending by
#' count) and, for each ion, find inside its own key window the one that ranks
#' first in the hit set (the smallest idxMap value); if that representative is
#' not taken yet, keep the current ion and mark the representative as taken.
#' Note that what is kept is the *current* ion, not the representative itself --
#' that is what the original does.
#'
#' @param cur current ion index vector (already descending by count)
#' @param key key vector of all ions
#' @param error_range tolerance, unit given by unit
#' @param mz m/z vector as long as cur; required in ppm mode (the tolerance is
#'   converted per row)
#' @param unit "ppm" or "Da"
#' @return index vector of the ions kept (cur order preserved)
dmf_distinct_pass <- function(cur, key, error_range, mz = NULL, unit = "Da") {
  n <- length(cur)
  if (n <= 1L) return(cur)

  ppm <- .dmf_vec_tol(unit)
  if (ppm && is.null(mz)) {
    stop("ppm mode needs the m/z of each ion (the mz argument of dmf_distinct_pass)")
  }

  kv <- key[cur]
  o <- order(kv)                 # stable sort; equal keys share a window, so order is irrelevant
  ks <- kv[o]
  rank_in_cur <- o               # position in cur of each key-ordered slot

  tol <- if (ppm) .dmf_tol_da(mz, error_range, unit)[o] else error_range
  amin <- dmf_argmin_in_window(ks, ks, tol, rank_in_cur, vec_tol = ppm)
  canon <- integer(n)
  canon[rank_in_cur] <- amin
  cur[!duplicated(canon)]
}

#' Main deduplication loop (at most two rounds, matching the original do/while)
dmf_distinct_ions <- function(cur, key, error_range, mz = NULL, unit = "Da") {
  res <- dmf_distinct_pass(cur, key, error_range, mz = mz, unit = unit)
  if (length(res) == length(cur)) return(res)
  dmf_distinct_pass(res, key, error_range,
                    mz = if (is.null(mz)) NULL else mz[match(res, cur)],
                    unit = unit)
}

#' Subset the ions by index (the mat column is kept)
dmf_subset_ions <- function(ions, idx) {
  out <- data.frame(
    no = ions$no[idx],
    no_int = ions$no_int[idx],
    rt = ions$rt[idx],
    rt_mz = ions$rt_mz[idx],
    no_mz = ions$no_mz[idx],
    mz = ions$mz[idx],
    rt_no_mz = ions$rt_no_mz[idx],
    intensity = ions$intensity[idx],
    col = ions$col[idx],
    count = ions$count[idx],
    avg = ions$avg[idx],
    stringsAsFactors = FALSE
  )
  out$mat <- ions$mat[idx, , drop = FALSE]
  out
}


# ============================================================
# 6. Scoring (scoringP50Ions / averageScore4AllIons / mergeScore)
# ============================================================

#' Individual scoring of the 50% ions (P50Score)
#'
#' Deduplicate into groups keyed on m/z: find each ion's representative inside
#' the m/z window (findIon), then group by representative and, within a group,
#' count the ions and average their intensity (the mean of averageIntensity).
#'
#' @param cur ion index vector (post-dedup order == the original _p50Ions order)
#' @param ions all ions
#' @param error_range tolerance
#' @param cfg configuration
#' @return data.frame with the same row order as cur
dmf_score_p50 <- function(cur, ions, error_range, cfg) {
  digits <- cfg$FloatCount
  n <- length(cur)
  if (n == 0L) return(NULL)

  ppm <- .dmf_vec_tol(cfg$ErrorRangeUnit)
  mzv <- ions$mz[cur]
  avgv <- ions$avg[cur]
  o <- order(mzv)
  ks <- mzv[o]
  rank_in_cur <- o
  tol <- if (ppm) .dmf_tol_da(mzv, error_range, cfg$ErrorRangeUnit)[o] else error_range
  amin <- dmf_argmin_in_window(ks, ks, tol, rank_in_cur, vec_tol = ppm)

  # Group by representative (key-ordered slot)
  cnt_grp <- tabulate(amin, nbins = n)
  sum_grp <- .dmf_group_sum(avgv[o], amin, n)

  std_mz <- ks[amin]
  std_cnt <- cnt_grp[amin]
  std_avg <- dmf_divide(sum_grp[amin], std_cnt, digits)

  rel <- dmf_divide(avgv[o], std_avg, digits)
  int_score <- dmf_score(avgv[o], cfg$p50IntensityRange, cfg$p50IntensityValue)
  cnt_score <- dmf_score(std_cnt, cfg$p50CountRange, cfg$p50CountValue)
  rel_score <- ifelse(std_cnt >= cfg$p50RelativeIntensitySplit,
                      dmf_score(rel, cfg$p50RelativeIntensityRange1, cfg$p50RelativeIntensityValue1),
                      dmf_score(rel, cfg$p50RelativeIntensityRange2, cfg$p50RelativeIntensityValue2))
  total <- int_score * cnt_score * rel_score

  back <- order(o)   # undo the key ordering, back to cur order

  data.frame(
    idx = cur,
    no_int = ions$no_int[cur],
    rt = ions$rt[cur],
    rt_mz = ions$rt_mz[cur],
    mz = ions$mz[cur],
    avg = avgv,
    std_mz = std_mz[back],
    std_count = std_cnt[back],
    std_avg = std_avg[back],
    rel = rel[back],
    int_score = int_score[back],
    count_score = cnt_score[back],
    rel_score = rel_score[back],
    total = total[back],
    stringsAsFactors = FALSE
  )
}

#' All-ion scoring (IonScore, noMz dimension + rtMz dimension)
#'
#' Both dimensions rest on "representative = smallest original index in the
#' window":
#'   noMz dimension: ions within one sample, one time slice and with a similar
#'     m/z form a group;
#'   rtMz dimension: ions across samples sharing the same RT&m/z form a group.
#' The first dimension yields noMzTotalScore; the second averages it per rtMz.
#'
#' @param ions all ions
#' @param error_range tolerance
#' @param cfg configuration
#' @return data.frame with the same row order as ions
dmf_score_all_ions <- function(ions, error_range, cfg) {
  digits <- cfg$FloatCount
  n <- nrow(ions)
  if (n == 0L) return(NULL)

  ppm <- .dmf_vec_tol(cfg$ErrorRangeUnit)
  tol_all <- .dmf_tol_da(ions$mz, error_range, cfg$ErrorRangeUnit)

  # ---- Dimension one: noMz ----
  # The no&m/z key is about 1e7, where the double ulp approaches the original
  # fixOffset, so the integer part plus the 8-decimal fraction is used and the
  # test runs exactly in decimal.
  # Note that both target and target_parts must follow the key-sorted order.
  o1 <- order(ions$no_mz)
  k1 <- ions$no_mz[o1]
  k1_parts <- list(ip = ions$no_mz_ip[o1], f8 = ions$no_mz_f8[o1])
  amin1 <- dmf_argmin_in_window(
    k1, k1, if (ppm) tol_all[o1] else error_range, o1, exact = TRUE,
    key_parts = k1_parts, target_parts = k1_parts, vec_tol = ppm
  )
  cnt1 <- tabulate(amin1, nbins = n)
  sum1 <- .dmf_group_sum(ions$intensity[o1], amin1, n)
  std_no_mz <- k1[amin1]
  no_mz_cnt <- cnt1[amin1]
  no_mz_avg <- dmf_divide(sum1[amin1], no_mz_cnt, digits)
  no_mz_rel <- dmf_divide(ions$intensity[o1], no_mz_avg, digits)

  no_mz_int <- dmf_score(ions$intensity[o1], cfg$intensityRange, cfg$intensityValue)
  no_mz_cnt_score <- dmf_score(no_mz_cnt, cfg$countRange, cfg$countValue)
  no_mz_rel_score <- ifelse(no_mz_cnt >= cfg$relativeIntensitySplit,
                            dmf_score(no_mz_rel, cfg$relativeIntensityRange1, cfg$relativeIntensityValue1),
                            dmf_score(no_mz_rel, cfg$relativeIntensityRange2, cfg$relativeIntensityValue2))
  no_mz_total <- no_mz_int * no_mz_cnt_score * no_mz_rel_score

  # ---- Dimension two: rtMz ----
  o2 <- order(ions$rt_mz)
  k2 <- ions$rt_mz[o2]
  amin2 <- dmf_argmin_in_window(k2, k2, if (ppm) tol_all[o2] else error_range, o2,
                                vec_tol = ppm)
  cnt2 <- tabulate(amin2, nbins = n)
  # The within-group sum runs over noMzTotalScore from dimension one, indexed
  # by the original ion index
  tot2_raw <- numeric(n)
  tot2_raw[o1] <- no_mz_total
  sum2 <- .dmf_group_sum(tot2_raw[o2], amin2, n)
  std_rt_mz <- k2[amin2]
  rt_mz_cnt <- cnt2[amin2]
  rt_mz_total <- sum2[amin2]
  rt_mz_avg <- dmf_divide(rt_mz_total, rt_mz_cnt, digits)

  back1 <- order(o1)
  back2 <- order(o2)

  out <- data.frame(
    no_int = ions$no_int,
    rt = ions$rt,
    rt_mz = ions$rt_mz,
    no_mz = ions$no_mz,
    mz = ions$mz,
    intensity = ions$intensity,
    std_no_mz = std_no_mz[back1],
    no_mz_cnt = no_mz_cnt[back1],
    no_mz_avg = no_mz_avg[back1],
    no_mz_rel = no_mz_rel[back1],
    no_mz_int_score = no_mz_int[back1],
    no_mz_cnt_score = no_mz_cnt_score[back1],
    no_mz_rel_score = no_mz_rel_score[back1],
    no_mz_total = no_mz_total[back1],
    std_rt_mz = std_rt_mz[back2],
    rt_mz_cnt = rt_mz_cnt[back2],
    rt_mz_total = rt_mz_total[back2],
    rt_mz_avg = rt_mz_avg[back2],
    stringsAsFactors = FALSE
  )
  out$score_diff <- out$no_mz_total - out$rt_mz_avg
  out
}


# ============================================================
# 7. Isotope search (IonCalculator.calcIsotopes)
# ============================================================

#' Look up M+1 / M+2 / M+3 for every ion and decide whether it is an isotope peak
#'
#' The decision rules copy the original's nested IF/AND/OR verbatim (null
#' propagation included):
#'   X = 100<=mz<=1000 and 1<=M/M+1<=50, or mz>=1000 and 0.5<=M/M+1<=5
#'   Y = X==1 and M+1/M+2>1 and (1<=M+1/M+2<=100 or 0.5<=...<=5, split by mz)
#'   Z = Y==1 and M+2/M+3>1 and (same as above)
#' When a level is missing (no peak found) that level stays empty and the cell
#' ends up holding NullCellValue(0).
#'
#' @param ions all ions
#' @param error_range tolerance
#' @param cfg configuration
#' @return data.frame with the same row order as ions
dmf_calc_isotopes <- function(ions, error_range, cfg) {
  digits <- cfg$FloatCount
  n <- nrow(ions)
  if (n == 0L) return(NULL)

  ppm <- .dmf_vec_tol(cfg$ErrorRangeUnit)
  tol_all <- .dmf_tol_da(ions$mz, error_range, cfg$ErrorRangeUnit)

  o <- order(ions$rt_no_mz)
  k <- ions$rt_no_mz[o]
  key_parts <- list(ip = ions$rt_no_mz_ip[o], f8 = ions$rt_no_mz_f8[o])
  target_parts <- list(ip = ions$rt_no_mz_ip, f8 = ions$rt_no_mz_f8)

  # rtNoMz is a pseudo-number built from rt/no/mz and reaches 1e8, so the window
  # boundary must be tested exactly in decimal; otherwise a neighbour differing
  # by exactly 0.002 is wrongly admitted.
  # The offset is handled inside the comparison so that target + delta cannot add
  # another rounding step.
  # Note that target follows the original ion order, so the per-row tolerance is
  # taken in that order too.
  pick <- function(delta) {
    amin <- dmf_argmin_in_window(k, ions$rt_no_mz,
                                 if (ppm) tol_all else error_range, o,
                                 exact = TRUE, offset = delta,
                                 key_parts = key_parts,
                                 target_parts = target_parts,
                                 vec_tol = ppm)
    idx <- rep(NA_integer_, n)
    hit <- !is.na(amin)
    idx[hit] <- o[amin[hit]]
    idx
  }
  m1_idx <- pick(cfg$m1)
  m2_idx <- pick(cfg$m2)
  m3_idx <- pick(cfg$m3)

  fin <- function(idx, v) ifelse(is.na(idx), NA_real_, v[ifelse(is.na(idx), 1L, idx)])
  m1_find <- fin(m1_idx, ions$rt_no_mz)
  m2_find <- fin(m2_idx, ions$rt_no_mz)
  m3_find <- fin(m3_idx, ions$rt_no_mz)
  m1_int <- fin(m1_idx, ions$intensity)
  m2_int <- fin(m2_idx, ions$intensity)
  m3_int <- fin(m3_idx, ions$intensity)

  m_m1 <- dmf_divide(ions$intensity, m1_int, digits)
  m1_m2 <- dmf_divide(m1_int, m2_int, digits)
  m2_m3 <- dmf_divide(m2_int, m3_int, digits)

  # The original decision:
  #   X = IF(OR(AND(100<=E<=1000, 1<=T<=50), AND(E>=1000, 0.5<=T<=5)), 1, 0)
  #   Y = IF(AND(U>1, X==1, OR(AND(100<=E<=1000, 1<=U<=100), AND(E>=1000, 0.5<=U<=5))), 1, 0)
  #   Z = IF(AND(V>1, Y==1, OR(AND(100<=E<=1000, 1<=V<=100), AND(E>=1000, 0.5<=V<=5))), 1, 0)
  # e and v must be paired element-wise at equal length (v is a ratio on a
  # subset, so the full-length E cannot be used together with it)
  in_seg <- function(e, v, lo1, hi1, lo2, hi2) {
    (e >= 100 & e <= 1000 & v >= lo1 & v <= hi1) |
      (e >= 1000 & v >= lo2 & v <= hi2)
  }

  X <- rep(NA_integer_, n)
  ok <- !is.na(m_m1)
  X[ok] <- as.integer(in_seg(ions$mz[ok], m_m1[ok], 1, 50, 0.5, 5))

  Y <- rep(NA_integer_, n)
  ok <- !is.na(X) & !is.na(m1_m2)
  Y[ok] <- as.integer(m1_m2[ok] > 1 & X[ok] == 1L &
                        in_seg(ions$mz[ok], m1_m2[ok], 1, 100, 0.5, 5))

  Z <- rep(NA_integer_, n)
  ok <- !is.na(Y) & !is.na(m2_m3)
  Z[ok] <- as.integer(m2_m3[ok] > 1 & Y[ok] == 1L &
                        in_seg(ions$mz[ok], m2_m3[ok], 1, 100, 0.5, 5))

  data.frame(
    no_int = ions$no_int,
    rt = ions$rt,
    rt_mz = ions$rt_mz,
    rt_no_mz = ions$rt_no_mz,
    mz = ions$mz,
    intensity = ions$intensity,
    m1_calc = ions$rt_no_mz + cfg$m1,
    m2_calc = ions$rt_no_mz + cfg$m2,
    m3_calc = ions$rt_no_mz + cfg$m3,
    m1_find = m1_find,
    m2_find = m2_find,
    m3_find = m3_find,
    m1_int = m1_int,
    m2_int = m2_int,
    m3_int = m3_int,
    m_m1 = m_m1,
    m1_m2 = m1_m2,
    m2_m3 = m2_m3,
    m1_iso = X,
    m2_iso = Y,
    m3_iso = Z,
    stringsAsFactors = FALSE
  )
}


# ============================================================
# 8. Cross-group comparison (p80CompareWith + mergeDiff)
# ============================================================

#' Compare this group's 80% ions with the other group's total ions
#'
#' The other group is indexed in descending count order (idxMap); a window is
#' taken in the rtMz-sorted array and the hit that comes first in count order is
#' the paired b (the original findIon().get(0) semantics). The tolerance is
#' ErrorRangeInGroups (0.003 by default).
#'
#' @param cur indices of this group's 80% ions
#' @param ions this group's ions
#' @param other the other group, list(ions, sample_names)
#' @param cfg configuration
dmf_compare_p80 <- function(cur, ions, other, cfg) {
  n_this <- length(cur)
  if (n_this == 0L) return(NULL)
  error <- cfg$ErrorRangeInGroups
  unit <- cfg$ErrorRangeUnit
  ppm <- .dmf_vec_tol(unit)
  digits <- cfg$FloatCount

  other_ions <- other$ions
  n_other <- nrow(other_ions)
  count_rank <- integer(n_other)
  count_rank[dmf_sort_by_count(other_ions$count)] <- seq_len(n_other)

  o <- order(other_ions$rt_mz)
  ks <- other_ions$rt_mz[o]
  target <- ions$rt_mz[cur]
  # The tolerance is converted from the **query side** (this group's ions) m/z
  tol <- if (ppm) .dmf_tol_da(ions$mz[cur], error, unit) else error
  amin <- dmf_argmin_in_window(ks, target, tol, count_rank[o], vec_tol = ppm)

  b_idx <- rep(NA_integer_, n_this)
  hit <- !is.na(amin)
  b_idx[hit] <- o[amin[hit]]

  b_rt_mz <- rep(NA_real_, n_this)
  b_avg <- rep(NA_real_, n_this)
  b_count <- rep(NA_real_, n_this)
  a_b <- rep(NA_real_, n_this)
  b_rt_mz[hit] <- other_ions$rt_mz[b_idx[hit]]
  b_avg[hit] <- other_ions$avg[b_idx[hit]]
  b_count[hit] <- other_ions$count[b_idx[hit]]
  a_b[hit] <- dmf_divide(ions$avg[cur][hit], b_avg[hit], digits)

  data.frame(idx = cur, b_idx = b_idx, b_rt_mz = b_rt_mz, b_avg = b_avg,
             b_count = b_count, a_b = a_b, stringsAsFactors = FALSE)
}

#' Differential ion summary (mergeDiff)
#'
#' Each row = one 80% ion of this group + its paired ion in the other group +
#' individual score + mean score + isotope verdict + per-sample intensity of both
#' groups.
#'
#' The score is not looked up exactly by rtMz; instead the "no tolerance" version
#' of the original Helper.binarySearch is reproduced: with no exact key it returns
#' the element around the insertion point, so the score may come from the nearest
#' neighbouring ion. The original behaviour is kept here.
#'
#' Ordering: descending count, then descending bCount (missing last); both steps
#' are stable sorts.
#'
#' @param cmp result of dmf_compare_p80()
#' @param ions this group's ions
#' @param p50_ions this group's 50% ions (same order as the dedup result)
#' @param p50_score result of dmf_score_p50()
#' @param iso result of dmf_calc_isotopes()
#' @param other the other group, list(ions, sample_names)
dmf_merge_diff <- function(cmp, ions, p50_ions, p50_score, iso, other) {
  n <- nrow(cmp)
  if (n == 0L) return(NULL)

  # ---- Score lookup ----
  merged_key <- p50_ions$rt_mz
  o <- order(merged_key)
  ks <- merged_key[o]
  slot <- vapply(cmp$idx, function(i) {
    target <- ions$rt_mz[i]
    p <- dmf_bsearch_java(ks, target)
    key_p <- ks[p]
    s <- p
    while (s > 1L && ks[s] == key_p) s <- s - 1L
    if (ks[s] != key_p) s <- s + 1L
    seg <- s:p
    seg[which.min(o[seg])]
  }, integer(1))
  merged_pos <- o[slot]

  # ---- Isotope lookup (only M+1 keys a map; M+2/M+3 use it as the gate) ----
  # The original builds three maps keyed on m1FindRtNoMz / m2FindRtNoMz /
  # m3FindRtNoMz with Helper.toMapF (first hit wins on duplicate keys, the same
  # semantics as R's match). All three columns are first gated by
  # m1Isotopes.containsKey(rtNoMz) and then read from their own map -- it is not
  # "take the m2 flag of whatever row held M+1".
  iso_target <- ions$rt_no_mz[cmp$idx]
  hit1 <- match(iso_target, iso$m1_find)
  hit2 <- match(iso_target, iso$m2_find)
  hit3 <- match(iso_target, iso$m3_find)
  iso1 <- rep(NA_integer_, n)
  iso2 <- rep(NA_integer_, n)
  iso3 <- rep(NA_integer_, n)
  got <- !is.na(hit1)
  iso1[got] <- iso$m1_iso[hit1[got]]
  got2 <- got & !is.na(hit2)
  iso2[got2] <- iso$m2_iso[hit2[got2]]
  got3 <- got & !is.na(hit3)
  iso3[got3] <- iso$m3_iso[hit3[got3]]

  # ---- Per-sample intensity of the other group (missing becomes 0.0, as valuesOr0 does) ----
  n_other <- length(other$sample_names)
  inten2 <- matrix(0, nrow = n, ncol = n_other)
  has_b <- !is.na(cmp$b_idx)
  if (any(has_b)) {
    inten2[has_b, ] <- other$ions$mat[cmp$b_idx[has_b], , drop = FALSE]
    inten2[is.na(inten2)] <- 0
  }

  out <- data.frame(
    idx = cmp$idx,
    no_int = ions$no_int[cmp$idx],
    rt = ions$rt[cmp$idx],
    rt_mz = ions$rt_mz[cmp$idx],
    rt_no_mz = ions$rt_no_mz[cmp$idx],
    mz = ions$mz[cmp$idx],
    avg = ions$avg[cmp$idx],
    count = ions$count[cmp$idx],
    b_rt_mz = cmp$b_rt_mz,
    b_avg = cmp$b_avg,
    b_count = cmp$b_count,
    a_b = cmp$a_b,
    b_rt = ifelse(is.na(cmp$b_idx), NA_real_, other$ions$rt[ifelse(is.na(cmp$b_idx), 1L, cmp$b_idx)]),
    score_one = p50_score$total[merged_pos],
    score_avg = p50_score$avg_score_by_rt[merged_pos],
    m1_iso = iso1,
    m2_iso = iso2,
    m3_iso = iso3,
    stringsAsFactors = FALSE
  )
  out$inten1 <- ions$mat[cmp$idx, , drop = FALSE]
  # The original writes both groups' per-sample intensity with valuesOr0: a sample
  # that was not measured is 0.0, not a blank cell
  out$inten1[is.na(out$inten1)] <- 0
  out$inten2 <- inten2
  # Stable sort: descending count, then descending bCount (NA last)
  o1 <- order(-out$count)
  out <- out[o1, , drop = FALSE]
  bc <- out$b_count
  ord2 <- order(is.na(bc), -ifelse(is.na(bc), 0, bc))
  out <- out[ord2, , drop = FALSE]
  rownames(out) <- NULL
  out
}


# ============================================================
# 9. Output sheet construction (the various toSheetData)
# ============================================================

#' Sheet structure: list(name, header = list(row1, row2, ...), cols = named column vectors)
dmf_sheet <- function(name, header, cols) {
  list(name = name, header = header, cols = cols)
}

#' Columns of toSheetData(List<Ion>)
dmf_cols_ion_table <- function(ions, idx) {
  list(no_int = ions$no_int[idx], rt = ions$rt[idx], rt_mz = ions$rt_mz[idx],
       mz = ions$mz[idx], avg = ions$avg[idx], count = ions$count[idx])
}

#' Assemble header cells (keeping numeric/text types; NA means an empty cell)
dmf_hdr <- function(...) {
  parts <- list(...)
  out <- list()
  for (p in parts) out <- c(out, if (is.list(p)) p else as.list(p))
  out
}

#' Reproduce BigDecimalHelper.valuesMayNA / to01MayNA
#'
#' Both original functions replace null with Config.instance.NullCellValue, whose
#' default is the integer 0. So "not found" shows up as 0 in the finished Excel,
#' not as a blank cell.
dmf_or0 <- function(v) {
  v[is.na(v)] <- 0
  v
}

.dmf_sheet_scoring <- function(g, p50_score, ion_score) {
  list(
    dmf_sheet(paste0(g, " 50% ion scores"),
              list(c("sample", "RT", "RT&m/z", "m/z", "Mean intensity", "Match (dedup. ions)",
                     "Count", "Repeated-ion mean intensity",
                     "Single/repeated mean intensity",
                     "Intensity score", "Count score", "Relative intensity score",
                     "Total score")),
              list(no_int = p50_score$no_int, rt = p50_score$rt, rt_mz = p50_score$rt_mz,
                   mz = p50_score$mz, avg = p50_score$avg, std_mz = p50_score$std_mz,
                   std_count = p50_score$std_count, std_avg = p50_score$std_avg,
                   rel = p50_score$rel, int_score = p50_score$int_score,
                   count_score = p50_score$count_score, rel_score = p50_score$rel_score,
                   total = p50_score$total)),
    dmf_sheet(paste0(g, " all-ion scores"),
              list(
                c("All-sample ion summary", NA, NA,
                  paste("Sample No. must exceed 2 because m/z spans 100-1500 and",
                        "sample&m/z would otherwise collide with m/z")),
                c("sample (No)", "RT", "RT&m/z", "No&m/z", "m/z", "Intensity", "-",
                  "Match (dedup. within one sample, all time slices)",
                  "Count (single sample)",
                  "Repeated-ion mean intensity (single sample)",
                  "Single/repeated mean intensity",
                  "Intensity score", "Count score", "Relative intensity",
                  "Total score", "-",
                  "Match (dedup. across all samples per time slice)", "Count",
                  "Sum of scores", "Mean score", "Score difference")
              ),
              dmf_cols_ion_score(ion_score)),
    dmf_sheet(paste0(g, " score summary"),
              list(c("sample", "RT", "RT&m/z", "m/z", "Individual score", "Mean score")),
              dmf_cols_merged_score(p50_score))
  )
}

dmf_cols_ion_score <- function(s) {
  list(no_int = s$no_int, rt = s$rt, rt_mz = s$rt_mz, no_mz = s$no_mz, mz = s$mz,
       intensity = s$intensity, dash1 = rep(NA_character_, nrow(s)),
       std_no_mz = s$std_no_mz, no_mz_cnt = s$no_mz_cnt, no_mz_avg = s$no_mz_avg,
       no_mz_rel = s$no_mz_rel, no_mz_int_score = s$no_mz_int_score,
       no_mz_cnt_score = s$no_mz_cnt_score, no_mz_rel_score = s$no_mz_rel_score,
       no_mz_total = s$no_mz_total, dash2 = rep(NA_character_, nrow(s)),
       std_rt_mz = s$std_rt_mz, rt_mz_cnt = s$rt_mz_cnt, rt_mz_total = s$rt_mz_total,
       rt_mz_avg = s$rt_mz_avg, score_diff = s$score_diff)
}

dmf_cols_merged_score <- function(p50_score) {
  list(no_int = p50_score$no_int, rt = p50_score$rt, rt_mz = p50_score$rt_mz,
       mz = p50_score$mz, score_one = p50_score$total, score_avg = p50_score$avg_score_by_rt)
}

.dmf_sheet_isotope <- function(g, iso) {
  n <- nrow(iso)
  dmf_sheet(paste0(g, " isotope search"),
            list(
              c("Isotope search over all ions", NA, "Group A all ions", NA, NA, NA, NA,
                "Theoretical M+1", "Theoretical M+2", "Theoretical M+3", NA,
                "Observed M+1", "Observed M+2", "Observed M+3", NA,
                "Observed M+1 intensity", "Theoretical M+2 intensity",
                "Observed M+3 intensity", NA,
                "Intensity ratio", NA, NA, NA, "Isotope of the M peak", NA, NA),
              c("sample (No)", "RT", "RT&m/z", "RT&No&m/z", "m/z", "Intensity", "-",
                "RT&No&(M+1)", "RT&No&(M+2)", "RT&No&(M+3)", "-",
                "RT&No&(M+1)", "RT&No&(M+2)", "RT&No&(M+3)", "-",
                "M+1", "M+2", "M+3", "-", "M/M+1", "M+1/M+2", "M+2/M+3", "-",
                "M+1", "M+2", "M+3")
            ),
            list(no_int = iso$no_int, rt = iso$rt, rt_mz = iso$rt_mz,
                 rt_no_mz = iso$rt_no_mz, mz = iso$mz, intensity = iso$intensity,
                 dash1 = rep(NA_character_, n),
                 m1_calc = iso$m1_calc, m2_calc = iso$m2_calc, m3_calc = iso$m3_calc,
                 dash2 = rep(NA_character_, n),
                 m1_find = dmf_or0(iso$m1_find), m2_find = dmf_or0(iso$m2_find),
                 m3_find = dmf_or0(iso$m3_find),
                 dash3 = rep(NA_character_, n),
                 m1_int = dmf_or0(iso$m1_int), m2_int = dmf_or0(iso$m2_int),
                 m3_int = dmf_or0(iso$m3_int),
                 dash4 = rep(NA_character_, n),
                 m_m1 = dmf_or0(iso$m_m1), m1_m2 = dmf_or0(iso$m1_m2),
                 m2_m3 = dmf_or0(iso$m2_m3),
                 dash5 = rep(NA_character_, n),
                 m1_iso = dmf_or0(iso$m1_iso),
                 m2_iso = dmf_or0(iso$m2_iso),
                 m3_iso = dmf_or0(iso$m3_iso)))
}

.dmf_sheet_p80_compare <- function(g, p80_str, other_g, cmp, ions, other) {
  n_other <- length(other$sample_names)
  n <- nrow(cmp)
  # The original hardcodes 10 empty cells (r1.addAll(Arrays.asList(null x10)));
  # copied verbatim here
  h1 <- dmf_hdr(paste0("Group A ", p80_str, " ions"), rep(NA, 10),
                "Group B intensity")
  h2 <- dmf_hdr(list("sample", "RT", "RT&m/z", "m/z", "Mean intensity", "Ion count",
                     paste0(other_g, " RT&m/z"), paste0(other_g, " mean intensity"),
                     paste0(other_g, " ion count"), paste0(g, "/", other_g), "-"),
                as.list(as.numeric(other$sample_names)))
  cols <- list(no_int = ions$no_int[cmp$idx], rt = ions$rt[cmp$idx],
               rt_mz = ions$rt_mz[cmp$idx], mz = ions$mz[cmp$idx],
               avg = ions$avg[cmp$idx], count = ions$count[cmp$idx],
               b_rt_mz = dmf_or0(cmp$b_rt_mz), b_avg = dmf_or0(cmp$b_avg),
               b_count = dmf_or0(cmp$b_count), a_b = dmf_or0(cmp$a_b),
               dash = rep(NA_character_, n))
  inten <- matrix(NA_real_, nrow = n, ncol = n_other)
  has_b <- !is.na(cmp$b_idx)
  if (any(has_b)) inten[has_b, ] <- other$ions$mat[cmp$b_idx[has_b], , drop = FALSE]
  # The original calls valuesMayNA(bIntensityRow.get(sampleName)) per column, so
  # null becomes 0
  inten[is.na(inten)] <- 0
  for (j in seq_len(n_other)) cols[[paste0("s", j)]] <- inten[, j]
  dmf_sheet(paste0(g, " ", p80_str, " ions vs ", other_g), list(h1, h2), cols)
}

#' t-test P value of two sample groups (vectorised; equals Excel TTEST(a, b, 2, 2))
#'
#' Excel TTEST(array1, array2, tails=2, type=2) is "two-tailed, two-sample, equal
#' variance (pooled variance)", which corresponds to the two-tailed P value of
#' R's t.test(x, y, var.equal = TRUE).
#' R's t.test is not called here (once per row it is far too slow); the pooled
#' formula is vectorised directly:
#'   sp2 = ((n1-1)*v1 + (n2-1)*v2) / (n1+n2-2)
#'   t   = (mean1 - mean2) / sqrt(sp2 * (1/n1 + 1/n2))
#'   df  = n1 + n2 - 2
#'   p   = 2 * pt(-|t|, df)
#' NA is dropped cell by cell as R normally does (same as t.test's na.rm).
#'
#' @param m1,m2 numeric matrices, rows = ions, columns = samples
#' @return numeric vector of length nrow
dmf_ttest_pval <- function(m1, m2) {
  m1 <- as.matrix(m1)
  m2 <- as.matrix(m2)
  if (nrow(m1) == 0L) return(numeric(0))
  storage.mode(m1) <- "double"
  storage.mode(m2) <- "double"

  n1 <- rowSums(!is.na(m1))
  n2 <- rowSums(!is.na(m2))
  m_1 <- rowSums(m1, na.rm = TRUE) / pmax(n1, 1L)
  m_2 <- rowSums(m2, na.rm = TRUE) / pmax(n2, 1L)
  # Sum of squares - n*mean^2; floating error can make it slightly negative, clamp at 0
  ss1 <- pmax(rowSums(m1 * m1, na.rm = TRUE) - n1 * m_1 * m_1, 0)
  ss2 <- pmax(rowSums(m2 * m2, na.rm = TRUE) - n2 * m_2 * m_2, 0)

  v1 <- ifelse(n1 > 1L, ss1 / pmax(n1 - 1L, 1L), NA_real_)
  v2 <- ifelse(n2 > 1L, ss2 / pmax(n2 - 1L, 1L), NA_real_)

  df <- n1 + n2 - 2L
  sp2 <- ((n1 - 1L) * v1 + (n2 - 1L) * v2) / df
  se <- sqrt(sp2 * (1 / n1 + 1 / n2))
  tval <- (m_1 - m_2) / se
  p <- 2 * stats::pt(-abs(tval), df)

  # With zero variance (all intensities equal inside a group) se = 0 and t becomes
  # Inf/NaN: equal means -> p = 1, different means -> p = 0 (Excel returns
  # #DIV/0! in both cases)
  bad <- !is.finite(p) & is.finite(m_1) & is.finite(m_2)
  if (any(bad)) {
    same <- bad & abs(m_1 - m_2) <= 1e-12 * pmax(1, abs(m_1))
    p[bad] <- 0
    p[same] <- 1
  }
  # Within-group variance only exists with at least 2 valid values per group
  p[n1 < 2L | n2 < 2L] <- NA_real_
  p[!is.finite(p)] <- NA_real_
  p
}

.dmf_sheet_diff <- function(g_a, g_b, p80_str, diff, samples_a, samples_b) {
  n <- nrow(diff)
  h1 <- dmf_hdr(paste0(g_a, " ", p80_str, " ions"), rep(NA, 18),
                paste0(g_a, " intensity"),
                rep(NA, length(samples_a)), NA, paste0(g_b, " intensity"))
  h2 <- dmf_hdr(list("sample (No)", "RT", "RT&m/z", "RT&No&m/z", "m/z",
                     "Mean intensity", "Ion count",
                     paste0(g_b, " RT&m/z"), paste0(g_b, " mean intensity"),
                     paste0(g_b, " ion count"),
                     paste0(g_a, "/", g_b), paste0(g_b, " m/z"), "-",
                     "Individual score", "Mean score", "P value",
                     "M+1", "M+2", "M+3", "-"),
                as.list(as.numeric(samples_a)), list("-"),
                as.list(as.numeric(samples_b)))

  # P value column: the original writes the Excel formula
  # =TTEST(U{r}:AD{r},AF{r}:AO{r},2,2), but openxlsx's writeData() does not treat a
  # string starting with "=" as a formula (it lands in the xlsx as a shared string
  # with t="s" and no <f> node), so Excel/WPS displays the formula text, and the DT
  # preview does the same. The P value is therefore computed as a number in R, so
  # both outputs are correct.
  # The statistics are identical to TTEST(...,2,2): two-tailed, two-sample,
  # equal variance.
  p_col <- dmf_ttest_pval(diff$inten1, diff$inten2)

  # Other group's m/z: strip the prefix of b's RT&m/z string using b's RT digit
  # count (what the original does:
  # int len = (int)Math.log10(b.rt) + 1; mz.substring(len))
  b_mz <- rep(NA_real_, n)
  ok <- !is.na(diff$b_rt_mz)
  if (any(ok)) {
    rt_int <- as.integer(diff$b_rt[ok])
    len <- as.integer(log10(rt_int)) + 1L
    b_mz[ok] <- as.numeric(substring(sprintf("%.8f", diff$b_rt_mz[ok]), len + 1L))
  }

  cols <- list(no_int = diff$no_int, rt = diff$rt, rt_mz = diff$rt_mz,
               rt_no_mz = diff$rt_no_mz, mz = diff$mz, avg = diff$avg,
               count = diff$count, b_rt_mz = dmf_or0(diff$b_rt_mz),
               b_avg = dmf_or0(diff$b_avg),
               b_count = dmf_or0(diff$b_count), a_b = dmf_or0(diff$a_b),
               b_mz = dmf_or0(b_mz),
               dash1 = rep(NA_character_, n), score_one = diff$score_one,
               score_avg = diff$score_avg, pval = p_col,
               m1_iso = dmf_or0(diff$m1_iso),
               m2_iso = dmf_or0(diff$m2_iso),
               m3_iso = dmf_or0(diff$m3_iso),
               dash2 = rep(NA_character_, n))
  for (j in seq_along(samples_a)) cols[[paste0("a", j)]] <- diff$inten1[, j]
  cols[["dash3"]] <- rep(NA_character_, n)
  for (j in seq_along(samples_b)) cols[[paste0("b", j)]] <- diff$inten2[, j]
  cols[["dash4"]] <- rep(NA_character_, n)

  dmf_sheet(sprintf("%s vs %s diff. ions", g_a, g_b), list(h1, h2), cols)
}


# ------------------------------------------------------------
# Merged table: each of the two differential-ion tables uses its own group's 80%
# ions as the row set, so one ion appears once in each of them (with the other
# side possibly zero throughout). The two are combined here into one union table:
# one row per ion, both sides' intensities side by side, and the direction decided
# directly from the group mean intensity ratio plus the P value.
# ------------------------------------------------------------

#' Look up the "individual score / mean score" of one group's ions
#'
#' Byte-for-byte equivalent to the binarySearch lookup inside dmf_merge_diff()
#' (no tolerance; on duplicate keys the smallest original index wins). It is
#' factored out so the merged table can also look up the *other* group's scores.
#'
#' @param ions that group's ions
#' @param idx indices into that group's ions (may contain NA)
#' @param p50_ions that group's 50% ions
#' @param p50_score result of dmf_score_p50()
#' @return list(one = individual score, avg = mean score), same length as idx,
#'   NA where nothing is found
dmf_score_at <- function(ions, idx, p50_ions, p50_score) {
  n <- length(idx)
  one <- rep(NA_real_, n)
  avg <- rep(NA_real_, n)
  if (n == 0L || is.null(p50_ions) || nrow(p50_ions) == 0L) {
    return(list(one = one, avg = avg))
  }
  merged_key <- p50_ions$rt_mz
  o <- order(merged_key)
  ks <- merged_key[o]
  ok <- !is.na(idx)
  if (any(ok)) {
    pos <- vapply(idx[ok], function(i) {
      target <- ions$rt_mz[i]
      if (is.na(target)) return(NA_integer_)
      p <- dmf_bsearch_java(ks, target)
      key_p <- ks[p]
      s <- p
      while (s > 1L && ks[s] == key_p) s <- s - 1L
      if (ks[s] != key_p) s <- s + 1L
      seg <- s:p
      o[seg[which.min(o[seg])]]
    }, integer(1))
    one[ok] <- p50_score$total[pos]
    avg[ok] <- p50_score$avg_score_by_rt[pos]
  }
  list(one = one, avg = avg)
}

#' Merge both groups' 80% ions into one union (intermediate structure of the
#' merged sheet)
#'
#' Row set = group A's 80% ions UNION group B's 80% ions:
#'   * every 80% ion of group A is kept and labelled "Shared" or "A 80% only"
#'     according to how it matched group B's total ions;
#'   * then the 80% ions of group B that no A ion matched are appended and
#'     labelled "B 80% only" -- a B ion already used as an A match does not
#'     reappear.
#'
#' Fold change = group A mean intensity / group B mean intensity; it is 0 when
#' either side's ion count is 0 (as in the other two tables: 0 always means "not
#' detected on the denominator or numerator side"; the Verdict column gives the
#' direction).
#'
#' @param diff_ab,diff_ba the two dmf_merge_diff() results
#' @param cmp_ab,cmp_ba the two dmf_compare_p80() results
#' @param ga,gb results of dmf_process_group()
#' @param cfg configuration (reads FoldChangeThreshold / PValueThreshold)
#' @return NULL (neither group has ions) or list(df, a_int, b_int)
dmf_union_diff <- function(diff_ab, cmp_ab, diff_ba, cmp_ba, ga, gb, cfg) {
  fold <- if (is.null(cfg$FoldChangeThreshold)) 2 else as.numeric(cfg$FoldChangeThreshold)
  alpha <- if (is.null(cfg$PValueThreshold)) 0.05 else as.numeric(cfg$PValueThreshold)

  n_a <- length(ga$sample_names)
  n_b <- length(gb$sample_names)
  has_ab <- !is.null(diff_ab) && nrow(diff_ab) > 0L
  has_ba <- !is.null(diff_ba) && nrow(diff_ba) > 0L
  if (!has_ab && !has_ba) return(NULL)

  parts <- list()
  used_b <- integer(0)

  if (has_ab) {
    partner_b <- cmp_ab$b_idx[match(diff_ab$idx, cmp_ab$idx)]
    in_b80 <- !is.na(partner_b) & partner_b %in% gb$p80_idx
    used_b <- partner_b[!is.na(partner_b)]
    sc_b <- dmf_score_at(gb$ions, partner_b, gb$p50_ions, gb$p50_score)
    # Matching is driven by this group and is not one-to-one: several A ions can
    # land on the same B ion. Record how many A ions share each B ion so
    # downstream code can tell whether a row may be counted independently.
    share <- tabulate(partner_b, nbins = nrow(gb$ions))
    parts$ab <- list(
      src = ifelse(in_b80, "Shared", "A 80% only"),
      n_share = ifelse(is.na(partner_b), NA_integer_, share[partner_b]),
      no_int = diff_ab$no_int, rt = diff_ab$rt, rt_mz = diff_ab$rt_mz, mz = diff_ab$mz,
      a_avg = diff_ab$avg, a_count = diff_ab$count,
      b_avg = diff_ab$b_avg, b_count = diff_ab$b_count,
      a_s1 = diff_ab$score_one, a_s2 = diff_ab$score_avg,
      b_s1 = sc_b$one, b_s2 = sc_b$avg,
      a_int = diff_ab$inten1, b_int = diff_ab$inten2
    )
  }

  if (has_ba) {
    keep <- !(diff_ba$idx %in% used_b)
    if (any(keep)) {
      d <- diff_ba[keep, , drop = FALSE]
      partner_a <- cmp_ba$b_idx[match(d$idx, cmp_ba$idx)]
      sc_a <- dmf_score_at(ga$ions, partner_a, ga$p50_ions, ga$p50_score)
      parts$ba <- list(
        src = rep("B 80% only", nrow(d)),
        n_share = rep(NA_integer_, nrow(d)),
        no_int = d$no_int, rt = d$rt, rt_mz = d$rt_mz, mz = d$mz,
        # In the reverse table "b_*" is group A (the other side) and
        # "avg/count" belong to this group, B
        a_avg = dmf_or0(d$b_avg), a_count = dmf_or0(d$b_count),
        b_avg = d$avg, b_count = d$count,
        a_s1 = sc_a$one, a_s2 = sc_a$avg,
        b_s1 = d$score_one, b_s2 = d$score_avg,
        a_int = d$inten2, b_int = d$inten1
      )
    }
  }

  if (length(parts) == 0L) return(NULL)

  df <- data.frame(
    src = unlist(lapply(parts, `[[`, "src"), use.names = FALSE),
    n_share = as.integer(unlist(lapply(parts, `[[`, "n_share"), use.names = FALSE)),
    no_int = unlist(lapply(parts, `[[`, "no_int"), use.names = FALSE),
    rt = unlist(lapply(parts, `[[`, "rt"), use.names = FALSE),
    rt_mz = unlist(lapply(parts, `[[`, "rt_mz"), use.names = FALSE),
    mz = unlist(lapply(parts, `[[`, "mz"), use.names = FALSE),
    a_avg = as.numeric(unlist(lapply(parts, `[[`, "a_avg"), use.names = FALSE)),
    a_count = as.numeric(unlist(lapply(parts, `[[`, "a_count"), use.names = FALSE)),
    b_avg = as.numeric(unlist(lapply(parts, `[[`, "b_avg"), use.names = FALSE)),
    b_count = as.numeric(unlist(lapply(parts, `[[`, "b_count"), use.names = FALSE)),
    a_s1 = as.numeric(unlist(lapply(parts, `[[`, "a_s1"), use.names = FALSE)),
    a_s2 = as.numeric(unlist(lapply(parts, `[[`, "a_s2"), use.names = FALSE)),
    b_s1 = as.numeric(unlist(lapply(parts, `[[`, "b_s1"), use.names = FALSE)),
    b_s2 = as.numeric(unlist(lapply(parts, `[[`, "b_s2"), use.names = FALSE)),
    stringsAsFactors = FALSE
  )
  df$a_avg[is.na(df$a_avg)] <- 0
  df$a_count[is.na(df$a_count)] <- 0
  df$b_avg[is.na(df$b_avg)] <- 0
  df$b_count[is.na(df$b_count)] <- 0
  a_int <- do.call(rbind, lapply(parts, `[[`, "a_int"))
  b_int <- do.call(rbind, lapply(parts, `[[`, "b_int"))
  a_int[is.na(a_int)] <- 0
  b_int[is.na(b_int)] <- 0

  # ---- Fold change: 0 when either side is not detected (same as the other two tables)
  df$a_b <- numeric(nrow(df))
  ok <- df$a_count > 0 & df$b_count > 0 & df$a_avg > 0 & df$b_avg > 0
  if (any(ok)) df$a_b[ok] <- dmf_divide(df$a_avg[ok], df$b_avg[ok], cfg$FloatCount)

  # ---- P value: identical to dmf_ttest_pval() (two-tailed, equal variance,
  # missing values count as 0)
  df$pval <- dmf_ttest_pval(a_int, b_int)

  # ---- Verdict
  df$tag <- rep("No change", nrow(df))
  df$tag[df$b_count <= 0] <- "A only"
  df$tag[df$a_count <= 0] <- "B only"
  sig <- !is.na(df$pval) & df$pval < alpha & df$a_count > 0 & df$b_count > 0
  df$tag[sig & df$a_b >= fold] <- "Higher in A"
  df$tag[sig & df$a_b <= 1 / fold] <- "Higher in B"

  # ---- Sort by RT and m/z so a human can check it
  ord <- order(df$rt, df$mz)
  df <- df[ord, , drop = FALSE]
  rownames(df) <- NULL
  list(df = df, a_int = a_int[ord, , drop = FALSE], b_int = b_int[ord, , drop = FALSE],
       n_shared = sum(df$src == "Shared"))
}

.dmf_sheet_diff_merged <- function(g_a, g_b, u, samples_a, samples_b) {
  d <- u$df
  n <- nrow(d)
  n_a <- length(samples_a)
  n_b <- length(samples_b)

  lab <- c("Source", paste0(g_b, " shared partner ions"), "sample (No)", "RT",
           "RT&m/z", "m/z",
           paste0(g_a, " mean intensity"), paste0(g_a, " ion count"),
           paste0(g_b, " mean intensity"), paste0(g_b, " ion count"),
           paste0(g_a, "/", g_b), "P value", "Verdict",
           paste0(g_a, " individual score"), paste0(g_a, " mean score"),
           paste0(g_b, " individual score"), paste0(g_b, " mean score"))
  n_fixed <- length(lab)
  h2 <- dmf_hdr(lab, as.list(as.numeric(samples_a)), as.list(as.numeric(samples_b)))

  # Upper grouping header: every position is looked up from lab, so inserting a
  # column later cannot shift the numbering
  h1 <- rep(NA_character_, n_fixed + n_a + n_b)
  h1[1L] <- sprintf("Merged union of the %s and %s 80%% ions (one ion per row)",
                    g_a, g_b)
  h1[match(paste0(g_a, " mean intensity"), lab)] <- paste0(g_a, " intensity")
  h1[match(paste0(g_b, " mean intensity"), lab)] <- paste0(g_b, " intensity")
  h1[n_fixed + 1L] <- paste0(g_a, " per-sample intensity")
  if (n_b > 0L) h1[n_fixed + n_a + 1L] <- paste0(g_b, " per-sample intensity")

  cols <- list(src = d$src, n_share = d$n_share,
               no_int = d$no_int, rt = d$rt, rt_mz = d$rt_mz,
               mz = d$mz, a_avg = d$a_avg, a_count = d$a_count,
               b_avg = d$b_avg, b_count = d$b_count, a_b = d$a_b,
               pval = d$pval, tag = d$tag,
               a_s1 = d$a_s1, a_s2 = d$a_s2, b_s1 = d$b_s1, b_s2 = d$b_s2)
  for (j in seq_len(n_a)) cols[[paste0("a", j)]] <- u$a_int[, j]
  for (j in seq_len(n_b)) cols[[paste0("b", j)]] <- u$b_int[, j]

  stopifnot(length(cols) == length(h2))

  # "Group A+Group B merged ions" is 26 characters, inside Excel's 31-character
  # limit; the earlier "merged diff. ions" wording overflowed and was silently
  # truncated to "...merged diff. io".
  dmf_sheet(sprintf("%s+%s merged ions", g_a, g_b), list(h1, h2), cols)
}


# ============================================================
# 10. Writing to disk (the equivalent of the EasyExcel output structure)
# ============================================================

#' Sanitise an Excel sheet name: <= 31 chars, no [ ] : * ? / \, and unique
#'
#' With long group names (for example "Group A+Group B merged diff. ions") the
#' original logic throws inside addWorksheet and aborts the whole export, so a
#' sanitise-and-deduplicate step is added here.
dmf_sheet_name <- function(name, used = character(0)) {
  nm <- gsub("[\\[\\]:*?/\\\\]", "_", as.character(name))
  nm <- substr(nm, 1L, 31L)
  if (!nzchar(nm)) nm <- "Sheet"
  if (nm %in% used) {
    base <- substr(nm, 1L, 28L)
    i <- 2L
    while (paste0(base, "_", i) %in% used) i <- i + 1L
    nm <- paste0(base, "_", i)
  }
  nm
}

#' Turn "%" into "pct" for file names (a literal % is awkward in shells and URLs)
dmf_file_tag <- function(x) gsub("%", "pct", x, fixed = TRUE)

#' Write a list of dmf_sheet objects to xlsx
#'
#' Header rows are written row by row (numeric/text types preserved) and each data
#' block is written in one go: all-numeric columns take the matrix path, mixed
#' columns take the data.frame path.
#' Note: openxlsx::writeData() does not treat a string starting with "=" as a
#' formula (it becomes a shared string with no <f> node); a real formula needs
#' writeFormula(). So every statistic (the P value, for instance) is computed as a
#' number in R and written as such, never as a formula string.
dmf_write_sheets <- function(sheets, path) {
  wb <- openxlsx::createWorkbook()
  used <- character(0)
  for (sh in sheets) {
    sname <- dmf_sheet_name(sh$name, used)
    used <- c(used, sname)
    openxlsx::addWorksheet(wb, sname)
    r <- 1L
    for (h in sh$header) {
      df <- as.data.frame(as.list(h), stringsAsFactors = FALSE,
                          check.names = FALSE, optional = TRUE)
      openxlsx::writeData(wb, sname, df, startCol = 1L, startRow = r,
                          colNames = FALSE, keepNA = FALSE)
      r <- r + 1L
    }
    cols <- sh$cols
    if (length(cols) > 0L && length(cols[[1]]) > 0L) {
      all_num <- all(vapply(cols, function(x) is.numeric(x) || is.integer(x), logical(1)))
      if (all_num) {
        m <- do.call(cbind, cols)
        openxlsx::writeData(wb, sname, m, startCol = 1L, startRow = r,
                            colNames = FALSE, keepNA = FALSE)
      } else {
        df <- as.data.frame(cols, stringsAsFactors = FALSE, check.names = FALSE,
                            optional = TRUE)
        openxlsx::writeData(wb, sname, df, startCol = 1L, startRow = r,
                            colNames = FALSE, keepNA = FALSE)
      }
    }
  }
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  invisible(path)
}


# ============================================================
# 11. Main pipeline (IonCalculator.Process / p80CompareWith / mergeDiff)
# ============================================================

#' Complete the configuration: parameters not exposed in the UI come from
#' default_config
dmf_merge_config <- function(config = NULL) {
  base <- default_config
  if (!is.null(config)) {
    for (nm in names(config)) if (!is.null(config[[nm]])) base[[nm]] <- config[[nm]]
  }
  need <- c("ErrorRange", "ErrorRangeInGroups", "FloatCount", "NullCellValue",
            "p50IonPercent", "p80IonPercent", "m1", "m2", "m3",
            "p50IntensityRange", "p50IntensityValue", "p50RelativeIntensitySplit",
            "p50RelativeIntensityRange1", "p50RelativeIntensityValue1",
            "p50RelativeIntensityRange2", "p50RelativeIntensityValue2",
            "p50CountRange", "p50CountValue",
            "intensityRange", "intensityValue", "relativeIntensitySplit",
            "relativeIntensityRange1", "relativeIntensityValue1",
            "relativeIntensityRange2", "relativeIntensityValue2",
            "countRange", "countValue")
  miss <- setdiff(need, names(base))
  if (length(miss) > 0L) stop("Configuration is missing fields: ",
                              paste(miss, collapse = ", "))

  # ---- Keep the 50% scoring table in step with the all-ion table -------------
  # The original Java build carried a separate table for the 50% pass, and the R
  # port reproduced that by shipping two identical sets of defaults. The moment a
  # caller overrides only one side (the UI exposes the all-ion table, and the CLI
  # accepts any subset of keys in --params), the two result sheets would silently
  # be scored with different tables -- the same number would mean two things.
  # So: whenever an all-ion table is supplied and its 50% counterpart is not,
  # mirror it. Supplying both explicitly still wins, which is what reproducing a
  # customised original run needs.
  mirror <- c(intensityRange = "p50IntensityRange",
              intensityValue = "p50IntensityValue",
              countRange = "p50CountRange",
              countValue = "p50CountValue",
              relativeIntensitySplit = "p50RelativeIntensitySplit",
              relativeIntensityRange1 = "p50RelativeIntensityRange1",
              relativeIntensityValue1 = "p50RelativeIntensityValue1",
              relativeIntensityRange2 = "p50RelativeIntensityRange2",
              relativeIntensityValue2 = "p50RelativeIntensityValue2")
  for (src in names(mirror)) {
    dst <- mirror[[src]]
    if (!is.null(config[[src]]) && is.null(config[[dst]])) base[[dst]] <- base[[src]]
  }

  # MatrixPick / ClusterRtTol decide whether the run matches the original Java
  # output or the v1.0.4 defaults. Reject typos instead of letting a misspelt
  # "first" fall through to the intensity-based rule.
  if (!is.null(base$MatrixPick) && !base$MatrixPick %in% c("max", "first")) {
    stop("MatrixPick must be \"max\" or \"first\", got: ", base$MatrixPick,
         call. = FALSE)
  }
  if (!is.null(base$ErrorRangeUnit) && !base$ErrorRangeUnit %in% c("ppm", "Da")) {
    stop("ErrorRangeUnit must be \"ppm\" or \"Da\", got: ", base$ErrorRangeUnit,
         call. = FALSE)
  }
  base
}

#' Process one group: read -> build the matrix -> 50%/80% filter and dedup ->
#' score -> isotopes
#'
#' @param path path to that group's Excel file
#' @param group_name group name (Group A / Group B)
#' @param cfg configuration already completed
#' @param verbose whether to print progress
#' @param progress optional callback function(frac, detail); frac is the completion
#'   fraction of the whole run
#' @param frac_from,frac_to progress interval of this group
dmf_process_group <- function(path, group_name, cfg, verbose = TRUE,
                              progress = NULL, frac_from = 0, frac_to = 1) {
  step <- function(f, detail) {
    if (is.function(progress)) {
      progress(frac_from + f * (frac_to - frac_from), detail)
    }
    if (verbose) message(sprintf("[%s] %s", group_name, detail))
  }
  t0 <- Sys.time()
  step(0.02, "Reading the data file")
  rd <- dmf_read_samples(path)

  step(0.18, sprintf("Building the matrix (%d ions / %d samples)",
                     nrow(rd$ions), length(rd$sample_names)))
  pick_cfg <- cfg$MatrixPick
  if (is.null(pick_cfg) || !length(pick_cfg) || is.na(pick_cfg)) pick_cfg <- "first"
  rt_tol <- cfg$ClusterRtTol
  if (is.null(rt_tol) || !length(rt_tol) || !is.numeric(rt_tol) ||
      is.na(rt_tol) || rt_tol < 0) rt_tol <- 0
  ions <- dmf_create_matrix(rd$ions, length(rd$sample_names), cfg$ErrorRange,
                            cfg$FloatCount, pick_cfg, rt_tol,
                            unit = cfg$ErrorRangeUnit)

  n_sample <- length(rd$sample_names)
  # 50% threshold: (int)(p50 * n) truncated; 80% threshold: (int)ceil(p80 * n)
  thr50 <- as.integer(cfg$p50IonPercent * n_sample)
  thr80 <- as.integer(ceiling(cfg$p80IonPercent * n_sample))
  p80_str <- sprintf("%d%%", as.integer(cfg$p80IonPercent * 100))
  if (verbose) {
    message(sprintf("[%s] read done, %d samples, minimum occurrence count: %s = %d",
                    group_name, n_sample, p80_str, thr80))
  }

  # ---- 50% ----
  step(0.50, "Filtering and deduplicating the 50% / 80% ions")
  idx50 <- which(ions$count >= thr50)
  idx50 <- idx50[dmf_sort_by_count(ions$count[idx50])]
  idx50 <- dmf_distinct_ions(idx50, ions$rt_mz, cfg$ErrorRange,
                             mz = ions$mz[idx50], unit = cfg$ErrorRangeUnit)
  p50_ions <- dmf_subset_ions(ions, idx50)

  # ---- 80% ----
  idx80 <- which(ions$count >= thr80)
  idx80 <- idx80[dmf_sort_by_count(ions$count[idx80])]
  idx80 <- dmf_distinct_ions(idx80, ions$rt_mz, cfg$ErrorRange,
                             mz = ions$mz[idx80], unit = cfg$ErrorRangeUnit)
  p80_ions <- dmf_subset_ions(ions, idx80)

  if (verbose) {
    message(sprintf("[%s] %d p50 ions, %d p80 ions", group_name,
                    length(idx50), length(idx80)))
  }

  # ---- Scoring ----
  step(0.62, "Scoring the 50% ions individually")
  p50_score <- dmf_score_p50(idx50, ions, cfg$ErrorRange, cfg)
  step(0.72, "Scoring all ions on both dimensions")
  ion_score <- dmf_score_all_ions(ions, cfg$ErrorRange, cfg)
  # "Mean score" in the summary is the same ion's mean score on the rtMz dimension
  p50_score$avg_score_by_rt <- ion_score$rt_mz_avg[idx50]

  # ---- Isotopes ----
  step(0.88, "Isotope search for M+1 / M+2 / M+3")
  iso <- dmf_calc_isotopes(ions, cfg$ErrorRange, cfg)

  step(1, sprintf("Group processed, %.1f s elapsed",
                  as.numeric(difftime(Sys.time(), t0, units = "secs"))))

  list(
    name = group_name,
    sample_names = rd$sample_names,
    ions = ions,
    p50_idx = idx50, p80_idx = idx80,
    p50_ions = p50_ions, p80_ions = p80_ions,
    p50_score = p50_score, ion_score = ion_score, isotopes = iso,
    thr50 = thr50, thr80 = thr80, p80_str = p80_str,
    sheets = c(
      .dmf_sheet_p50_p80_3(group_name, p80_str, ions, idx50, idx80, rd$sample_names),
      .dmf_sheet_scoring(group_name, p50_score, ion_score),
      list(.dmf_sheet_isotope(group_name, iso))
    )
  )
}

#' The three within-group sheets (distribution / 50% / 80%)
.dmf_sheet_p50_p80_3 <- function(g, p80_str, ions, idx50, idx80, sample_names) {
  n_s <- length(sample_names)
  cols_base <- c(
    list(no_int = ions$no_int, rt = ions$rt, rt_mz = ions$rt_mz, mz = ions$mz,
         dash = rep(NA_character_, nrow(ions))),
    stats::setNames(lapply(seq_len(n_s), function(j) ions$mat[, j, drop = TRUE]),
                    paste0("s", seq_len(n_s))),
    list(count = ions$count, avg = ions$avg)
  )
  list(
    dmf_sheet(paste0(g, " ion distribution"),
              list(dmf_hdr(list("sample", "RT", "RT&m/z", "m/z", "-"),
                           as.list(as.numeric(sample_names)),
                           list("Count", "Mean intensity"))),
              cols_base),
    dmf_sheet(paste0(g, " 50% ions by frequency"),
              list(c("Sample (No)", "RT", "RT&m/z", "m/z", "Mean intensity",
                     "Ion count")),
              dmf_cols_ion_table(ions, idx50)),
    dmf_sheet(paste0(g, " ", p80_str, " ions by frequency"),
              list(c("Sample (No)", "RT", "RT&m/z", "m/z", "Mean intensity",
                     "Ion count")),
              dmf_cols_ion_table(ions, idx80))
  )
}

#' Run the whole pipeline and write every result file
#'
#' Output (the original file and sheet naming, now in English):
#'   <A>_filtered_50pct_and_80pct_ions.xlsx   (3 sheets)
#'   <A>_ion_scores.xlsx                     (3 sheets)
#'   <A>_isotope_search.xlsx                 (1 sheet)
#'   <A>_80pct_ions_vs_<B>_all_ions.xlsx     (1 sheet)
#'   <A>_vs_<B>_differential_ions.xlsx       (2-3 sheets: A view, B view, merged)
#'   group B likewise
#'
#' @param file_a,file_b paths to the two groups' Excel files
#' @param output_dir output directory (created when missing)
#' @param config configuration; default_config when omitted
#' @param group_names group names, default c("Group A", "Group B")
#' @param verbose whether to print progress
#' @param progress optional callback function(frac, detail)
#' @return list(groups, diff, files, p80_str)
dmetfinder_run <- function(file_a, file_b, output_dir, config = NULL,
                           group_names = c("Group A", "Group B"), verbose = TRUE,
                           progress = NULL) {
  cfg <- dmf_merge_config(config)
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  g_a <- group_names[1]
  g_b <- group_names[2]
  step <- function(frac, detail) if (is.function(progress)) progress(frac, detail)

  ga <- dmf_process_group(file_a, g_a, cfg, verbose, progress, 0, 0.42)
  gb <- dmf_process_group(file_b, g_b, cfg, verbose, progress, 0.42, 0.84)

  # ---- Cross-group comparison: 80% ions vs the other group's total ions ----
  step(0.86, "Cross-group comparison: 80% ions vs the other group's total ions")
  cmp_ab <- dmf_compare_p80(ga$p80_idx, ga$ions, list(ions = gb$ions, sample_names = gb$sample_names), cfg)
  step(0.88, "Cross-group comparison (reverse)")
  cmp_ba <- dmf_compare_p80(gb$p80_idx, gb$ions, list(ions = ga$ions, sample_names = ga$sample_names), cfg)

  sheet_ab <- .dmf_sheet_p80_compare(g_a, ga$p80_str, g_b, cmp_ab, ga$ions, list(sample_names = gb$sample_names, ions = gb$ions))
  sheet_ba <- .dmf_sheet_p80_compare(g_b, gb$p80_str, g_a, cmp_ba, gb$ions, list(sample_names = ga$sample_names, ions = ga$ions))

  # ---- Differential ion summary ----
  step(0.90, "Building the differential ion summary")
  diff_ab <- dmf_merge_diff(cmp_ab, ga$ions, ga$p50_ions, ga$p50_score, ga$isotopes,
                            list(ions = gb$ions, sample_names = gb$sample_names))
  diff_ba <- dmf_merge_diff(cmp_ba, gb$ions, gb$p50_ions, gb$p50_score, gb$isotopes,
                            list(ions = ga$ions, sample_names = ga$sample_names))

  sheet_diff_ab <- .dmf_sheet_diff(g_a, g_b, ga$p80_str, diff_ab, ga$sample_names, gb$sample_names)
  sheet_diff_ba <- .dmf_sheet_diff(g_b, g_a, gb$p80_str, diff_ba, gb$sample_names, ga$sample_names)

  # ---- Merged table: union of the two tables above (one row per ion, both
  # sides' intensities side by side)
  union_diff <- dmf_union_diff(diff_ab, cmp_ab, diff_ba, cmp_ba, ga, gb, cfg)
  sheet_diff_union <- if (is.null(union_diff)) NULL else
    .dmf_sheet_diff_merged(g_a, g_b, union_diff, ga$sample_names, gb$sample_names)
  diff_sheets <- list(sheet_diff_ab, sheet_diff_ba)
  if (!is.null(sheet_diff_union)) diff_sheets <- c(diff_sheets, list(sheet_diff_union))

  # ---- Write to disk ----
  files <- character(0)
  n_out <- 9L
  w <- function(sheets, fname) {
    p <- file.path(output_dir, fname)
    dmf_write_sheets(sheets, p)
    files <<- c(files, p)
    if (verbose) message("Wrote: ", fname)
    step(0.92 + 0.08 * length(files) / n_out, paste("Writing", fname))
    p
  }
  w(ga$sheets[1:3], sprintf("%s_filtered_50pct_and_%s_ions.xlsx",
                            g_a, dmf_file_tag(ga$p80_str)))
  w(ga$sheets[4:6], sprintf("%s_ion_scores.xlsx", g_a))
  w(ga$sheets[7],   sprintf("%s_isotope_search.xlsx", g_a))
  w(list(sheet_ab), sprintf("%s_%s_ions_vs_%s_all_ions.xlsx",
                            g_a, dmf_file_tag(ga$p80_str), g_b))
  # Differential ion summary: 2 group-view sheets + 1 merged union sheet
  # (the merged sheet is omitted when there are no ions)
  w(diff_sheets, sprintf("%s_vs_%s_differential_ions.xlsx", g_a, g_b))

  w(gb$sheets[1:3], sprintf("%s_filtered_50pct_and_%s_ions.xlsx",
                            g_b, dmf_file_tag(gb$p80_str)))
  w(gb$sheets[4:6], sprintf("%s_ion_scores.xlsx", g_b))
  w(gb$sheets[7],   sprintf("%s_isotope_search.xlsx", g_b))
  w(list(sheet_ba), sprintf("%s_%s_ions_vs_%s_all_ions.xlsx",
                            g_b, dmf_file_tag(gb$p80_str), g_a))

  list(
    groups = list(A = ga, B = gb),
    diff = list(ab = diff_ab, ba = diff_ba, union = union_diff),
    compare = list(ab = cmp_ab, ba = cmp_ba),
    files = files,
    p80_str = ga$p80_str,
    sheets = list(A = ga$sheets, B = gb$sheets,
                  compare_ab = sheet_ab, compare_ba = sheet_ba,
                  diff_ab = sheet_diff_ab, diff_ba = sheet_diff_ba,
                  diff_union = sheet_diff_union)
  )
}

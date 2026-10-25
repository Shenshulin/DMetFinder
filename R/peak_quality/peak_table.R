# ============================================================
# Peak-table reading, column mapping and sample matching
# ============================================================
# Different software exports different column names. Nothing here assumes a
# fixed layout: the UI lets the user map each unified field onto an actual
# column of the uploaded file, and the guessed defaults are only suggestions.
# ============================================================

PQ_REQUIRED_FIELDS <- c("feature_id", "mz", "rt")

PQ_OPTIONAL_FIELDS <- c("sample_id", "area", "height", "polarity",
                        "charge", "software", "original_id")

pq_field_labels <- c(
  feature_id  = "feature_id (required)",
  mz          = "mz (required)",
  rt          = "rt (required)",
  sample_id   = "sample_id (optional)",
  area        = "area (optional)",
  height      = "height (optional)",
  polarity    = "polarity (optional)",
  charge      = "charge (optional)",
  software    = "software (optional)",
  original_id = "original feature id (optional)"
)

# ------------------------------------------------------------
# Read csv / tsv / txt / xlsx / xls
# ------------------------------------------------------------
pq_read_table <- function(path, original_name = NULL) {
  nm <- if (is.null(original_name)) path else original_name
  ext <- tolower(tools::file_ext(nm))

  if (ext %in% c("xlsx", "xls")) {
    df <- as.data.frame(readxl::read_excel(path), stringsAsFactors = FALSE,
                        check.names = FALSE)
    return(df)
  }

  if (ext %in% c("csv", "tsv", "txt")) {
    first <- readLines(path, n = 1, warn = FALSE, encoding = "UTF-8")
    sep <- if (grepl("\t", first)) "\t"
           else if (grepl(";", first) && !grepl(",", first)) ";"
           else ","
    df <- utils::read.table(path, header = TRUE, sep = sep, quote = "\"",
                            stringsAsFactors = FALSE, check.names = FALSE,
                            comment.char = "", fileEncoding = "UTF-8-BOM")
    return(as.data.frame(df))
  }

  stop("Unsupported peak table format: .", ext,
       " (supported: csv, tsv, txt, xlsx, xls)")
}

# ------------------------------------------------------------
# Guess which column plays which role
# ------------------------------------------------------------
pq_norm_name <- function(x) gsub("[^a-z0-9]", "", tolower(x))

pq_guess_mapping <- function(cols) {
  nc <- pq_norm_name(cols)

  pick <- function(patterns, exclude = integer(0)) {
    for (p in patterns) {
      hit <- which(grepl(p, nc))
      hit <- setdiff(hit, exclude)
      if (length(hit) > 0) return(cols[hit[1]])
    }
    ""
  }

  feature_id <- pick(c("^featureid$", "^feature$", "^fid$", "^peakid$",
                       "^alignmentid$", "^rowid$", "^id$", "^index$",
                       "featureid", "rowid"))
  mz <- pick(c("^mz$", "^mzmed$", "^averagemz$", "^mzv$",
               "precursormz", "mz"), exclude = which(cols == feature_id))
  rt <- pick(c("^rt$", "^rtmed$", "^averagert$", "^apexrt$",
               "^retentiontime$", "retentiontime", "averagert", "rt"),
             exclude = which(cols %in% c(feature_id, mz)))
  sample_id <- pick(c("^sampleid$", "^sample$", "^samplename$", "^filename$",
                      "^file$", "^sourcefile$", "^rawfile$", "sample", "file"),
                    exclude = which(cols %in% c(feature_id, mz, rt)))
  # NOTE: deliberately anchored patterns only. An MS-DIAL alignment export
  # carries one "<sample name> Height" column per sample; a loose "height"
  # match would silently bind the optional height field to a single sample.
  area <- pick(c("^area$", "^averagearea$", "^meanarea$", "^peakarea$"))
  height <- pick(c("^height$", "^averageheight$", "^meanheight$", "^peakheight$"))
  polarity <- pick(c("^polarity$", "^ionmode$", "^mode$", "polarity"))
  charge <- pick(c("^charge$", "^z$", "charge"))
  software <- pick(c("^software$", "^tool$", "^program$", "software"))
  original_id <- pick(c("^originalid$", "^rawid$", "^originalfeatureid$", "original"))

  list(feature_id = feature_id, mz = mz, rt = rt, sample_id = sample_id,
       area = area, height = height, polarity = polarity, charge = charge,
       software = software, original_id = original_id)
}

# ------------------------------------------------------------
# Apply the mapping -> standardised feature table
# ------------------------------------------------------------
# Returns list(ok = data.frame, bad = data.frame, errors = character()).
# The apex RT is converted to MINUTES here (rt_min); the original value and
# unit are kept for the report.
pq_standardize_features <- function(df, mapping, rt_unit = "min") {
  errors <- character()

  used <- unlist(mapping[PQ_REQUIRED_FIELDS], use.names = FALSE)
  if (any(!nzchar(used))) {
    miss <- PQ_REQUIRED_FIELDS[!nzchar(used)]
    errors <- c(errors, paste0("Required field not mapped: ",
                               paste(miss, collapse = ", ")))
  }
  if (length(used) == 3 && anyDuplicated(used)) {
    errors <- c(errors, "The same column cannot be mapped to two required fields.")
  }
  if (length(errors) > 0) {
    return(list(ok = NULL, bad = NULL, errors = errors))
  }

  get_col <- function(field) {
    col <- mapping[[field]]
    if (is.null(col) || !nzchar(col) || !col %in% names(df)) return(rep(NA, nrow(df)))
    df[[col]]
  }

  fac <- if (identical(rt_unit, "sec")) 1 / 60 else 1

  out <- data.frame(
    row             = seq_len(nrow(df)),
    feature_id      = as.character(get_col("feature_id")),
    mz              = suppressWarnings(as.numeric(get_col("mz"))),
    rt_input        = suppressWarnings(as.numeric(get_col("rt"))),
    rt_unit         = rt_unit,
    sample_id       = as.character(get_col("sample_id")),
    area            = suppressWarnings(as.numeric(get_col("area"))),
    height          = suppressWarnings(as.numeric(get_col("height"))),
    polarity        = as.character(get_col("polarity")),
    charge          = suppressWarnings(as.numeric(get_col("charge"))),
    software        = as.character(get_col("software")),
    original_id     = as.character(get_col("original_id")),
    stringsAsFactors = FALSE
  )

  out$rt_min <- out$rt_input * fac

  bad_reason <- rep(NA_character_, nrow(out))
  bad_reason[is.na(out$feature_id) | !nzchar(trimws(out$feature_id))] <- "feature_id is empty"
  bad_reason[is.na(bad_reason) & (is.na(out$mz) | out$mz <= 0)] <- "mz is missing or <= 0"
  bad_reason[is.na(bad_reason) & (is.na(out$rt_min) | out$rt_min < 0)] <- "rt is missing or negative"

  bad <- out[!is.na(bad_reason), , drop = FALSE]
  bad$reason <- bad_reason[!is.na(bad_reason)]
  ok <- out[is.na(bad_reason), , drop = FALSE]
  rownames(ok) <- NULL

  # de-duplicate identical feature_id x sample_id rows (keep the first, report)
  dup_key <- paste(ok$feature_id, ok$sample_id)
  dup <- duplicated(dup_key)
  if (any(dup)) {
    dropped <- ok[dup, , drop = FALSE]
    dropped$reason <- "duplicated feature_id x sample_id (first occurrence kept)"
    bad <- rbind(bad, dropped)
    ok <- ok[!dup, , drop = FALSE]
  }

  ok$row_key <- seq_len(nrow(ok))
  list(ok = ok, bad = bad, errors = character())
}

# ------------------------------------------------------------
# Aligned-table support: replicate each feature once per raw file
# ------------------------------------------------------------
# An MS-DIAL / MZmine alignment result is ONE ROW PER FEATURE: the m/z and RT
# are the average (representative) values across the cohort and there is no
# sample column. To score such a feature we have to look it up in every raw
# file, i.e. expand the table to feature x sample before running the pipeline.
# Nothing downstream changes: XIC extraction, boundary detection and scoring
# only ever see ordinary (feature_id, mz, rt, sample_id) rows.
#
# feat            : standardised data.frame from pq_standardize_features()$ok
# files           : character vector of raw file paths
# sample_names    : optional display names (default: file name without extension)
# per_sample_rt   : optional data.frame(feature_id, sample_id, rt) holding the
#                   RT measured in EACH sample by the source software. When a
#                   (feature, sample) pair is present there, that RT replaces
#                   the cohort average for the search, and the row records
#                   rt_source = "per_sample_override". Pairs without an entry
#                   keep the cohort average and say so. This is deliberately
#                   an explicit table instead of a guess: an aligned export
#                   names its per-sample columns differently in every tool,
#                   and inventing a mapping would silently change the search
#                   window.
pq_expand_features <- function(feat, files, sample_names = NULL,
                               per_sample_rt = NULL) {
  if (is.null(feat) || nrow(feat) == 0) return(feat)
  if (is.null(files) || length(files) == 0) return(feat)

  nm <- if (is.null(sample_names)) {
    sub("\\.(raw|mzml|mzxml)$", "", basename(files), ignore.case = TRUE)
  } else {
    as.character(sample_names)
  }

  n_f <- nrow(feat)
  idx <- rep(seq_len(n_f), times = length(files))
  out <- feat[idx, , drop = FALSE]
  out$sample_id <- rep(nm, each = n_f)
  out$aligned   <- TRUE
  # default: every row is evaluated at the cohort-average RT
  out$rt_source <- "cohort_average"

  if (!is.null(per_sample_rt) && nrow(per_sample_rt) > 0) {
    need <- c("feature_id", "sample_id", "rt")
    if (!all(need %in% names(per_sample_rt))) {
      stop("per_sample_rt must have the columns: ",
           paste(need, collapse = ", "), call. = FALSE)
    }
    key_out <- paste(out$feature_id, out$sample_id, sep = "\r")
    key_rt  <- paste(as.character(per_sample_rt$feature_id),
                     as.character(per_sample_rt$sample_id), sep = "\r")
    pos <- match(key_out, key_rt)
    rt_val <- suppressWarnings(as.numeric(per_sample_rt$rt))
    if ("rt_unit" %in% names(per_sample_rt)) {
      # per-entry unit wins when the file states one
      f <- ifelse(tolower(as.character(per_sample_rt$rt_unit)) %in% "sec", 1 / 60, 1)
      rt_val <- rt_val * f
    } else if ("rt_unit" %in% names(feat) && identical(feat$rt_unit[1], "sec")) {
      rt_val <- rt_val / 60
    }
    hit <- !is.na(pos) & !is.na(rt_val[pos])
    if (any(hit)) {
      out$rt_min[hit] <- rt_val[pos[hit]]
      out$rt_input[hit] <- rt_val[pos[hit]]
      out$rt_source[hit] <- "per_sample_override"
    }
  }

  out$row_key   <- seq_len(nrow(out))
  rownames(out) <- NULL
  out
}

# ------------------------------------------------------------
# Sample <-> file matching
# ------------------------------------------------------------
pq_norm_key <- function(x) {
  x <- tolower(basename(as.character(x)))
  x <- sub("\\.(raw|mzml|mzxml)$", "", x)
  gsub("[^a-z0-9]", "", x)
}

# files: character vector of full paths
# samples: unique sample ids found in the peak table
# manual: optional data.frame(sample_id, file) overriding auto matching
pq_match_samples <- function(samples, files, manual = NULL) {
  file_key <- pq_norm_key(files)
  out <- lapply(samples, function(s) {
    if (!is.null(manual) && s %in% manual$sample_id) {
      hit <- manual$file[manual$sample_id == s][1]
      idx <- which(basename(files) == hit | files == hit)
      if (length(idx) == 1) {
        return(data.frame(sample_id = s, file = files[idx],
                          match = "manual", n_candidates = 1L,
                          stringsAsFactors = FALSE))
      }
      return(data.frame(sample_id = s, file = NA_character_, match = "none",
                        n_candidates = 0L, stringsAsFactors = FALSE))
    }
    if (is.na(s) || !nzchar(s)) {
      return(data.frame(sample_id = s, file = NA_character_,
                        match = "none", n_candidates = 0L,
                        stringsAsFactors = FALSE))
    }
    key <- pq_norm_key(s)
    exact <- which(file_key == key)
    if (length(exact) == 1) {
      return(data.frame(sample_id = s, file = files[exact], match = "exact",
                        n_candidates = 1L, stringsAsFactors = FALSE))
    }
    if (length(exact) > 1) {
      return(data.frame(sample_id = s, file = NA_character_,
                        match = "ambiguous", n_candidates = length(exact),
                        stringsAsFactors = FALSE))
    }
    part <- which(mapply(function(fk) grepl(key, fk, fixed = TRUE) ||
                           grepl(fk, key, fixed = TRUE), file_key))
    if (length(part) == 1) {
      return(data.frame(sample_id = s, file = files[part], match = "contains",
                        n_candidates = 1L, stringsAsFactors = FALSE))
    }
    data.frame(sample_id = s, file = NA_character_,
               match = if (length(part) > 1) "ambiguous" else "none",
               n_candidates = length(part), stringsAsFactors = FALSE)
  })
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

# Manual mapping file: columns sample_id + file
pq_read_sample_map <- function(path) {
  df <- pq_read_table(path)
  nm <- pq_norm_name(names(df))
  si <- which(nm %in% c("sampleid", "sample", "samplename"))[1]
  fi <- which(nm %in% c("file", "filename", "rawfile", "path"))[1]
  if (is.na(si) || is.na(fi)) {
    stop("Sample map must contain a sample_id column and a file column.")
  }
  data.frame(sample_id = as.character(df[[si]]),
             file = as.character(df[[fi]]),
             stringsAsFactors = FALSE)
}

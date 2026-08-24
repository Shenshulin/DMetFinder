# ============================================================
# DMetFinder Utility Functions
# ============================================================

#' Read raw data Excel file
#' Format: 6 columns per sample (Sample(No), RT, RT&m/z, m/z, Intensity, NaN)
#' @param filepath Path to the Excel file
#' @return List containing ion data for each sample
read_raw_data <- function(filepath) {
  # Read Excel without headers
  df <- read_excel(filepath, col_names = FALSE)
  
  # First row contains column names, skip it
  data <- df[-1, ]
  
  # Determine number of samples (6 columns per sample)
  ncols <- ncol(data)
  n_samples <- ceiling(ncols / 6)
  
  samples <- list()
  sample_ids <- c()
  
  for (i in 1:n_samples) {
    start_col <- (i - 1) * 6 + 1
    if (start_col > ncols) break
    
    # Extract the 5 columns of data for this sample (Sample, RT, RT&m/z, m/z, Intensity)
    sample_id <- as.numeric(data[[start_col]])
    rt <- as.numeric(data[[start_col + 1]])
    rt_mz <- as.numeric(data[[start_col + 2]])
    mz <- as.numeric(data[[start_col + 3]])
    intensity <- as.numeric(data[[start_col + 4]])
    
    # Remove invalid rows
    valid <- !is.na(sample_id) & !is.na(rt_mz) & !is.na(mz) & !is.na(intensity)
    
    sample_df <- data.frame(
      Sample = sample_id[valid],
      RT = rt[valid],
      RT_mz = rt_mz[valid],
      mz = mz[valid],
      Intensity = intensity[valid],
      stringsAsFactors = FALSE
    )
    
    sid <- unique(sample_id[valid])
    if (length(sid) > 0) {
      samples[[as.character(sid[1])]] <- sample_df
      sample_ids <- c(sample_ids, sid[1])
    }
  }
  
  return(list(samples = samples, sample_ids = sample_ids))
}

#' Find indices of values within error range in a sorted vector
#' @param sorted_vec Sorted numeric vector
#' @param targets Target value vector
#' @param error_range Error range (absolute value)
#' @return Integer vector, -1 indicates no match
fast_match <- function(sorted_vec, targets, error_range) {
  n <- length(targets)
  result <- integer(n)
  
  # Use findInterval to find the nearest position for each target
  pos <- findInterval(targets, sorted_vec, all.inside = FALSE)
  
  for (i in 1:n) {
    found <- -1L
    # Check positions pos[i] and pos[i]+1
    if (pos[i] >= 1 && pos[i] <= length(sorted_vec)) {
      if (abs(sorted_vec[pos[i]] - targets[i]) <= error_range) {
        found <- pos[i]
      }
    }
    if (found == -1L && pos[i] >= 1 && pos[i] + 1 <= length(sorted_vec)) {
      if (abs(sorted_vec[pos[i] + 1] - targets[i]) <= error_range) {
        found <- pos[i] + 1
      }
    }
    result[i] <- found
  }
  
  return(result)
}

#' Merge samples by RT&m/z
#' Uses each sample's ions as reference, matches against other samples within RT&m/z error range
#' @param data Data read by read_raw_data
#' @param error_range Matching error range
#' @return Merged data frame
#'   Structure: sample(reference sample), RT, RT&m/z, m/z, intensity columns per sample..., count, avg_intensity
merge_samples <- function(data, error_range = 0.002) {
  samples <- data$samples
  sample_ids <- data$sample_ids
  n_samples <- length(sample_ids)
  
  # Pre-sort RT&m/z for all samples (for fast matching)
  sorted_rt_mz <- vector("list", n_samples)
  sorted_intensity <- vector("list", n_samples)
  sort_order <- vector("list", n_samples)
  
  for (j in 1:n_samples) {
    s <- samples[[as.character(sample_ids[j])]]
    ord <- order(s$RT_mz)
    sorted_rt_mz[[j]] <- s$RT_mz[ord]
    sorted_intensity[[j]] <- s$Intensity[ord]
    sort_order[[j]] <- ord
  }
  
  # Generate merged rows for each reference sample
  result_list <- list()
  
  for (ref_idx in 1:n_samples) {
    ref_s <- samples[[as.character(sample_ids[ref_idx])]]
    ref_rt_mz <- ref_s$RT_mz
    n_ref <- nrow(ref_s)
    
    # Initialize intensity matrix
    intensity_mat <- matrix(NA_real_, nrow = n_ref, ncol = n_samples)
    
    # Batch match against each target sample
    for (j in 1:n_samples) {
      # Find matching positions of reference ions in sample j's sorted RT&m/z
      match_pos <- fast_match(sorted_rt_mz[[j]], ref_rt_mz, error_range)
      valid <- match_pos > 0
      intensity_mat[valid, j] <- sorted_intensity[[j]][match_pos[valid]]
    }
    
    # Calculate count and average intensity (consistent with original software: count non-zero values, average non-zero values)
    counts <- apply(intensity_mat, 1, function(x) sum(!is.na(x) & x > 0))
    avg_intensity <- apply(intensity_mat, 1, function(x) {
      vals <- x[!is.na(x) & x > 0]
      if (length(vals) > 0) mean(vals) else 0
    })
    
    # Create result data frame
    result_df <- data.frame(
      sample = ref_s$Sample,
      RT = ref_s$RT,
      RT_mz = ref_rt_mz,
      mz = ref_s$mz,
      stringsAsFactors = FALSE
    )
    
    # Add intensity columns
    intensity_df <- as.data.frame(intensity_mat)
    names(intensity_df) <- as.character(sample_ids)
    result_df <- cbind(result_df, intensity_df)
    
    # Add count and average intensity
    result_df$count <- counts
    result_df$avg_intensity <- avg_intensity
    
    result_list[[ref_idx]] <- result_df
  }
  
  # Combine results from all reference samples
  result <- do.call(rbind, result_list)
  
  return(result)
}

#' Scoring function - map values to scores based on ranges
#' @param values Numeric vector
#' @param ranges Range boundaries
#' @param scores Corresponding scores
#' @return Score vector
score_mapping <- function(values, ranges, scores) {
  n <- length(values)
  result <- rep(NA, n)
  
  # ranges and scores must have the same length
  # Each interval [ranges[i], ranges[i+1]) corresponds to scores[i]
  # The last interval [ranges[last], Inf) corresponds to scores[last]
  if (length(ranges) != length(scores)) {
    stop("Length of ranges must equal length of scores")
  }
  
  for (i in 1:n) {
    v <- values[i]
    if (is.na(v)) {
      result[i] <- NA
      next
    }
    # Find the interval containing v
    found <- FALSE
    for (j in 1:(length(ranges) - 1)) {
      if (v >= ranges[j] && v < ranges[j + 1]) {
        result[i] <- scores[j]
        found <- TRUE
        break
      }
    }
    if (!found) {
      # v >= last ranges value
      result[i] <- scores[length(scores)]
    }
  }
  return(result)
}

#' Ion scoring
#' @param merged Merged data
#' @param config Configuration parameters
#' @return Scored data frame
score_ions <- function(merged, config) {
  # Group by m/z and calculate average intensity of duplicate ions
  # Use m/z as lookup key
  mz_groups <- split(merged$avg_intensity, merged$mz)
  dup_avg_map <- sapply(mz_groups, mean)
  
  # Assign dup_avg to each row
  merged$dup_avg <- dup_avg_map[as.character(merged$mz)]
  merged$ratio <- merged$avg_intensity / merged$dup_avg
  
  # Intensity scoring
  merged$int_score <- score_mapping(merged$avg_intensity, 
                                     config$intensityRange, 
                                     config$intensityValue)
  
  # Count scoring
  merged$count_score <- score_mapping(merged$count, 
                                       config$countRange, 
                                       config$countValue)
  
  # Relative ion intensity scoring
  max_avg <- max(merged$avg_intensity, na.rm = TRUE)
  rel_intensity <- merged$avg_intensity / max_avg * 100
  
  # Use relativeIntensityRange1 and relativeIntensityValue1
  merged$rel_score <- score_mapping(rel_intensity, 
                                     config$relativeIntensityRange1, 
                                     config$relativeIntensityValue1)
  
  # Total score
  merged$total <- merged$int_score * merged$count_score * merged$rel_score
  
  return(merged)
}

#' Isotope search
#' For each sample's raw ion data, find M+1/M+2/M+3 isotope peaks
#' @param data Data read by read_raw_data
#' @param config Configuration parameters
#' @return Isotope search result data frame
find_isotopes <- function(data, config) {
  samples <- data$samples
  sample_ids <- data$sample_ids
  n_samples <- length(sample_ids)
  
  result_list <- list()
  
  for (j in 1:n_samples) {
    s <- samples[[as.character(sample_ids[j])]]
    n <- nrow(s)
    
    # RT&No&m/z = (sample+2000)*1000 + m/z
    rt_no_mz <- (s$Sample + 2000) * 1000 + s$mz
    s$RT_No_mz <- rt_no_mz
    
    # Theoretical M+1, M+2, M+3
    theo_m1 <- rt_no_mz + config$m1
    theo_m2 <- rt_no_mz + config$m2
    theo_m3 <- rt_no_mz + config$m3
    
    # Sort rt_no_mz for fast matching
    ord <- order(rt_no_mz)
    sorted_rt_no_mz <- rt_no_mz[ord]
    sorted_intensity <- s$Intensity[ord]
    
    # Use fast_match to batch find M+1/M+2/M+3
    match_m1 <- fast_match(sorted_rt_no_mz, theo_m1, config$ErrorRange)
    match_m2 <- fast_match(sorted_rt_no_mz, theo_m2, config$ErrorRange)
    match_m3 <- fast_match(sorted_rt_no_mz, theo_m3, config$ErrorRange)
    
    # Initialize actual values
    actual_m1 <- rep(0, n)
    actual_m2 <- rep(0, n)
    actual_m3 <- rep(0, n)
    
    # Fill actual values
    valid_m1 <- match_m1 > 0
    valid_m2 <- match_m2 > 0
    valid_m3 <- match_m3 > 0
    
    actual_m1[valid_m1] <- sorted_rt_no_mz[match_m1[valid_m1]]
    actual_m2[valid_m2] <- sorted_rt_no_mz[match_m2[valid_m2]]
    actual_m3[valid_m3] <- sorted_rt_no_mz[match_m3[valid_m3]]
    
    # Get intensities of M+1/M+2/M+3
    int_m1 <- rep(0, n)
    int_m2 <- rep(0, n)
    int_m3 <- rep(0, n)
    
    int_m1[valid_m1] <- sorted_intensity[match_m1[valid_m1]]
    int_m2[valid_m2] <- sorted_intensity[match_m2[valid_m2]]
    int_m3[valid_m3] <- sorted_intensity[match_m3[valid_m3]]
    
    # Ion intensity ratios
    ratio_m_m1 <- ifelse(int_m1 > 0, s$Intensity / int_m1, 0)
    ratio_m1_m2 <- ifelse(int_m2 > 0, int_m1 / int_m2, 0)
    ratio_m2_m3 <- ifelse(int_m3 > 0, int_m2 / int_m3, 0)
    
    # Detection flags
    is_m1 <- ifelse(actual_m1 > 0, 1, 0)
    is_m2 <- ifelse(actual_m2 > 0, 1, 0)
    is_m3 <- ifelse(actual_m3 > 0, 1, 0)
    
    result_df <- data.frame(
      sample = s$Sample,
      RT = s$RT,
      RT_mz = s$RT_mz,
      RT_No_mz = rt_no_mz,
      mz = s$mz,
      Intensity = s$Intensity,
      theo_M1 = theo_m1,
      theo_M2 = theo_m2,
      theo_M3 = theo_m3,
      actual_M1 = actual_m1,
      actual_M2 = actual_m2,
      actual_M3 = actual_m3,
      int_M1 = int_m1,
      int_M2 = int_m2,
      int_M3 = int_m3,
      ratio_M_M1 = ratio_m_m1,
      ratio_M1_M2 = ratio_m1_m2,
      ratio_M2_M3 = ratio_m2_m3,
      is_M1 = is_m1,
      is_M2 = is_m2,
      is_M3 = is_m3,
      stringsAsFactors = FALSE
    )
    
    result_list[[j]] <- result_df
  }
  
  result <- do.call(rbind, result_list)
  return(result)
}

#' Filter ions by percentage
#' @param merged Merged data
#' @param percent Filter percentage (0.8 = 80%)
#' @return Filtered data (only rows with match count >= threshold)
filter_by_percent <- function(merged, percent) {
  # Calculate minimum count required per reference sample from merged data
  # Actual logic calculates based on number of samples in the group
  # Get number of samples from the sample column
  n_samples <- length(unique(merged$sample))
  min_count <- ceiling(n_samples * percent)
  
  # Filter by sample group
  result_list <- list()
  samples <- unique(merged$sample)
  for (sid in samples) {
    subset <- merged[merged$sample == sid, ]
    filtered <- subset[subset$count >= min_count, ]
    result_list[[as.character(sid)]] <- filtered
  }
  result <- do.call(rbind, result_list)
  return(result)
}

#' Compare two groups of ions
#' @param group1 First group data (after 80% filter)
#' @param group2 Second group data (total ions or after 80% filter)
#' @param error_range Matching error range
#' @return Comparison result
compare_groups <- function(group1, group2, error_range) {
  n <- nrow(group1)
  
  # Create RT&m/z lookup table for group2
  g2_rt_mz <- group2$RT_mz
  g2_avg <- group2$avg_intensity
  g2_count <- group2$count
  
  # Find matches for each group1 ion in group2
  # Match RT&m/z within error range
  match_idx <- rep(NA, n)
  matched <- rep(FALSE, n)
  
  # Build index for each unique RT&m/z value
  unique_g2 <- unique(g2_rt_mz)
  
  # Use findInterval for fast matching
  g2_sorted <- sort(unique_g2)
  
  for (i in 1:n) {
    target <- group1$RT_mz[i]
    # Use findInterval to find the nearest match
    pos <- findInterval(target, g2_sorted)
    candidates <- c()
    if (pos > 0) candidates <- c(candidates, pos)
    if (pos < length(g2_sorted)) candidates <- c(candidates, pos + 1)
    
    for (p in candidates) {
      if (abs(g2_sorted[p] - target) <= error_range) {
        # Match found
        val <- g2_sorted[p]
        idx <- which(g2_rt_mz == val)
        if (length(idx) > 0) {
          match_idx[i] <- idx[1]
          matched[i] <- TRUE
          break
        }
      }
    }
  }
  
  # Create result
  result <- group1
  result$B_RT_mz <- NA
  result$B_avg_intensity <- NA
  result$B_count <- NA
  result$ratio <- NA
  
  result$B_RT_mz[matched] <- group2$RT_mz[match_idx[matched]]
  result$B_avg_intensity[matched] <- group2$avg_intensity[match_idx[matched]]
  result$B_count[matched] <- group2$count[match_idx[matched]]
  result$ratio[matched] <- result$avg_intensity[matched] / result$B_avg_intensity[matched]
  
  return(result)
}
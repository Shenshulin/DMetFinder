# ============================================================
# DMetFinder core algorithms
# ------------------------------------------------------------
# 本文件是原版 Java 程序 DMetFinder.exe（corvida.core.*）的忠实移植。
#
# 对齐依据：exe4j overlay 解密后的内嵌 jar 反编译源码，关键类
#   corvida.core.io.AnalysisIonListener   （数据读取、键构造）
#   corvida.core.collection.impl.IonsManager2 / Helper（区间检索、唯一化）
#   corvida.core.calc.IonCalculator       （筛选、打分、同位素、跨组比对）
#   corvida.core.utils.BigDecimalHelper / CalcTools（精度与打分语义）
#
# 与旧版 R 实现的根本差别（旧版是简化近似，会导致结果数量级不一致）：
#   1. 离子对象带 noMz / rtNoMz 两个"拼接键"，原版的全部去重与打分都建立在
#      这两个键上，旧版完全没有；
#   2. 50% / 80% 阈值筛选之后必须再跑 distinctIons() 唯一化（最多两轮），
#      旧版漏掉了这一步；
#   3. count / averageIntensity 由 MatrixRow 按"样品编号"归并得到（同一
#      样品内重复命中去重，之后求均值），旧版按参考样品展开再统计，口径不同；
#   4. 50% 离子打分与全离子打分是两套独立打分表（后者还分 noMz / rtMz 两个
#      维度），旧版只实现了一套 5 列的简化打分。
#
# 数值语义上用 double 复刻 BigDecimal：
#   truncate(x)  = (x + 1e-10) 向零截断到 8 位小数
#   divideD(a,b) = a / b 四舍五入（HALF_UP）到 FloatCount(=7) 位
# 区间检索复刻 Helper.binarySearch：窗口为 [target-e+1e-9, target+e-1e-9]
# 的开区间，命中集合按"原始下标"升序返回，findIon 取第一个。
# ============================================================


# ============================================================
# 0. 常量（与原版字面量一致）
# ============================================================

# Helper.binarySearch 里的 fixOffset = new BigDecimal("0.000000001")
.dmf_fix_offset <- 1e-9
# BigDecimalHelper.TRUNCATE_NUMBER = new BigDecimal("0.0000000001")
.dmf_truncate_num <- 1e-10
# BigDecimalHelper.truncate 的 setScale(8, DOWN)
.dmf_truncate_scale <- 1e8


# ============================================================
# 1. BigDecimal 数值语义
# ============================================================

#' 复刻 BigDecimalHelper.truncate：先加 1e-10，再向零截断到 8 位小数
#'
#' 关键点：原版的 BigDecimal 是 double 的**精确十进制展开**（new BigDecimal(double)
#' 的语义），不是"最短往返表示"。例如单元格 81132.26642 的实际 double 是
#' 81132.266419999898…，加 1e-10 之后仍然没有跨过 81132.26642，
#' 因此原版截断得到 81132.26641999。若直接用 double 做 +1e-10 的算术，
#' 加法会把结果舍入到下一个 double（=81132.26642），从而截断出不同的值。
#' 所以这里取 20 位定点字符串做十进制判断：小数第 9 位之后的部分记为 rest，
#' rest + 0.01 >= 1 说明加 1e-10 会进位。
#'
#' @param x numeric 向量（|x| < 9e15）
#' @return numeric 向量，值为 8 位小数
dmf_truncate <- function(x) {
  if (length(x) == 0L) return(numeric(0))
  out <- rep(NA_real_, length(x))
  ok <- !is.na(x)
  if (!any(ok)) return(out)
  if (any(abs(x[ok]) >= 9e15)) stop("数值超出 truncate 的定点处理范围")

  ax <- abs(x[ok])
  # 19 位整数部分（左补零）+ '.' + 20 位小数，总宽 40，位置固定
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

#' BigDecimal.divide(…, digits, RoundingMode.HALF_UP) 的向量化版本
#'
#' R 的 round()/sprintf() 都是 banker's rounding（四舍六入五成双），
#' 例如 13.23828125 保留 7 位会得到 13.2382812，而原版 HALF_UP 要 13.2382813。
#' 这里取 digits + 9 位十进制展开后手工判断第 digits+1 位是否 >= 5 再进位。
#' @param a,b numeric 向量（长度可回收）
#' @param digits 小数位，默认取 config$FloatCount
dmf_divide <- function(a, b, digits = 7L) {
  if (any(b == 0, na.rm = TRUE)) {
    stop("divideD 的除数为 0：原版在此处抛出 ArithmeticException，请检查打分统计强度")
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

#' CalcTools.Score：从后往前找第一个 v >= range[i]，返回 scores[i]，否则 0
#'
#' 注意 range 必须是升序；命中多个区间时取下标最大的那个（原版是倒序扫描）。
#' @param v numeric 向量
#' @param range 升序区间下界
#' @param scores 与 range 等长的分值
dmf_score <- function(v, range, scores) {
  if (length(range) != length(scores)) {
    stop("打分区间与分值数量不一致（原版配置校验同样会拒绝）")
  }
  idx <- findInterval(v, range)
  out <- numeric(length(v))
  hit <- !is.na(idx) & idx > 0L
  if (any(hit)) out[hit] <- scores[idx[hit]]
  out
}

#' BigDecimal.toString() 在整数场景下的等价物（用于拼接 no / rt 字符串）
#' @param x numeric 向量，要求全部为整数
dmf_integer_string <- function(x) {
  if (any(is.na(x))) stop("样品编号 / 保留时间为空，无法构造原版要求的拼接键")
  if (any(x != round(x))) {
    stop("原版用字符串拼接构造 RT&No&m/z 键（rt.toString()+no+mz），" ,
         "要求 RT 与样品编号都是整数；当前数据存在非整数取值，原版在此处会抛 ",
         "NumberFormatException。请先把 RT 取整后再运行。")
  }
  if (any(abs(x) >= 1e15)) stop("样品编号 / 保留时间超出整数可表示范围")
  sprintf("%.0f", x)
}

#' 把固定 8 位小数的十进制字符串拆成「整数部分 + 小数部分 × 1e8」
#'
#' 拼出来的 rt&no&m/z 键量级可达 1e8，转成 double 后第 8 位小数已经不可靠
#' （ulp 约 3e-8）。原版用 BigDecimal 做精确十进制比较，所以这里把键拆成
#' 两个精确整数，窗口边界判定就在整数域里完成。
#'
#' @param s 由数字、可选负号与小数点组成的字符串向量
#' @param scale 小数位数，默认 8（与 dmf_truncate 的 scale 一致）
#' @return list(ip = 整数部分, f8 = 小数部分放大 scale 倍后的整数)
dmf_decimal_parts <- function(s, scale = 8L) {
  if (length(s) == 0L) return(list(ip = numeric(0), f8 = numeric(0)))
  scale <- as.integer(scale)
  if (any(is.na(s))) stop("十进制字符串为空，无法拆分")

  neg <- startsWith(s, "-")
  body <- ifelse(neg, substring(s, 2L), s)
  ip_s <- sub("\\..*$", "", body)
  fr_s <- ifelse(grepl("\\.", body, fixed = FALSE),
                 sub("^[^.]*\\.", "", body), "")
  if (any(nchar(fr_s) > scale)) {
    stop("十进制字符串的小数位超过 ", scale, " 位，无法用整数精确表示")
  }
  fr_s <- gsub(" ", "0", sprintf(paste0("%-", scale, "s"), fr_s),
               fixed = TRUE)
  ip <- suppressWarnings(as.numeric(ip_s))
  f8 <- suppressWarnings(as.numeric(fr_s))
  if (any(is.na(ip)) || any(is.na(f8))) stop("十进制字符串解析失败")
  sign <- ifelse(neg, -1, 1)
  list(ip = ip * sign, f8 = f8 * sign)
}


# ============================================================
# 2. 区间检索（复刻 Helper.binarySearch + IonsManager2.findIons）
# ============================================================

#' 计算每个 target 在升序键数组中的开区间下标
#'
#' 原版窗口：targetMin = target - error + 1e-9，targetMax = target + error - 1e-9，
#' 命中条件为 key > targetMin 且 key < targetMax。
#'
#' 注意：`rt&no&m/z` 这类拼接键的量级可达 1e8，此时 double 的 ulp（3e-8）
#' 已经大于原版的 fixOffset（1e-9），直接按 error 求出的边界会把
#' 「恰好相差 error」的邻元误纳进来。`exact = TRUE` 时改用
#' 「粗筛 + 十进制整数（单位 1e-8）精确判边界」，与 BigDecimal 比较一致。
#'
#' @param sorted_key 升序数值向量
#' @param target 查询值向量
#' @param error 容差（ErrorRange 或 ErrorRangeInGroups）
#' @param exact 是否走十进制精确判边界（键的量级超过 1e7 时必须开）
#' @param offset 查询值在比较时额外叠加的常量（如同位素的 1.00335）。
#'   精确模式下不把 offset 加进 target，而是比较 key - target 与 offset，
#'   避免 target + offset 这一步又引入一次 double 舍入。
#' @param key_parts target_parts dmf_decimal_parts() 结果（整数部分 + 8 位小数）。
#'   给了就走整数域精确比较，键量级超过 1e7 时必需。
#' @return list(lo, hi)，闭区间下标；lo > hi 表示无命中
dmf_window_bounds <- function(sorted_key, target, error, exact = FALSE, offset = 0,
                              key_parts = NULL, target_parts = NULL) {
  guard <- error - .dmf_fix_offset
  if (guard <= 0) stop("匹配容差必须大于 1e-9（原版的 fixOffset）")
  if (!isTRUE(exact)) {
    return(list(
      lo = findInterval(target + offset - guard, sorted_key) + 1L,
      hi = findInterval(target + offset + guard, sorted_key, left.open = TRUE)
    ))
  }

  # ---- 粗筛：放宽 1e-6（远超 1e-8 量级键的 ulp），保证不漏 ----
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

  # 键与 target 都是 8 位小数，乘 1e8 后是整数；
  # key - target 相减是精确的（Sterbenz），误差只来自各自 double 表示，
  # 键量级 < 3.4e7 时误差不足 0.5，round 后即原版 BigDecimal 的差值。
  e8 <- round(error * .dmf_truncate_scale)
  if (abs(error * .dmf_truncate_scale - e8) > 1e-6) {
    stop("匹配容差必须是 1e-8 的整数倍（原版按十进制精确比较）")
  }
  off8 <- round(offset * .dmf_truncate_scale)
  if (!is.null(key_parts) && !is.null(target_parts)) {
    # 整数域：integer 部分差 × 1e8 + 小数部分差，全部是精确整数
    delta <- (key_parts$ip[pos] - target_parts$ip[qidx]) * .dmf_truncate_scale +
      (key_parts$f8[pos] - target_parts$f8[qidx]) - off8
  } else {
    # key - target 相减是精确的（Sterbenz），误差只来自各自 double 表示，
    # 键量级 < 3.4e7 时误差不足 0.5，round 后即原版 BigDecimal 的差值。
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

#' 在窗口内取"下标最小"（即原版 findIon 返回的第一个）元素
#'
#' 原版把命中集合塞进 TreeMap<原始下标, Ion>，get(0) 即原始下标最小者。
#' 这里用稀疏表做 O(1) 区间最小值查询：把 (rank, 位置) 编码成一个数值，
#' 取最小即先比 rank、再比位置。rank 必须唯一，因此结果与逐元素比较一致。
#' @param sorted_key 升序键
#' @param target 查询值
#' @param error 容差
#' @param rank 与 sorted_key 等长的原始下标（互不相同）
#' @param exact 窗口边界是否走十进制精确判定
#' @param offset 比较时叠加的常量（见 dmf_window_bounds）
#' @param key_parts target_parts 键的精确十进制分解（见 dmf_window_bounds）
#' @return 整数向量，命中位置在 sorted_key 中的下标；无命中为 NA
dmf_argmin_in_window <- function(sorted_key, target, error, rank, exact = FALSE,
                                 offset = 0, key_parts = NULL,
                                 target_parts = NULL) {
  n <- length(sorted_key)
  out <- rep(NA_integer_, length(target))
  if (n == 0L || length(target) == 0L) return(out)

  b <- dmf_window_bounds(sorted_key, target, error, exact = exact, offset = offset,
                         key_parts = key_parts, target_parts = target_parts)
  ok <- b$lo <= b$hi
  if (!any(ok)) return(out)

  # 编码：enc = rank * K + 位置，K > n 保证解码无歧义；最大约 n*2^20 < 2^53
  K <- 2^ceiling(log2(n + 1))
  enc <- rank * K + seq_len(n)

  lo <- b$lo[ok]
  hi <- b$hi[ok]
  len <- hi - lo + 1L
  max_len <- max(len)

  # 稀疏表：第 j 层覆盖 2^(j-1) 个元素
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

#' 按分组求和，结果按组号对齐成长度 n 的向量（空组为 0）
.dmf_group_sum <- function(x, group, n) {
  rs <- rowsum(x, group, reorder = TRUE)
  out <- numeric(n)
  out[as.integer(rownames(rs))] <- as.numeric(rs)
  out
}

#' Helper.binarySearch 的递归版本（无容差、精确键匹配，mergeDiff 用）
#'
#' 0-based 下标逐行复刻：遇到等于 mid 的键立即返回，因此同键多元素时返回的
#' 不一定是第一个，后续调用方还需要向前展开同键区间。这一点原版行为如此，
#' 此处保持，不做"更正确"的修正。
#' @return 1-based 下标
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
# 3. 数据读取（AnalysisIonListener + IoHelper.ReadSamples）
# ============================================================

#' 读取一个分组的原始数据 Excel
#'
#' 格式：每个样品 6 列（Sample(No), RT, RT&m/z, m/z, Intensity, 空列）。
#' 原版用 EasyExcel 按"首行出现的单元格"切块，并把第一行当表头丢弃；
#' 这里按 6 列步长切块，块的存在性同样由首行判定。
#'
#' 样品名取自首行各块的 Sample(No)（与原版一致，不读表头文字），
#' 去重保序；离子列表按"样品优先"排列（先样品 1 的全部离子，再样品 2…），
#' 这一顺序会影响原版的稳定排序与 findIon 的 tie-break，必须保持。
#'
#' @param path Excel 路径
#' @param block_width 每样品列数，默认 6
#' @return list(sample_names, ions)，ions 为 data.frame：
#'   no(字符串), no_int, rt, rt_mz, no_mz, mz, rt_no_mz, intensity, col
dmf_read_samples <- function(path, block_width = 6L) {
  if (!file.exists(path)) stop("找不到数据文件：", path)

  raw <- readxl::read_excel(path, col_names = FALSE, .name_repair = "minimal")
  raw <- as.data.frame(raw, stringsAsFactors = FALSE)
  if (nrow(raw) < 2L) stop("数据文件除表头外没有数据行：", path)

  # EasyExcel 默认 headRowNumber = 1：第一行被当作表头丢弃
  data <- raw[-1L, , drop = FALSE]
  n_col <- ncol(data)

  starts <- seq.int(1L, n_col, by = block_width)
  starts <- starts[starts + 4L <= n_col]
  if (length(starts) == 0L) stop("数据文件列数不足，无法按每样品 6 列切块")

  first_no <- vapply(starts, function(s) suppressWarnings(as.numeric(data[[s]][1])), numeric(1))
  starts <- starts[!is.na(first_no)]
  first_no <- first_no[!is.na(first_no)]
  if (length(starts) == 0L) stop("首行没有任何样品编号，文件格式不符合要求")

  blocks <- lapply(seq_along(starts), function(j) {
    s <- starts[j]
    no   <- suppressWarnings(as.numeric(data[[s]]))
    rt   <- suppressWarnings(as.numeric(data[[s + 1L]]))
    rtmz <- suppressWarnings(as.numeric(data[[s + 2L]]))
    mz   <- suppressWarnings(as.numeric(data[[s + 3L]]))
    inten <- suppressWarnings(as.numeric(data[[s + 4L]]))
    ok <- !is.na(no) & !is.na(rt) & !is.na(rtmz) & !is.na(mz) & !is.na(inten)
    if (!any(ok)) return(NULL)
    data.frame(block = j, no_num = no[ok], rt = rt[ok], rt_mz_raw = rtmz[ok],
               mz_raw = mz[ok], intensity = inten[ok], stringsAsFactors = FALSE)
  })
  blocks <- blocks[!vapply(blocks, is.null, logical(1))]
  if (length(blocks) == 0L) stop("没有读到任何离子数据：", path)
  ions <- do.call(rbind, blocks)
  rownames(ions) <- NULL

  # 样品名：首行各块的 Sample(No)，去重保序（原版 HashSet + ArrayList 的顺序）
  block_names <- dmf_integer_string(first_no)
  sample_names <- unique(block_names)
  col_of_block <- match(block_names, sample_names)

  # 键构造：与原版 parseIon 一致
  no_str <- dmf_integer_string(ions$no_num)
  rt_str <- dmf_integer_string(ions$rt)
  mz <- dmf_truncate(ions$mz_raw)
  rt_mz <- dmf_truncate(ions$rt_mz_raw)
  mz_str <- sprintf("%.8f", mz)                       # BigDecimal(scale 8).toString()
  # truncate(no + mz)：拼接串已是 8 位小数，加 1e-10 再截 8 位是恒等变换，
  # 所以这里不再对 double 做一次 truncate —— 那会把 double 表示误差
  # （如 4491174.33184999979）带进来，截成 4491174.33184999。
  no_concat <- paste0(no_str, mz_str)
  no_mz <- as.numeric(no_concat)
  concat <- paste0(rt_str, no_str, mz_str)
  rt_no_mz <- as.numeric(concat)                      # new BigDecimal(rt+no+mz)

  if (any(is.na(no_mz)) || any(is.na(rt_no_mz))) {
    stop("拼接键构造失败：样品编号 / RT / m/z 的字符串拼接无法解析为数值，",
         "与手机版原版一样受 Sample(No) 位数与 RT 整数性约束")
  }

  # no&m/z（约 1e7）与 rt&no&m/z（最高约 1.9e8）这两类拼接键的量级都已接近
  # 或超过 double 的分辨极限，ulp 吃掉原版 fixOffset(1e-9) 后无法再分辨
  # 第 8 位小数。原版是 BigDecimal 十进制比较，因此额外保存
  # 「整数部分 + 8 位小数」两个精确整数，供窗口判定使用。
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
      stringsAsFactors = FALSE
    )
  )
}


# ============================================================
# 4. 强度矩阵（IonsManager2.buildIntensityMatrix + MatrixRow）
# ============================================================

#' 为每个离子里生成跨样品的强度矩阵行，并统计 count / averageIntensity
#'
#' 原版：对每个离子，以其 rtMz 为中心取 ±ErrorRange 内的全部离子，
#' 按样品编号放入 MatrixRow（同一样品先到先得），
#' count = 出现的样品数，averageIntensity = 强度和 / count（7 位 HALF_UP）。
#'
#' @param ions dmf_read_samples() 得到的离子表
#' @param n_samples 样品数
#' @param error_range 组内匹配容差
#' @param digits 均值小数位
#' @return ions 追加 count / avg / mat（n_ions × n_samples，缺测为 NA）
dmf_create_matrix <- function(ions, n_samples, error_range, digits = 7L) {
  n <- nrow(ions)
  o <- order(ions$rt_mz)
  ks <- ions$rt_mz[o]

  b <- dmf_window_bounds(ks, ks, error_range)
  w <- b$hi - b$lo + 1L
  if (any(w < 1L)) stop("存在空的匹配窗口，数据或误差范围异常")

  ion_ion <- o[rep.int(seq_len(n), w)]
  mem_ion <- o[sequence(w, from = b$lo)]
  col_mem <- ions$col[mem_ion]

  # 同一窗口内按"原始下标升序"遍历，同一样品先到先得
  ord <- order(ion_ion, mem_ion)
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
# 5. 阈值筛选与唯一化（IonCalculator.filterIons + distinctIons）
# ============================================================

#' IonsManager2.sortByCount：按 count 降序，稳定排序
dmf_sort_by_count <- function(count) {
  order(count, seq_along(count), decreasing = c(TRUE, FALSE))
}

#' 单轮唯一化
#'
#' 原版 distinctIons(ions, iStd, errorRange)：
#'   遍历 ions（按 count 降序），对每个离子在自己的键窗口里找"命中集合中
#'   排在最前的那个"（即 idxMap 值最小者），若该代表还没被占用，就保留
#'   当前离子，并把代表标记为已占用。
#' 注意保留的是"当前离子"而不是代表本身，这是原版的行为。
#'
#' @param cur 当前离子下标向量（已按 count 降序）
#' @param key 全部离子的键向量
#' @param error_range 容差
#' @return 保留的离子下标向量（保持 cur 的顺序）
dmf_distinct_pass <- function(cur, key, error_range) {
  n <- length(cur)
  if (n <= 1L) return(cur)

  kv <- key[cur]
  o <- order(kv)                 # 稳定排序；同键元素同处一个窗口，顺序无关
  ks <- kv[o]
  rank_in_cur <- o               # 每个"键有序槽位"在 cur 中的位置

  amin <- dmf_argmin_in_window(ks, ks, error_range, rank_in_cur)
  canon <- integer(n)
  canon[rank_in_cur] <- amin
  cur[!duplicated(canon)]
}

#' 唯一化主循环（最多两轮，与原版 do/while 一致）
dmf_distinct_ions <- function(cur, key, error_range) {
  res <- dmf_distinct_pass(cur, key, error_range)
  if (length(res) == length(cur)) return(res)
  dmf_distinct_pass(res, key, error_range)
}

#' 取出指定下标的离子子集（保留 mat 列）
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
# 6. 打分（scoringP50Ions / averageScore4AllIons / mergeScore）
# ============================================================

#' 50% 离子的单独打分（P50Score）
#'
#' 以 m/z 为键做唯一化分组：先为每个离子找 mz 窗口内的代表（findIon），
#' 再按代表分组，组内统计离子数与平均强度（对 averageIntensity 求均值）。
#'
#' @param cur 离子下标向量（distinct 后的顺序 == 原版 _p50Ions 顺序）
#' @param ions 全部离子
#' @param error_range 容差
#' @param cfg 配置
#' @return data.frame，行序与 cur 一致
dmf_score_p50 <- function(cur, ions, error_range, cfg) {
  digits <- cfg$FloatCount
  n <- length(cur)
  if (n == 0L) return(NULL)

  mzv <- ions$mz[cur]
  avgv <- ions$avg[cur]
  o <- order(mzv)
  ks <- mzv[o]
  rank_in_cur <- o
  amin <- dmf_argmin_in_window(ks, ks, error_range, rank_in_cur)

  # 按代表（键有序槽位）分组
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

  back <- order(o)   # 从键有序槽位还原到 cur 顺序

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

#' 全离子打分（IonScore，noMz 维度 + rtMz 维度）
#'
#' 两个维度都建立在"代表 = 窗口内原始下标最小者"之上：
#'   noMz 维度：同一样品内、同一时间段、m/z 相近的离子归为一组；
#'   rtMz 维度：跨样品、同一 RT&m/z 的离子归为一组。
#' 第一个维度给出 noMzTotalScore，第二个维度对它按 rtMz 求均值。
#'
#' @param ions 全部离子
#' @param error_range 容差
#' @param cfg 配置
#' @return data.frame，行序与 ions 一致
dmf_score_all_ions <- function(ions, error_range, cfg) {
  digits <- cfg$FloatCount
  n <- nrow(ions)
  if (n == 0L) return(NULL)

  # ---- 维度一：noMz ----
  # no&m/z 拼接键量级约 1e7，double 的 ulp 已接近原版 fixOffset，
  # 因此用「整数部分 + 8 位小数」走十进制精确判定。
  # 注意 target 与 target_parts 都必须是「键有序」顺序。
  o1 <- order(ions$no_mz)
  k1 <- ions$no_mz[o1]
  k1_parts <- list(ip = ions$no_mz_ip[o1], f8 = ions$no_mz_f8[o1])
  amin1 <- dmf_argmin_in_window(
    k1, k1, error_range, o1, exact = TRUE,
    key_parts = k1_parts, target_parts = k1_parts
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

  # ---- 维度二：rtMz ----
  o2 <- order(ions$rt_mz)
  k2 <- ions$rt_mz[o2]
  amin2 <- dmf_argmin_in_window(k2, k2, error_range, o2)
  cnt2 <- tabulate(amin2, nbins = n)
  # 组内求和的对象是维度一的 noMzTotalScore（按 ions 原始下标取）
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
# 7. 同位素查找（IonCalculator.calcIsotopes）
# ============================================================

#' 为每个离子查找 M+1 / M+2 / M+3 并判定是否为同位素峰
#'
#' 判定规则完全照抄原版的嵌套 IF/AND/OR（含 null 传播）：
#'   X = 100<=mz<=1000 且 1<=M/M+1<=50  或  mz>=1000 且 0.5<=M/M+1<=5
#'   Y = X==1 且 M+1/M+2>1 且 （1<=M+1/M+2<=100 或 0.5<=…<=5，按 mz 分段）
#'   Z = Y==1 且 M+2/M+3>1 且 （同上）
#' 任一层级缺失（未找到峰）时该层级结果为空，最终在表里写 NullCellValue(0)。
#'
#' @param ions 全部离子
#' @param error_range 容差
#' @param cfg 配置
#' @return data.frame，行序与 ions 一致
dmf_calc_isotopes <- function(ions, error_range, cfg) {
  digits <- cfg$FloatCount
  n <- nrow(ions)
  if (n == 0L) return(NULL)

  o <- order(ions$rt_no_mz)
  k <- ions$rt_no_mz[o]
  key_parts <- list(ip = ions$rt_no_mz_ip[o], f8 = ions$rt_no_mz_f8[o])
  target_parts <- list(ip = ions$rt_no_mz_ip, f8 = ions$rt_no_mz_f8)

  # rtNoMz 是 rt/no/mz 拼出来的伪数值，量级可达 1e8，
  # 窗口边界必须走十进制精确判定，否则「恰好差 0.002」的邻元会被误纳。
  # offset 交给比较环节处理，避免 target + delta 再引入一次舍入。
  pick <- function(delta) {
    amin <- dmf_argmin_in_window(k, ions$rt_no_mz, error_range, o,
                                 exact = TRUE, offset = delta,
                                 key_parts = key_parts,
                                 target_parts = target_parts)
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

  # 原版判定：
  #   X = IF(OR(AND(100<=E<=1000, 1<=T<=50), AND(E>=1000, 0.5<=T<=5)), 1, 0)
  #   Y = IF(AND(U>1, X==1, OR(AND(100<=E<=1000, 1<=U<=100), AND(E>=1000, 0.5<=U<=5))), 1, 0)
  #   Z = IF(AND(V>1, Y==1, OR(AND(100<=E<=1000, 1<=V<=100), AND(E>=1000, 0.5<=V<=5))), 1, 0)
  # e/v 必须同长度逐元素配对（v 是取子集后的比值，不能再拿全长 E 一起算）
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
# 8. 跨组比对（p80CompareWith + mergeDiff）
# ============================================================

#' 本组 80% 离子对照另一组的总离子
#'
#' 另一组按 count 降序建立索引（idxMap），在 rtMz 有序数组里取窗口，
#' 命中集合中 count 序最靠前者即为配对的 b（原版 findIon().get(0) 语义）。
#' 容差用 ErrorRangeInGroups（默认 0.003）。
#'
#' @param cur 本组 80% 离子下标
#' @param ions 本组离子
#' @param other 另一组 list(ions, sample_names)
#' @param cfg 配置
dmf_compare_p80 <- function(cur, ions, other, cfg) {
  n_this <- length(cur)
  if (n_this == 0L) return(NULL)
  error <- cfg$ErrorRangeInGroups
  digits <- cfg$FloatCount

  other_ions <- other$ions
  n_other <- nrow(other_ions)
  count_rank <- integer(n_other)
  count_rank[dmf_sort_by_count(other_ions$count)] <- seq_len(n_other)

  o <- order(other_ions$rt_mz)
  ks <- other_ions$rt_mz[o]
  target <- ions$rt_mz[cur]
  amin <- dmf_argmin_in_window(ks, target, error, count_rank[o])

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

#' 差异离子汇总（mergeDiff）
#'
#' 每行 = 本组一个 80% 离子 + 另一组配对离子 + 单独得分 + 平均得分 +
#' 同位素判定 + 两组各样品强度。
#'
#' 得分不是按 rtMz 精确查表，而是复刻原版 Helper.binarySearch 的
#' "无容差" 版本：找不到精确键时返回插入位置附近的元素，因此可能取到
#' 邻近距离最近的离子的分数。这里保持原版行为。
#'
#' 排序：先按 count 降序，再按 bCount 降序（缺失排最后），两步都是稳定排序。
#'
#' @param cmp dmf_compare_p80() 的结果
#' @param ions 本组离子
#' @param p50_ions 本组 50% 离子（与 distinct 顺序一致）
#' @param p50_score dmf_score_p50() 结果
#' @param iso dmf_calc_isotopes() 结果
#' @param other 另一组 list(ions, sample_names)
dmf_merge_diff <- function(cmp, ions, p50_ions, p50_score, iso, other) {
  n <- nrow(cmp)
  if (n == 0L) return(NULL)

  # ---- 得分查表 ----
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

  # ---- 同位素查表（原版只按 M+1 建表，M+2/M+3 也用它做存在性判断） ----
  # 原版建三张映射表：键分别是 m1FindRtNoMz / m2FindRtNoMz / m3FindRtNoMz，
  # 用 Helper.toMapF（重复键「首次命中优先」，与 R 的 match 语义一致）。
  # 取值时三列都先用 m1Isotopes.containsKey(rtNoMz) 把门，
  # 再各自到自己的表里取 —— 不是「找到 M+1 那一行的 m2 标志」。
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

  # ---- 另一组各样品强度（缺失记 0.0，与原版 valuesOr0 一致） ----
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
  # 原版两组的样品强度列都用 valuesOr0：该样品没测到就是 0.0，不是空白
  out$inten1[is.na(out$inten1)] <- 0
  out$inten2 <- inten2
  # 稳定排序：先 count 降序，再 bCount 降序（NA 最后）
  o1 <- order(-out$count)
  out <- out[o1, , drop = FALSE]
  bc <- out$b_count
  ord2 <- order(is.na(bc), -ifelse(is.na(bc), 0, bc))
  out <- out[ord2, , drop = FALSE]
  rownames(out) <- NULL
  out
}


# ============================================================
# 9. 输出表构造（对应各 toSheetData）
# ============================================================

#' 表结构：list(name, header = list(row1, row2...), cols = 具名列向量)
dmf_sheet <- function(name, header, cols) {
  list(name = name, header = header, cols = cols)
}

#' toSheetData(List<Ion>) 的列
dmf_cols_ion_table <- function(ions, idx) {
  list(no_int = ions$no_int[idx], rt = ions$rt[idx], rt_mz = ions$rt_mz[idx],
       mz = ions$mz[idx], avg = ions$avg[idx], count = ions$count[idx])
}

#' 组合表头单元格（保持数值/文本类型，NA 表示空单元格）
dmf_hdr <- function(...) {
  parts <- list(...)
  out <- list()
  for (p in parts) out <- c(out, if (is.list(p)) p else as.list(p))
  out
}

#' 复刻 BigDecimalHelper.valuesMayNA / to01MayNA
#'
#' 原版这两个函数把 null 替换成 Config.instance.NullCellValue，
#' 而该字段的默认值是整数 0。所以「未找到」在成品 Excel 里是 0，不是空白。
dmf_or0 <- function(v) {
  v[is.na(v)] <- 0
  v
}

.dmf_sheet_scoring <- function(g, p50_score, ion_score) {
  list(
    dmf_sheet(paste0(g, "50%离子单独打分"),
              list(c("sample", "RT", "RT&m/z", "m/z", "平均离子强度", "查找(离子唯一化处理)",
                     "计数", "重复离子平均强度", "单个离子平均强度/重复离子平均强度",
                     "强度打分", "计数打分", "相对离子强度打分", "总得分")),
              list(no_int = p50_score$no_int, rt = p50_score$rt, rt_mz = p50_score$rt_mz,
                   mz = p50_score$mz, avg = p50_score$avg, std_mz = p50_score$std_mz,
                   std_count = p50_score$std_count, std_avg = p50_score$std_avg,
                   rel = p50_score$rel, int_score = p50_score$int_score,
                   count_score = p50_score$count_score, rel_score = p50_score$rel_score,
                   total = p50_score$total)),
    dmf_sheet(paste0(g, "总离子平均得分"),
              list(
                c("所有样品离子汇总", NA, NA,
                  "样品编号必须大于2，因为m/z为100-1500，要避免sample&m/z不会与m/z重复"),
                c("sample (No)", "RT", "RT&m/z", "No&m/z", "m/z", "Intensity", "-",
                  "查找(单个样品内所有时间段离子唯一化)", "计数(单个样品)",
                  "重复离子平均强度(单个样品)", "单个离子平均强度/重复离子平均强度",
                  "强度打分", "计数打分", "相对离子强度", "总得分", "-",
                  "查找（每个时间段所有样品离子唯一化）", "计数", "得分总和",
                  "平均得分", "得分差")
              ),
              dmf_cols_ion_score(ion_score)),
    dmf_sheet(paste0(g, "离子打分汇总"),
              list(c("sample", "RT", "RT&m/z", "m/z", "单独得分", "平均得分")),
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
  dmf_sheet(paste0(g, "同位素离子查找"),
            list(
              c("总离子查找同位素", NA, "A组总离子", NA, NA, NA, NA,
                "计算理论M+1", "计算理论M+2", "计算理论M+3", NA,
                "查找实际M+1", "查找实际M+2", "查找实际M+3", NA,
                "查找实际M+1离子强度", "计算理论M+2离子强度", "查找实际M+3离子强度", NA,
                "离子强度比", NA, NA, NA, "判断是否为M峰的同位素峰", NA, NA),
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
  # 原版把 10 个空单元格写死（r1.addAll(Arrays.asList(null x10))），此处照抄
  h1 <- dmf_hdr(paste0("A组", p80_str, "离子"), rep(NA, 10), "B组离子强度")
  h2 <- dmf_hdr(list("sample", "RT", "RT&m/z", "m/z", "平均离子强度", "离子计数",
                     paste0(other_g, "RT&m/z"), paste0(other_g, "平均离子强度"),
                     paste0(other_g, "离子计数"), paste0(g, "/", other_g), "-"),
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
  # 原版逐列调 valuesMayNA(bIntensityRow.get(sampleName))，null 会变成 0
  inten[is.na(inten)] <- 0
  for (j in seq_len(n_other)) cols[[paste0("s", j)]] <- inten[, j]
  dmf_sheet(paste0(g, p80_str, "离子和", other_g, "比对"), list(h1, h2), cols)
}

.dmf_sheet_diff <- function(g_a, g_b, p80_str, diff, samples_a, samples_b) {
  n <- nrow(diff)
  h1 <- dmf_hdr(paste0(g_a, p80_str, "离子"), rep(NA, 18), paste0(g_a, "离子强度"),
                rep(NA, length(samples_a)), NA, paste0(g_b, "离子强度"))
  h2 <- dmf_hdr(list("sample (No)", "RT", "RT&m/z", "RT&No&m/z", "m/z", "平均离子强度", "离子计数",
                     paste0(g_b, "RT&m/Z"), paste0(g_b, "平均离子强度"), paste0(g_b, "离子计数"),
                     paste0(g_a, "/", g_b), paste0(g_b, "m/z"), "-",
                     "单独得分", "平均得分", "P值", "M+1", "M+2", "M+3", "-"),
                as.list(as.numeric(samples_a)), list("-"),
                as.list(as.numeric(samples_b)))

  # P 值列：原版意图写 Excel 公式 =TTEST(U{r}:AD{r},AF{r}:AO{r},2,2)，
  # 但 EasyExcel 实际写成了文本 "==TTEST(...)"。这里写真正的公式。
  p_col <- sprintf("=TTEST(U%d:AD%d,AF%d:AO%d,2,2)", seq_len(n) + 2L,
                   seq_len(n) + 2L, seq_len(n) + 2L, seq_len(n) + 2L)

  # 另一组 m/z：从 b 的 RT&m/z 字符串里按 b 的 rt 位数截掉前缀（原版做法：
  # int len = (int)Math.log10(b.rt) + 1; mz.substring(len)）
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

  dmf_sheet(sprintf("%s和%s差异离子(%s比%s)", g_a, g_b, g_a, g_b), list(h1, h2), cols)
}


# ============================================================
# 10. 写盘（EasyExcel 输出结构的等价物）
# ============================================================

#' 把 dmf_sheet 列表写成 xlsx
#'
#' 表头行逐行写（保留数值/文本类型），数据块整块写：全数值列走矩阵通道，
#' 混合类型列走 data.frame 通道。以 "=" 开头的字符串由 openxlsx 写成公式。
dmf_write_sheets <- function(sheets, path) {
  wb <- openxlsx::createWorkbook()
  for (sh in sheets) {
    openxlsx::addWorksheet(wb, sh$name)
    r <- 1L
    for (h in sh$header) {
      df <- as.data.frame(as.list(h), stringsAsFactors = FALSE,
                          check.names = FALSE, optional = TRUE)
      openxlsx::writeData(wb, sh$name, df, startCol = 1L, startRow = r,
                          colNames = FALSE, keepNA = FALSE)
      r <- r + 1L
    }
    cols <- sh$cols
    if (length(cols) > 0L && length(cols[[1]]) > 0L) {
      all_num <- all(vapply(cols, function(x) is.numeric(x) || is.integer(x), logical(1)))
      if (all_num) {
        m <- do.call(cbind, cols)
        openxlsx::writeData(wb, sh$name, m, startCol = 1L, startRow = r,
                            colNames = FALSE, keepNA = FALSE)
      } else {
        df <- as.data.frame(cols, stringsAsFactors = FALSE, check.names = FALSE,
                            optional = TRUE)
        openxlsx::writeData(wb, sh$name, df, startCol = 1L, startRow = r,
                            colNames = FALSE, keepNA = FALSE)
      }
    }
  }
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  invisible(path)
}


# ============================================================
# 11. 主流程（IonCalculator.Process / p80CompareWith / mergeDiff）
# ============================================================

#' 补全配置：未在界面上暴露的参数取 default_config
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
  if (length(miss) > 0L) stop("配置缺少字段：", paste(miss, collapse = ", "))
  base
}

#' 处理一个分组：读取 → 建矩阵 → 50%/80% 筛选与唯一化 → 打分 → 同位素
#'
#' @param path 该组 Excel 路径
#' @param group_name 组名（A组 / B组）
#' @param cfg 已完成补全的配置
#' @param verbose 是否打印进度
#' @param progress 可选回调 function(frac, detail)，frac 为整轮流程的完成比例
#' @param frac_from,frac_to 本组的进度区间
dmf_process_group <- function(path, group_name, cfg, verbose = TRUE,
                              progress = NULL, frac_from = 0, frac_to = 1) {
  step <- function(f, detail) {
    if (is.function(progress)) {
      progress(frac_from + f * (frac_to - frac_from), detail)
    }
    if (verbose) message(sprintf("[%s] %s", group_name, detail))
  }
  t0 <- Sys.time()
  step(0.02, "开始读取文件")
  rd <- dmf_read_samples(path)

  step(0.18, sprintf("开始初始化矩阵（%d 个离子 / %d 个样品）",
                     nrow(rd$ions), length(rd$sample_names)))
  ions <- dmf_create_matrix(rd$ions, length(rd$sample_names), cfg$ErrorRange, cfg$FloatCount)

  n_sample <- length(rd$sample_names)
  # 50% 阈值：(int)(p50 * n) 截断；80% 阈值：(int)ceil(p80 * n)
  thr50 <- as.integer(cfg$p50IonPercent * n_sample)
  thr80 <- as.integer(ceiling(cfg$p80IonPercent * n_sample))
  p80_str <- sprintf("%d%%", as.integer(cfg$p80IonPercent * 100))
  if (verbose) {
    message(sprintf("[%s] 读取完成，样品数 %d，最少出现次数：%s = %d",
                    group_name, n_sample, p80_str, thr80))
  }

  # ---- 50% ----
  step(0.50, "筛选与唯一化 50% / 80% 离子")
  idx50 <- which(ions$count >= thr50)
  idx50 <- idx50[dmf_sort_by_count(ions$count[idx50])]
  idx50 <- dmf_distinct_ions(idx50, ions$rt_mz, cfg$ErrorRange)
  p50_ions <- dmf_subset_ions(ions, idx50)

  # ---- 80% ----
  idx80 <- which(ions$count >= thr80)
  idx80 <- idx80[dmf_sort_by_count(ions$count[idx80])]
  idx80 <- dmf_distinct_ions(idx80, ions$rt_mz, cfg$ErrorRange)
  p80_ions <- dmf_subset_ions(ions, idx80)

  if (verbose) {
    message(sprintf("[%s] p50 离子数 %d，p80 离子数 %d", group_name,
                    length(idx50), length(idx80)))
  }

  # ---- 打分 ----
  step(0.62, "50% 离子单独打分")
  p50_score <- dmf_score_p50(idx50, ions, cfg$ErrorRange, cfg)
  step(0.72, "全离子两维度打分")
  ion_score <- dmf_score_all_ions(ions, cfg$ErrorRange, cfg)
  # 汇总表里的"平均得分"= 同一离子在 rtMz 维度的平均分
  p50_score$avg_score_by_rt <- ion_score$rt_mz_avg[idx50]

  # ---- 同位素 ----
  step(0.88, "同位素 M+1 / M+2 / M+3 查找")
  iso <- dmf_calc_isotopes(ions, cfg$ErrorRange, cfg)

  step(1, sprintf("处理完成，耗时 %.1f 秒",
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

#' 组内三张表（分布初筛 / 50% / 80%）
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
    dmf_sheet(paste0(g, "离子分布初筛"),
              list(dmf_hdr(list("sample", "RT", "RT&m/z", "m/z", "-"),
                           as.list(as.numeric(sample_names)),
                           list("计数", "平均强度"))),
              cols_base),
    dmf_sheet(paste0(g, "50%分布频率离子"),
              list(c("Sample (No)", "RT", "RT&m/z", "m/z", "平均离子强度", "离子计数")),
              dmf_cols_ion_table(ions, idx50)),
    dmf_sheet(paste0(g, p80_str, "分布频率离子"),
              list(c("Sample (No)", "RT", "RT&m/z", "m/z", "平均离子强度", "离子计数")),
              dmf_cols_ion_table(ions, idx80))
  )
}

#' 跑完整流程并写出全部结果文件
#'
#' 输出（与原版文件名、工作表名一致）：
#'   <A>-筛选50%和80%离子.xlsx        （3 表）
#'   <A>-离子打分.xlsx               （3 表）
#'   <A>-同位素离子查找.xlsx          （1 表）
#'   <A>-80%离子与<B>总离子比对分析.xlsx（1 表）
#'   <A>-<B>差异离子筛选汇总.xlsx      （2 表）
#'   B 组同上
#'
#' @param file_a,file_b 两个分组的 Excel 路径
#' @param output_dir 输出目录（不存在会自动创建）
#' @param config 配置，缺省用 default_config
#' @param group_names 组名，默认 c("A组","B组")
#' @param verbose 是否打印进度
#' @param progress 可选回调 function(frac, detail)
#' @return list(groups, diff, files, p80_str)
dmetfinder_run <- function(file_a, file_b, output_dir, config = NULL,
                           group_names = c("A组", "B组"), verbose = TRUE,
                           progress = NULL) {
  cfg <- dmf_merge_config(config)
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  g_a <- group_names[1]
  g_b <- group_names[2]
  step <- function(frac, detail) if (is.function(progress)) progress(frac, detail)

  ga <- dmf_process_group(file_a, g_a, cfg, verbose, progress, 0, 0.42)
  gb <- dmf_process_group(file_b, g_b, cfg, verbose, progress, 0.42, 0.84)

  # ---- 跨组比对：80% 离子 vs 另一组总离子 ----
  step(0.86, "跨组比对：80% 离子 vs 另一组总离子")
  cmp_ab <- dmf_compare_p80(ga$p80_idx, ga$ions, list(ions = gb$ions, sample_names = gb$sample_names), cfg)
  step(0.88, "跨组比对（反向）")
  cmp_ba <- dmf_compare_p80(gb$p80_idx, gb$ions, list(ions = ga$ions, sample_names = ga$sample_names), cfg)

  sheet_ab <- .dmf_sheet_p80_compare(g_a, ga$p80_str, g_b, cmp_ab, ga$ions, list(sample_names = gb$sample_names, ions = gb$ions))
  sheet_ba <- .dmf_sheet_p80_compare(g_b, gb$p80_str, g_a, cmp_ba, gb$ions, list(sample_names = ga$sample_names, ions = ga$ions))

  # ---- 差异离子汇总 ----
  step(0.90, "生成差异离子汇总")
  diff_ab <- dmf_merge_diff(cmp_ab, ga$ions, ga$p50_ions, ga$p50_score, ga$isotopes,
                            list(ions = gb$ions, sample_names = gb$sample_names))
  diff_ba <- dmf_merge_diff(cmp_ba, gb$ions, gb$p50_ions, gb$p50_score, gb$isotopes,
                            list(ions = ga$ions, sample_names = ga$sample_names))

  sheet_diff_ab <- .dmf_sheet_diff(g_a, g_b, ga$p80_str, diff_ab, ga$sample_names, gb$sample_names)
  sheet_diff_ba <- .dmf_sheet_diff(g_b, g_a, gb$p80_str, diff_ba, gb$sample_names, ga$sample_names)

  # ---- 写盘 ----
  files <- character(0)
  n_out <- 9L
  w <- function(sheets, fname) {
    p <- file.path(output_dir, fname)
    dmf_write_sheets(sheets, p)
    files <<- c(files, p)
    if (verbose) message("已写出：", fname)
    step(0.92 + 0.08 * length(files) / n_out, paste("写出", fname))
    p
  }
  w(ga$sheets[1:3], sprintf("%s-筛选50%%和%s离子.xlsx", g_a, ga$p80_str))
  w(ga$sheets[4:6], sprintf("%s-离子打分.xlsx", g_a))
  w(ga$sheets[7],   sprintf("%s-同位素离子查找.xlsx", g_a))
  w(list(sheet_ab), sprintf("%s-%s离子与%s总离子比对分析.xlsx", g_a, ga$p80_str, g_b))
  w(list(sheet_diff_ab, sheet_diff_ba), sprintf("%s-%s差异离子筛选汇总.xlsx", g_a, g_b))

  w(gb$sheets[1:3], sprintf("%s-筛选50%%和%s离子.xlsx", g_b, gb$p80_str))
  w(gb$sheets[4:6], sprintf("%s-离子打分.xlsx", g_b))
  w(gb$sheets[7],   sprintf("%s-同位素离子查找.xlsx", g_b))
  w(list(sheet_ba), sprintf("%s-%s离子与%s总离子比对分析.xlsx", g_b, gb$p80_str, g_a))

  list(
    groups = list(A = ga, B = gb),
    diff = list(ab = diff_ab, ba = diff_ba),
    compare = list(ab = cmp_ab, ba = cmp_ba),
    files = files,
    p80_str = ga$p80_str,
    sheets = list(A = ga$sheets, B = gb$sheets,
                  compare_ab = sheet_ab, compare_ba = sheet_ba,
                  diff_ab = sheet_diff_ab, diff_ba = sheet_diff_ba)
  )
}

# MSGeter → DMetFinder 数据处理流程与逻辑

> 依据源码逐行核对：`shiny_app/server/FeatureGeter_server.R`（Ms1Geter）、`Ms2Geter_server.R`、`RtGeter_server.R`、`R/dmetfinder_functions.R`、`R/config.R`、`server/dmetfinder_server.R`。
> 整理日期：2026-10-22。

---

## 0. 一句话总览

**MSGeter 负责把仪器原始文件变成「结构规整、可直接比对」的峰表；DMetFinder 负责在两组的峰表之间做统计意义上的差异离子筛选。** 两者唯一的硬契约是「每样品 6 列」的 Excel 布局，其余全部通过文件对接，不做数据库或对象传递。

| 环节 | 子模块 | 输入 | 输出 | 谁读这份输出 |
|---|---|---|---|---|
| 前处理 | **Ms1Geter** | `.raw / .mzML / .mzXML` + 分组表 | `Clean_MS1_Data_GroupX.xlsx`、`MS2_Group_Info.csv`、`MS2_MGF/*.msp` | DMetFinder / Ms2Geter / 外部注释工具 |
| 前处理 | **Ms2Geter** | `MS2_Group_Info.csv` + 目标特征表 + MSP 目录 | 只含目标特征的 `.msp` | 谱库匹配 / MS-DIAL 等 |
| 前处理 | **RtGeter** | 峰表（峰id/样品/MZ/RT_min）+ 原始文件目录 | 原表全部列 + `RT` | 人工核对 / 后续建 RT&m/z |
| 分析 | **DMetFinder** | 两组 6 列 Excel | 9 个 xlsx（18 张表） | 人工解读 |

---

## 1. 数据形态契约（最容易出错的地方）

### 1.1 每样品 6 列

```
| Sample(No) | RT | RT&m/z | m/z | Intensity | (空列) | Sample(No) | RT | ... |
|<--                    样品 1 的 6 列块                -->|<--     样品 2 ...   -->|
```

- 第 1 列是样品编号（**整数**），第 6 列必须是**空列**，作为块分隔。
- `dmf_read_samples()` 以 `block_width = 6` 定长切块；一个块「是否存在」只看该块第 1 列**首行**是否为数值。
- 文件**第一行会被丢弃**（复刻 EasyExcel `headRowNumber = 1` 的行为），所以第一行写什么表头都不影响，但必须有这一行。
- 样品名取自各块首行第 1 列的编号，**去重保序**（不是读表头文字）。

### 1.2 三个数值必须成立的约束

| 字段 | 约束 | 不满足时 |
|---|---|---|
| `RT` | 必须是整数 | 抛错：原版会 `NumberFormatException` |
| `Sample(No)` | 必须是整数 | 同上 |
| `m/z` | 读入后统一 `truncate` 到 8 位小数 | 自动处理 |

### 1.3 拼接键

DMetFinder 内部所有去重与打分都建立在两个「字符串拼接再转数值」的伪键上：

```
noMz   = Sample(No) ‖ mz(8位定点)        # 量级约 1e7
rtNoMz = RT ‖ Sample(No) ‖ mz(8位定点)   # 量级最高约 1.9e8
```

这两个键的量级已经超过 double 的有效分辨力（ulp ≈ 3e-8 > 原版 `fixOffset` = 1e-9），所以代码里额外存了一份「整数部分 + 8 位小数的整数」，窗口比较全部在整数域完成（`dmf_decimal_parts()`）——这是与原版 `BigDecimal` 对齐的关键，不能用普通浮点比较替代。

---

## 2. MSGeter

### 2.1 Ms1Geter（代码里叫 `FeatureGeter`）

**入口**：`FeatureGeter_server()`，工作目录 + 分组表（必须含 `Sample`、`Group` 两列）。

#### 2.1.1 文件读取（`read_ms_file`）

| 格式 | 读取方式 | 保留时间 | 谱图来源 |
|---|---|---|---|
| `.raw` | `rawrr::readFileHeader` 取扫描数 → `readSpectrum(1:N, mode = "profile")` | `StartTime`（已是分钟） | `centroid.mZ` / `centroid.intensity` |
| `.mzML/.mzXML` | `mzR::openMSfile` + `header()` + `peaks()` | `retentionTime / 60`（秒→分） | 原始点，必要时在线去卷积 |

- **MS1 判定**：`.raw` 里 `scanType` **严格等于**常量 `"FTMS - p ESI Full ms [100.0000-1500.0000]"` 才算 MS1，其余一律算 MS2。
- **precursor m/z**：从 scanType 字符串里正则抽 `(?<=ms2\s)[^@]+`。
- **极性**：`.raw` 一律写 `"Negative"`（原版硬编码）；`.mzML` 由 `infer_ion_mode()` 从 `polarity` 推断。
- **profile 判定**（仅 mzML）：峰间距中位数 `< 0.005` 视为 profile，用 `centroid_profile_peaks()` 以 **20 ppm 锚点窗**取每簇最强点。

#### 2.1.2 MS1 清洗链

1. **分桶**：取所有 `msLevel == 1` 的扫描，按 `floor(StartTime)` 归入分钟桶，同桶内的峰直接 `bind_rows` 堆叠。
2. **去卷积**：`clean_spectrum_keep_max(min_mz = 0, max_mz = 1500, ppm = 10, normalize = FALSE)`
   - 去掉 `mz <= 0` 或 `intensity <= 0` 的峰；
   - 按 m/z 排序，以**组内第一个点的 m/z 为锚点**做 10 ppm 聚类（不是链式比较，误差不累积）；
   - 每组只留强度最高的那个点；
   - 此步**不做**噪声比例过滤、**不做** TopN（两个参数传 `0 / -1`）。
3. **硬阈值**：`intensity > 10000`，低于直接丢弃（**硬编码**）。
4. **RT 换算**：`RT = 桶号 + 1`（桶 0 → RT 1，桶 17 → RT 18），只保留 `RT ∈ 1..18`（**硬编码** `keep_rt <- as.character(1:18)`）。
5. **精度规整**：`mz` 保留 4 位小数、`intensity` 取整。
6. **拼键**：`RT_mz = as.numeric(paste0(RT, sprintf("%.4f", mz)))`。

> 这一步的解释要准确：**同一分钟内的所有 MS1 谱被合并成一个「伪谱」再取最强峰**，所以最终 RT 的分辨率是 1 分钟，不是扫描级。

#### 2.1.3 输出

| 文件 | 内容 |
|---|---|
| `MS2_Group_Info.csv` | 全部 MS2 扫描：`scan, StartTime, scanType, ms2_value, group, Sample`；`group` 按 precursor m/z 贪心分段（**当前 m/z > 组首 + 0.9** 就开新组） |
| `MS2_MGF/<样品>.msp` | 每个 MS2 谱一个 block：`NAME / PRECURSORMZ / IONMODE / RETENTIONTIME / Num Peaks / 峰对` |
| `Clean_MS1_Data_Group<Group>.xlsx` | 每个工作表一个 `Group`；**样品横向排开，样品之间留 1 个空列** → 正好构成 6 列块 |

同一样本存在多种格式（如 `P173.raw` 与 `P173.mzML`）时只处理 `list.files` 遇到的第一个；分组表里有、目录里没有的样品会被静默跳过。

### 2.2 Ms2Geter

**目标**：把「峰表里的一个特征」反查回「原始 MS2 扫描」，并把这批谱单独导出成 MSP。

1. **扫描匹配**：对每个目标特征（同样品内），筛 `|ms2_value − m/z| <= 0.01`（**0.01 Da 硬编码**）→ 按 `(|StartTime − RT|, |mz 差|)` 双键升序取第一条。
2. **取谱**：从同名 `.msp` 里按 scan 号取原始峰列表。
3. **重写 MSP**：比 Ms1Geter 多输出一行 `FEATURE_INFO: 样品&RT&m/z`。

注意两点：RT 只用于**平手时的排序**，不设容差上限——所以只要同样品存在同 m/z 的 MS2，就一定会配上一条，哪怕 RT 差很远。

### 2.3 RtGeter

**目标**：把峰表里的「分钟区间」解析成「具体保留时间」。

- **RT_min 是区间的右端点**：`RT_min = 2` → 窗口 `(1, 2]`；左开右闭，相邻桶既不重叠也不留缝。
- **只扫 MS1**，且只读索引 → 在内存里筛窗口 → 按需读窗内扫描，不整文件读入。
- **按 (样品, RT_min) 分组**：一个窗口只读一次谱，组内所有 m/z 复用。
- **取点**：窗口内每张谱取 m/z 容差（默认 ppm，可切 Da）内最强峰 → 跨所有谱取全局最强 → **平手取更早的扫描** → 返回该扫描的 `StartTime`。
- **样品名匹配**：归一化（小写、去扩展名、去空格/下划线/点/横线）后与文件名比对，失败再做唯一前缀/后缀/包含匹配。
- **列识别**：中英文别名表（`峰id / 峰编号 / peakid / featureid …`），失败按前四列位置回退。
- **失败行会保留**（RT 留空），诊断信息写第二个工作表：`Window / Status / RT / Intensity / Scan / MZ_found / Error_ppm / MS1_scans / Scans_hit / File`。
- 状态码：`ok / no_peak / empty_window / no_index / read_error / sample_not_found / bad_sample / bad_rt_min / bad_mz`。

---

## 3. DMetFinder

**入口**：`dmetfinder_run(file_a, file_b, output_dir, config)`；界面在 `dmetfinder_server.R` 里只负责参数装配与进度。

### 3.1 阶段一：读取与键构造（`dmf_read_samples`）

1. `readxl` 读入 → 丢第一行 → 按 6 列步长切块。
2. 每行产出 `no / rt / mz / intensity`，然后：
   - `mz  = truncate(mz)`：**加 1e-10 后向零截断到 8 位小数**（在十进制字符串层面做，不能直接用 double 加）；
   - `rt_mz = truncate(RT&m/z 列)`；
   - 拼 `noMz`、`rtNoMz`，并同时存精确十进制分解。
3. **离子排列顺序是「样品优先」**（先样品 1 的全部离子，再样品 2 …）。这个顺序决定后续稳定排序与 `findIon` 的 tie-break，**不能改**。

### 3.2 阶段二：强度矩阵（`dmf_create_matrix`）

- 以 `rtMz` 为键排序，为每个离子取 `±ErrorRange(0.002)` 窗口内的全部邻居（**开区间**：`[t − e + 1e-9, t + e − 1e-9]`）。
- 命中离子按样品编号落进矩阵行，**同一样品先到先得**（原始下标小者胜）。
- `count` = 该离子覆盖的样品数；`avg` = 强度总和 ÷ count，**7 位 HALF_UP**。

### 3.3 阶段三：阈值筛选 + 唯一化

| 阈值 | 计算方式 | 含义 |
|---|---|---|
| 50% | `thr50 = as.integer(0.5 * n)` | **向零截断** |
| 80% | `thr80 = as.integer(ceiling(0.8 * n))` | **向上取整** |

两者不对称，这是原版行为。

唯一化 `dmf_distinct_ions`（最多两轮，复刻 `do/while`）：

1. 取 `count >= 阈值` 的离子，按 `count` 降序**稳定排序**；
2. 对每个离子，在自己的 `rtMz` 窗口内找**代表**（= 窗口内原始下标最小者）；
3. 若代表未被占用，则**保留当前离子**并把代表标记为已占用（保留的是当前离子，不是代表本身）；
4. 若这一轮没有减少任何离子则结束，否则再来一轮。

### 3.4 阶段四：两套打分

打分不是概率、不是显著性，是三个因子的**乘积启发式**：`total = 强度分 × 计数分 × 相对强度分`。

**打分表（默认值）**

| 因子 | 区间下界 | 分值 |
|---|---|---|
| 强度 | `0, 5000, 10000, 50000, 100000, 500000, 1000000` | `1, 2, 5, 6, 8, 9, 10` |
| 计数 | `1, 3, 5, 10` | `10, 3, 2, 1` |
| 相对强度（组内计数 ≥ 5） | `0, 1, 2, 3, 4, 5` | `0.5, 1, 2, 3, 5, 10` |
| 相对强度（组内计数 < 5） | `0, 2, 3, 4, 5` | `1, 2, 3, 5, 10` |

查表规则 `dmf_score`：从后往前找**第一个** `v >= range[i]`，返回 `scores[i]`，否则 0（等价 `findInterval`，左闭）。

注意**计数分是反向的**：count 越少得分越高（1–2 次 → 10 分，≥10 次 → 1 分）。原版逻辑是「偶尔出现但强度高的离子更有判别力」，不是「越常见越好」。

**A. 50% 离子单独打分（`dmf_score_p50`）**

以 **m/z** 为键做分组（窗口 `ErrorRange`），组内：

```
std_count = 组内离子数
std_avg   = 组内 avg 的均值（7 位 HALF_UP）
rel       = avg / std_avg
total     = int_score × count_score × rel_score
```

**B. 全离子两维度打分（`dmf_score_all_ions`）**

- **维度一 noMz**（同一样品内、m/z 相近的离子归组）：
  `no_mz_total = int_score × count_score × rel_score`，`rel = 强度 / 组内平均强度`。
- **维度二 rtMz**（跨样品、同一 RT&m/z 归组）：
  把维度一的 `no_mz_total` 按 rtMz 组**求和** → `rt_mz_total`；`rt_mz_avg = rt_mz_total / rt_mz_cnt`。
- **`score_diff = no_mz_total − rt_mz_avg`**。

汇总表里的「平均得分」列，取的就是该 50% 离子在 **rtMz 维度**的 `rt_mz_avg`。

### 3.5 阶段五：同位素查找（`dmf_calc_isotopes`）

- 以 `rtNoMz` 为键，分别按 `+1.00335 / +2.0067 / +3.01005` 查窗口（容差 `ErrorRange`），得到 `m1/m2/m3_find`、对应强度与三个比值 `M/M+1`、`M+1/M+2`、`M+2/M+3`。
- 判定链完全照抄原版嵌套 IF（含缺失传播）：

```
X = (100 ≤ mz ≤ 1000 且 1 ≤ M/M+1 ≤ 50) 或 (mz ≥ 1000 且 0.5 ≤ M/M+1 ≤ 5)   → 1/0
Y = X == 1 且 M+1/M+2 > 1 且 (1 ≤ M+1/M+2 ≤ 100 或 0.5 ≤ … ≤ 5，按 mz 分段)
Z = Y == 1 且 M+2/M+3 > 1 且 (同上分段)
```

- 未找到峰时该层为 NA，**写进 Excel 时变成 0**（`NullCellValue = 0`），不是空白。

### 3.6 阶段六：跨组比对（`dmf_compare_p80`）

- **A 组 80% 离子 vs B 组全部离子**（反向再来一次），容差 `ErrorRangeInGroups = 0.003`。
- B 组先按 `count` 降序建立 rank，在 B 的 `rtMz` 有序数组里取窗口，命中集合中 **rank 最小者**（即 count 最高者）为配对 `b`。
- 产出 `b_rt_mz / b_avg / b_count / a_b`，其中 `a_b = avg_A / avg_B`。

### 3.7 阶段七：差异离子汇总（`dmf_merge_diff`）

每行 = 一个 80% 离子 + 配对离子 + 单独得分 + 平均得分 + 同位素标志 + 两组各样品强度。

- **得分查表**用原版 `Helper.binarySearch` 的「无容差」版本：找不到精确键时返回插入位置附近的元素——所以**可能取到邻近距离最近的离子分数**。这是原版缺陷，代码刻意保留未修正。
- **同位素查表**建三张映射表（M+1/M+2/M+3 各一张），取值时三列都先用 `m1_find` 做 `containsKey` 门控，再各自到自己的表里取。
- **强度缺失写 `0.0`**（`valuesOr0` 语义），不是空白。
- **排序**：先 `count` 降序，再 `bCount` 降序（缺失排最后），两步都是稳定排序。
- **P 值列**写真正的 Excel 公式 `=TTEST(U{r}:AD{r}, AF{r}:AO{r}, 2, 2)`。

### 3.8 阶段八：输出清单（9 个文件 / 18 张表）

| # | 文件 | 工作表 |
|---|---|---|
| 1 | `A组-筛选50%和80%离子.xlsx` | `A组离子分布初筛` / `A组50%分布频率离子` / `A组80%分布频率离子` |
| 2 | `A组-离子打分.xlsx` | `A组50%离子单独打分` / `A组总离子平均得分` / `A组离子打分汇总` |
| 3 | `A组-同位素离子查找.xlsx` | `A组同位素离子查找` |
| 4 | `A组-80%离子与B组总离子比对分析.xlsx` | `A组80%离子和B组比对` |
| 5 | `A组-B组差异离子筛选汇总.xlsx` | `A组和B组差异离子(A组比B组)` + `B组和A组差异离子(B组比A组)` |
| 6 | `B组-筛选50%和80%离子.xlsx` | 同 1，B 组 |
| 7 | `B组-离子打分.xlsx` | 同 2，B 组 |
| 8 | `B组-同位素离子查找.xlsx` | 同 3，B 组 |
| 9 | `B组-80%离子与A组总离子比对分析.xlsx` | `B组80%离子和A组比对` |

> 差异离子筛选汇总只有**一个文件**（A 侧生成），里面同时装 A比B 和 B比A 两张表；B 侧不再重复写一份。
> A 侧 10 张表（3+3+1+1+2），B 侧 8 张表（3+3+1+1）。

---

## 4. 贯穿全局的数值语义（改动会直接导致结果不一致）

| 语义 | 实现 | 为什么不能简化 |
|---|---|---|
| `truncate(x)` | 加 `1e-10` 后向零截断到 8 位 | 必须在**十进制字符串**层面做；double 直接加 `1e-10` 会跨过截断边界 |
| `divide(a,b)` | HALF_UP 保留 7 位 | R 的 `round`/`sprintf` 是银行家舍入，`13.23828125` 会得 `13.2382812`（原版要 `…13`） |
| 窗口 | `[t − e + 1e-9, t + e − 1e-9]` 开区间 | `fixOffset = 1e-9` 是原版字面量，不做就等于把「恰好差 e」的邻元纳进来 |
| 命中取值 | 窗口内**原始下标最小**者 | 原版是 `TreeMap<原始下标, Ion>.get(0)` |
| 空值 | `values()` 留空白；`valuesMayNA`/`to01MayNA` → **0**；`valuesOr0` → **0.0** | 三套语义不同，混用会让「未找到」和「真的 0」难以区分 |

---

## 5. 参数默认值（`R/config.R`）

| 参数 | 默认 | 作用范围 |
|---|---|---|
| `ErrorRange` | 0.002 | 组内匹配（矩阵、唯一化、打分、同位素） |
| `ErrorRangeInGroups` | 0.003 | 跨组比对 |
| `FloatCount` | 7 | 所有除法的小数位 |
| `p50IonPercent` / `p80IonPercent` | 0.5 / 0.8 | 50% / 80% 阈值 |
| `m1 / m2 / m3` | 1.00335 / 2.0067 / 3.01005 | 同位素质量差 |
| `NullCellValue` | 0 | 未找到时的单元格值 |

---

## 6. 已知约束与断点（按影响排序）

1. **6 列布局是硬契约**。任何手工改表（删空列、插入备注列、改列顺序）都会让切块错位，且不报错——只会读到错列的数据。
2. **RT 与 Sample(No) 必须整数**。小数 RT 会直接抛错（这是有意保留的原版行为），不会自动取整。
3. **Ms1Geter 的 `1–18` 分钟与 `> 10000` 强度是硬编码**。超出 18 分钟的峰会被静默丢弃；低强度峰在设计上就不进入下一步。
4. **`RT_mz` 拼接键有固有歧义**：`RT=1, mz=1234.5678` 与 `RT=11, mz=234.5678` 拼出同一个数值。原版同样如此，代码未修正；出问题时应当以独立的 `RT` 与 `mz` 列为准。
5. **Ms2Geter 的 0.01 Da 是硬编码**，且 RT 无容差上限——只能保证「同 m/z 必配」，不能保证「配对正确」。
6. **P 值公式硬编码了列区间 `U:AD` 与 `AF:AO`**，即假定每组恰好 10 个样品。样品数变化时公式会指向错误的列（原版同样存在）。
7. **得分只能做组内相对比较**，它是乘积启发式，不是概率也不是 p 值；跨数据集比总分没有意义。
8. **`.raw` 的离子模式恒为 `Negative`**，正离子模式数据集需要在导出后人工修正。

---

## 7. 调用入口

```r
# 界面
shiny::runApp(".")                    # 三个 tab：MSGeter / DMetFinder / Peak Quality

# 只跑 DMetFinder（R 脚本里）
source("R/config.R"); source("R/dmetfinder_functions.R")
res <- dmetfinder_run(
  file_a = "Clean_MS1_Data_GroupA.xlsx",
  file_b = "Clean_MS1_Data_GroupB.xlsx",
  output_dir = "out",
  config = list(ErrorRange = 0.002, ErrorRangeInGroups = 0.003),
  verbose = TRUE,
  progress = function(frac, detail) message(sprintf("%.0f%% %s", frac * 100, detail))
)
res$files      # 9 个输出文件路径
res$diff$ab    # A 比 B 的差异离子 data.frame
```

分阶段单独调用：`dmf_read_samples()` → `dmf_create_matrix()` → `dmf_distinct_ions()` → `dmf_score_p50()` / `dmf_score_all_ions()` → `dmf_calc_isotopes()` → `dmf_compare_p80()` → `dmf_merge_diff()`。

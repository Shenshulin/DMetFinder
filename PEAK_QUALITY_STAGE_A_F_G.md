# Peak Quality — 阶段 A 复查 + 阶段 F/G 实施记录

> **状态更新（2026-10-21 晚）**：本文是当时那一次运行的记录，其中"cpc 缺失 /
> `cpc:not_installed`"的表述**已过时**——`cpc` 之后已装入隔离库 `C:/rlib/cpc`
> 并跑通。以 `THREE_METHOD_IMPLEMENTATION_REPORT.md` 第 3.2 节为准。

> 日期：2026-10-21
> 对应任务书：`完善 DMetFinder 的 Peak Quality 独立峰质量评价模块`
> 前置文档：`PEAK_QUALITY_ALGORITHM_AUDIT.md`（算法审查）、`PEAK_QUALITY_METHODS_REPORT.md`（方法实现）
>
> **任务书写的是 `D:\ms_soft`，该路径在本机不存在。实际项目根目录是
> `G:\20170828 P_35D Seeds _screen 10Y and 10B _190315\DMetFinder1.0.3\DMetFinder`，
> 本轮所有工作都在该目录内完成，没有另建应用。**

---

## 1. 阶段 A 复查：现有实现与依赖状态

### 1.1 依赖实测（R 4.6.0）

| 包 | 版本 | 状态 | 对本模块的影响 |
|---|---|---|---|
| shiny | 1.14.0 | 可用 | — |
| readxl | 1.5.0 | 可用 | 峰表 xlsx/xls 读取 |
| openxlsx | 4.2.8.1 | 可用 | XLSX 导出 |
| zip | 3.0.1 | 可用 | ZIP 报告 |
| DT | 0.34.0 | 可用 | 结果表 |
| plotly | 4.12.0 | 可用 | 峰图 |
| rawrr | 1.20.0 | 可用 | Thermo `.raw` |
| mzR | 2.46.0 | 可用 | `.mzML / .mzXML` |
| **cpc** | — | **缺失** | CPC 不可执行；每行标记 `cpc:not_installed` |
| **xcms** | — | **缺失** | cpc 的硬依赖，同样缺失 |
| **squallms** | — | **缺失** | **不影响运行**：Kumler 是 `vendor/squallms_qscore.R` 逐字复制 |

`options(dmetfinder.cpc.lib)` 与 `DMETFINDER_CPC_LIB` 均未设置，即没有指向隔离库。

### 1.2 已实现且本轮未重写

| 任务书章节 | 现有实现 | 位置 |
|---|---|---|
| 二、输入与样品匹配 | 5 种格式、自动列名猜测 + 手动映射、min/sec、逐样品与对齐广播、规范化匹配 + `sample_ambiguous`、非法行带原因、`max_expanded_rows` 硬中止 | `peak_table.R` |
| 三、XIC 提取 | 只取 MS1、4 种折叠、缺失扫描不补 0、诊断字段、双轨迹、按文件分组 | `xic_extract.R`、`eic_smooth.R` |
| 四、边界检测 | 局部极大 + prominence 三关、阈值/谷边界、多候选保留、6 状态、选最近而非最高 | `peak_detect.R` |
| 五、presence | 3 状态、5 条规则按序、逐条原因、噪声 `1.4826·MAD(diff)/√2` | `presence.R` |
| 六、Kumler | vendored 逐字复制、`peak_cor` 与 `SNR` 分离、provenance | `vendor/`、`score_adapter.R` |
| 六、CPC | 外部包调用、缺依赖明确报告、`area` 单位标注、`min_sn` 只记录不启用 | `cpc_adapter.R` |
| 六、DNN | 无权重 → 只出峰组图，`quality_probability` 恒空 | `peak_group.R` |
| 六、方法独立性 | 长表 / 宽表分离，无总分列，`method_agreement` 只计数 | `unified_results.R`、`compare_methods.R` |
| 十、界面（6 页） | Results / Peak view / Compare methods / Peak group / Inputs & mapping / Parameters & provenance | `peak_quality_ui.R` |

### 1.3 本轮发现的缺口

| 编号 | 缺口 | 对应任务书 |
|---|---|---|
| G1 | **没有四类质量分类接口** | 七、第二层输出 |
| G2 | **没有跨软件统一比较** | 八 |
| G3 | 对齐表广播未标记 RT 来源（队列平均 vs 逐样品） | 二 |
| G4 | 无法使用软件提供的逐样品 RT | 二 |
| G5 | 结果行不带 `software` / `original_id`，跨软件分组无从下手 | 八 |
| G6 | 没有 benchmark 与验证 | 九、阶段 H |
| G7 | 逐样品峰边界（不是 RT）没有被利用 | 二 |

G3–G5 本轮已解决；G1、G2 已实现为**明确标注的草案**；G6、G7 明确未做（原因见第 6 节）。

---

## 2. 阶段 F：四类质量判定

### 2.1 为什么是"规则草案"而不是分类器

任务书第七节允许四种输出（`high_quality / poor_quality / likely_noise / unknown`），
同时禁止把它包装成已验证的分类器。因此：

- 规则阈值集中在 `pq_quality_rules()`，每个**人为选定**的阈值都在 `$source` 里
  写明"NOT validated on labelled peaks"；
- 每一行输出都带 `quality_class_verified = FALSE` 与 `quality_class_version = "provisional-1"`；
- 界面、XLSX、CSV、ZIP 四处都显示这一状态；
- 兜底类别是 `unknown`，不是"中间偏下"。

当前没有可信的人工标注集，因此**本轮不报告任何 Precision / Recall / F1 / AUROC**。
任何声称这些数字的说法都缺乏依据。

### 2.2 规则表（首个匹配即生效）

| 规则 | 条件 | 类别 | 理由 |
|---|---|---|---|
| R1 | `presence = unknown` | unknown | 文件/扫描不可用，无法评价 |
| R2 | `presence = absent` | **unknown** | 无信号 ≠ 噪声峰，任务书第七节明确禁止归为 noise |
| R3 | `score_status ≠ ok` | unknown | 方法没有产出数字（含作者函数 5 点门槛） |
| R4 | `boundary_status ≠ ok` | unknown | 边界不可信时，切片的形状指标不可解释 |
| R5 | `presence_snr < 3` | likely_noise | 峰高仅为自身点间噪声的 3 倍以下 |
| R6 | `peak_cor < 0.50` | poor_quality | 有信号，但不符合任何测试过的 beta 形状 |
| R7 | `peak_cor ≥ 0.80` 且 `presence_snr ≥ 10` | high_quality | 形状与信噪同时达标 |
| R8 | 其余 | unknown | 中间地带，规则不足以分离 |

规则顺序保证**每行恰好一条规则命中**，因此每个判定都能被单独审计。

### 2.3 方法独立性如何保持

- **CPC 不参与判定**。`quality_corroboration` 列只抄写 `cpc_tf` / `cpc_sn` 供旁证，
  测试 `test_13` 用断言锁死"加入 CPC 后所有类别不变"。
- **DNN 不参与**。`quality_methods_missing` 每行写明 `dnn:no_published_weights`。
- 没有加权、相加、平均、排名或总分列。

### 2.4 输出列

| 列 | 含义 |
|---|---|
| `quality_class` | 四类之一 |
| `quality_rule` | R1..R8 |
| `quality_reason` | 人可读理由，含为何留在 unknown |
| `quality_evidence` | 支撑数字，字段与顺序固定 |
| `quality_corroboration` | CPC 旁证（不改变判定） |
| `quality_methods_missing` | 哪些方法没出结果及原因 |
| `quality_class_version` | `provisional-1` |
| `quality_class_verified` | 恒 `FALSE` |

---

## 3. 阶段 G：跨软件统一比较

### 3.1 实现

- `software`、`original_id` 从峰表一路带到每一条结果行；
- `pq_class_by_software()`：按软件分组统计四类占比，附 **Wilson 95% 置信区间**
  （比例接近 0/1 或样本量小时优于正态近似）；
- `pq_metrics_by_software()`：`peak_cor / SNR / presence_snr / n_points /
  median_ppm_dev` 的 n / 中位数 / 5% / 95% 分位；
- 缺失 `software` 的行归入 `(not stated)`，**不丢弃**；
- 界面新增 **By software** 页签，导出新增 `SoftwareComparison` sheet 与
  `quality_class_by_software.csv`、`software_comparison_note.txt`。

### 3.2 公平性约束（写在界面和导出里，不是口头承诺）

`pq_software_compare_note()` 固定输出五条：

1. 分母是候选行数，不是独立生物学重复；同一 feature 在多个样品的记录
   **不是**互相独立的重复，置信区间只能解释为行级比例；
2. 高质量占比高**不能证明**工具更好——不同软件的候选覆盖了色谱的不同区域，
   只报少数容易峰的工具在比例上天然占优；
3. `absent` 与 `unknown` 单独报告，绝不并入某个质量类别；
4. 从不读取任何软件的内部评分；
5. 分类规则是草案，`verified = FALSE`。

---

## 4. 修改文件清单

| 文件 | 改动 | 原因 |
|---|---|---|
| `R/peak_quality/quality_class.R` | **新增**（约 430 行） | 四类判定、按软件汇总、Wilson 区间、指标分布、列字典（G1、G2） |
| `app.R` | +1 行 `source()` | 加载新模块，位置在 `unified_results.R` 之后、`export_peak_quality.R` 之前 |
| `R/peak_quality/pipeline.R` | `pq_empty_row()` / `pq_row_from()` 增加 `software`、`original_id`、`rt_source` | G3、G5：来源信息必须逐行可追溯 |
| `R/peak_quality/peak_table.R` | `pq_expand_features()` 增加 `per_sample_rt` 参数与 `rt_source` 标记 | G3、G4：逐样品 RT 优先，且明确标记 RT 来源 |
| `R/peak_quality/export_peak_quality.R` | 导出前统一分类；XLSX 增加 `QualityClassSummary`、`SoftwareComparison`、`SoftwareComparisonNote`；ZIP 增加 2 个 CSV + 1 个 TXT；Parameters 增加规则阈值；ColumnDictionary 合并质量字典 | 让界面与导出不可能给出不同判定 |
| `R/peak_quality/peak_quality_ui.R` | Results 增加 `quality_cards`；新增 **By software** 页签 | 让四类与跨软件比例可见 |
| `R/peak_quality/peak_quality_server.R` | 新增 `classified_rows()` reactive；`display_rows()` 改用分类结果；新增 `quality_cards` 与 4 个 software 输出；CSV 下载改用分类行 | 一次计算、四处复用，避免屏幕与文件不一致 |
| `tests/peak_quality/helpers.R` | 加载 `quality_class.R` | 测试可复用项目加载顺序 |
| `tests/peak_quality/test_13_quality_class.R` | **新增**，63 项检查 | 锁死规则顺序、absent 不入噪声、CPC 不改变判定、分母与区间、RT 来源 |
| `tests/peak_quality/test_14_noise_robustness.R` | **新增**，17 项检查 | 核实噪声估计在缺失扫描、RT 不等间隔、强峰、极低噪声四种情况下的适用性 |
| `tests/peak_quality/pq_tabs_smoke.js` | **新增**，21 项检查 | 7 个结果页签可达、By software 内容正确、无 console 错误 |
| `.workbuddy/tools/demo_cross_software.R` | **新增** | 生成三软件比较报告的**格式样例**（合成数据，文件内含 SYNTHETIC 警告） |
| `PEAK_QUALITY_STAGE_A_F_G.md` | **新增**（本文件） | 阶段 A 复查 + F/G 实施记录 |

**未改动**：`R/dmetfinder_functions.R`、`R/config.R`、`server/dmetfinder_server.R`、
DMetFinder 的任何 Java 兼容逻辑。`vendor/squallms_qscore.R` 逐字未动。

**过程中修掉的真 bug**：`pq_result_columns()` 把尚未存在的 `quality_*` 列放进
`preferred` 后直接 `rows[, cols]`，在"未分类的表"上会报
`undefined columns selected`（`test_01` 因此崩溃）。改为 `intersect(preferred, names(rows))`。

---

## 4b. 测试结果（本轮实测）

```
test_01_pipeline.R          63 checks  OK
test_02_xic.R               37 checks  OK
test_03_boundaries.R        29 checks  OK
test_04_peak_table.R        34 checks  OK
test_05_scoring.R           37 checks  OK
test_06_real_raw.R          13 checks  OK     (真实 .raw)
test_07_aligned.R           51 checks  OK
test_08_presence.R          53 checks  OK
test_09_cpc_adapter.R       51 checks  OK     (CPC 未安装，走"明确不可用"分支)
test_10_unified.R           42 checks  OK
test_11_peak_group.R        43 checks  OK
test_12_eic_smooth.R        78 checks  OK
test_13_quality_class.R     63 checks  OK     (新增)
test_14_noise_robustness.R  17 checks  OK     (新增)
------------------------------------------------
14/14 files, 611 checks, 0 failed
```

界面冒烟（`tests/peak_quality/pq_tabs_smoke.js`，系统 Edge headless）：
**21/21 通过**，7 个结果页签全部可达，`By software` 内容正确，0 console / page error。

日志：`.workbuddy/tests/pq_final.log`、截图 `.workbuddy/tests/pq_tabs_shots/`。

### test_14 给出的三条实证结论

1. 删掉 2/3 的扫描点后，噪声估计从 50.9 变到 47.2（−7%），**不是**按点数线性塌缩；
2. `pq_point_noise(y)` 的形参只有一个 `y`，RT 轴**根本进不去**这个估计器，
   因此"RT 不等间隔"不会污染它，但也意味着它不做任何 RT 校正——这是要写进说明的性质；
3. 当一个峰占据窗口绝大部分时，估计值从 43.6 涨到 3524.6（**80 倍**）。
   这是该估计器的已知失效模式：**宽峰会把自身算进噪声**。本轮**没有**修改它
   （任务书禁止无据调参），只把它固定为测试断言与文档结论。

---

## 5. 复现步骤

```bash
# 1. 全量测试（12 个旧文件 + 新增 test_13）
Rscript tests/peak_quality/run_all.R

# 2. 只跑分类规则
Rscript tests/peak_quality/test_13_quality_class.R

# 3. 界面
Rscript .workbuddy/tools/run_shiny.R 3838
# → http://127.0.0.1:3838/ → Peak Quality → Results / By software
```

最小复现（不需要原始文件，用仓库自带的合成轨迹）：

```r
for (f in list.files("R/peak_quality", "[.]R$", full.names = TRUE)) source(f, encoding = "UTF-8")
source("tests/peak_quality/helpers.R")
syn <- pq_make_synthetic_run(n_samples = 3L, features = c("F1", "F2"), seed = 7L)
r <- pq_classify_rows(syn$rows)
table(r$quality_class, r$quality_rule, useNA = "ifany")
pq_class_summary(r)
```

---

## 6. 明确未实现或无法验证的部分

| 项 | 状态 | 原因 |
|---|---|---|
| 阶段 H：benchmark（Precision/Recall/F1/AUROC、盲法标注、分层分析、调参/测试集分离） | **未做** | 没有可信的人工标注参考集。用现有数据自造标注再报性能，等于自己出题自己判卷，任务书第九节明确禁止。 |
| 逐样品**峰边界**（不只 RT） | 未做 | 需要各软件逐样品边界列的统一映射；目前只实现了逐样品 RT 覆盖（`per_sample_rt`），且界面未暴露上传入口 |
| XCMS / MS-DIAL / MZmine 的真实三分比较报告 | 未做 | 手头没有三份来自同一批原始文件、同一次运行的真实峰表。合成数据做出来的"比较报告"没有意义 |
| CPC 指标参与判定 | 未做（有意） | 任务书禁止跨方法合成；只用旁证 |
| DNN 概率 | 未做（有意） | 作者仓库无权重（`PEAK_QUALITY_ALGORITHM_AUDIT.md` 3.1 已确认） |
| DT 表格的软件分组筛选 | 未做 | 可用 `filter = "top"` 手动筛选，优先做统计正确性 |
| 并行处理 | 未加 | 任务书第十一节禁止无依据增加 |

---

## 7. 对照任务书验收标准的差距

> "输入候选峰列表和原始文件后，系统能够为每个 `(feature, sample)` 提供可追溯的峰形指标、
> 检测状态及**经验证或明确标记为暂定**的质量类别，并能在统一评价标准下比较三个软件。"

- 可追溯的峰形指标：**已有**（Kumler + CPC（若装）+ 诊断）
- 检测状态：**已有**（presence / boundary_status / score_status + 原因）
- 质量类别：**已有，标记为 provisional**，属于任务书允许的第二档
- 三软件统一比较：**框架与统计已就绪**，缺真实数据验证
- "经验证"这一档：**未达到**，需要标注集

因此当前状态是任务书第七节第 5 条允许的
"原始指标 + 规则草案 + 未验证标记"，不是第 4 条要求的"已验证"。

# Peak Quality Assessment — 交付报告

DMetFinder 1.0.3 新增模块 · 引擎版本 `PQ_ENGINE_VERSION = "1.0.0"`
生成日期：2026-10-18 · 分支 `main` · HEAD `171cae1` · **未提交、未推送**

---

## 1. 新增和修改的文件清单

### 1.1 新增：模块实现（`R/peak_quality/`，11 个 R 文件 + 2 个 vendor 文件）

| 文件 | 行数 | 职责 |
|---|---:|---|
| `peak_quality_config.R` | 206 | 引擎版本、算法来源元数据 `PQ_PROVENANCE`、默认参数 `pq_default_params()`、状态/存在性标签表、显示上限常量 |
| `vendor/squallms_qscore.R` | 68 | **逐字复制**的 `qscoreCalculator()`（MIT，见第 3 节） |
| `vendor/LICENSE.squallms` | 32 | MIT 许可全文 + 适用范围说明 |
| `score_adapter.R` | 135 | 输入准备 → 调用上游函数 → 规范化输出；`pq_score_xic()` |
| `xic_extract.R` | 261 | 复用 `read_ms_file()`、MS1 索引、m/z 窗口、多离子聚合、XIC 提取、逐点噪声估计 |
| `presence.R` | 126 | **峰是否存在于该样本**的判定（absent / present / unknown），与评分代码隔离 |
| `peak_detect.R` | 292 | 自研边界识别（平滑、局部极大、prominence、双侧行走、候选选择、状态判定） |
| `peak_table.R` | 273 | 峰表读取（CSV/TSV/TXT/XLSX/XLS）、列名猜测与映射、RT 单位换算、样本↔文件匹配、**对齐表展开** |
| `pipeline.R` | 388 | 作业规模规划 `pq_plan_job()`、按文件分组的批量主流程 `pq_process_features()`、失败/absent 清单、候选峰长表 |
| `feature_summary.R` | 144 | **feature 级汇总**（对齐表模式）：中位数 + 最差值 + 一致性类别，分母只用 present 样本 |
| `plot_peak_quality.R` | 253 | 交互图（plotly）、残差图、报告用基础图（PDF/PNG） |
| `export_peak_quality.R` | 165 | XLSX（8 sheet）、CSV、完整报告 ZIP |
| `peak_quality_ui.R` | 250 | 侧栏 6 组参数 + 4 个结果页签 |
| `peak_quality_server.R` | 750 | 文件发现、映射 UI、运行、结果表（含 presence 过滤）、单峰视图、4 个下载 |

### 1.2 新增：测试（`tests/peak_quality/`，9 个测试文件 + 演示脚本 + fixture 产物）

`helpers.R`(102)、`run_all.R`(41)、`test_01_pipeline.R`(192)、`test_02_xic.R`(129)、
`test_03_boundaries.R`(113)、`test_04_peak_table.R`(107)、`test_05_scoring.R`(87)、
`test_06_real_raw.R`(105)、`test_07_aligned.R`(182)、`test_08_presence.R`(240)、
`ui_smoke.js`(203)、`fixtures/make_fixtures.R`(255)、`fixtures/generate.R`(23)、
`fixtures/qscore_oracle.csv`、`fixtures/cases.rds`；
演示/规模脚本：`demo/make_demo_peak_table.R`(119)、`demo/make_aligned_from_demo.R`(14)、
`demo/demo_real_data.js`、`demo/run_full_scale.R`(91)

另新增 `.workbuddy/tests/test5_peak_quality.R`(30)，使新套件可从既有回归测试目录一并启动。

### 1.3 修改：既有文件（4 个，共 +86 / −1 行，全部为追加式集成）

| 文件 | 变更 | 说明 |
|---|---|---|
| `app.R` | +17 | 在 `R/dmetfinder_functions.R` 之后追加 12 行 `source()`，仅加载新模块 |
| `ui/main_ui.R` | +3 / −1 | `navbarPage` 追加第三个 `tabPanel("Peak Quality", …)`（原 DMetFinder 行末补逗号） |
| `server/main_server.R` | +3 | 追加 `peak_quality_server("PeakQuality")` |
| `shiny_app/ui/theme.R` | +62 | 在 `/* misc */` 前追加 Peak Quality 专用 CSS（卡片、KV 网格、软按钮等） |

**未改动**：`shiny_app/server/FeatureGeter_server.R`、`shiny_app/server/Ms2Geter_server.R`、
`R/dmetfinder_functions.R`、`R/config.R`、以及 DMetFinder 的 9 个输出文件格式。
`git diff --name-only` 已确认（见第 6 节）。

---

## 2. 数据流程与关键参数

### 2.1 单个 feature 的处理链

```
峰表行 (feature_id, mz, rt[, sample_id])
  │  pq_standardize_features()     列名映射 + RT 秒→分 + 非法行剔除
  ├─ sample_id ──► pq_match_samples()  exact / contains / manual
  │                                        └─ 匹配不到 → sample_unmatched / sample_ambiguous（终止）
  ▼
raw 文件 ──► pq_load_ms_file() ──► read_ms_file()   ← 项目唯一读取层，未复制第二套
  │                                  .raw → rawrr ; .mzML/.mzXML → mzR
  │                                  返回 scan_table(scan, StartTime=分钟, msLevel, …) + spectra
  │                                  读失败 / 空 scan_table → file_error（不静默跳过、不伪造）
  ▼
pq_ms1_index()   仅保留 msLevel == 1 的扫描（MS2 前体 m/z 全程不参与强度）
  ▼
pq_extract_xic() RT 半窗过滤 → m/z 窗口（ppm 或 Da，二选一）→ 逐扫描取窗口内离子 → 聚合
  │              输出 xic(rt, intensity, mz_used, n_ions_in_scan) + diag + status
  ▼
pq_detect_peaks()   平滑(仅检测用) → 局部极大 → 三重过滤 → 双侧行走定边界 → 候选选择 → 状态
  │              输出 start_rt / apex_rt / end_rt / n_points / 候选表 / boundary_status
  ▼
pq_peak_slice() + pq_score_xic()  原始（未平滑）峰内扫描 → 上游 qscoreCalculator
  │              输出 peak_cor, SNR, score_status(ok/skipped/failed/not_finite), failure_reason
  ▼
结果行（26 列）→ DT 表 / 交互图 / XLSX / CSV / ZIP 报告
```

按文件解析结果缓存在 `ms_cache` 环境中，同一 raw 文件在多 feature 之间只解析一次。

### 2.2 关键参数（UI 全部可见、可改，并随每次结果写入 `Parameters` sheet）

| 参数 | 默认 | 单位 | 作用 |
|---|---|---|---|
| `mz_tol_unit` | `ppm` | — | 容差单位；选 ppm 时 Da 输入框隐藏，二者互斥 |
| `mz_tol_ppm` | `10` | ppm | ppm 模式下窗口半宽（相对 m/z） |
| `mz_tol_da` | `0.005` | Da | Da 模式下窗口半宽（绝对） |
| `xic_aggregate` | `max` | — | 窗口内多离子聚合：`max`/`nearest`/`sum`/`mean` |
| `rt_unit` | `min` | — | 峰表 RT 单位（`min` 或 `sec`，秒会自动 ÷60） |
| `rt_window` | `0.30` | min | RT **半**窗（左右各 0.30 min） |
| `min_points` | `5` | 扫描 | 峰内最少扫描点数 |
| `smooth_points` | `0` | 扫描 | 平滑窗口（0 = 不平滑；仅用于边界检测，评分始终用原始值） |
| `min_prominence_frac` | `0.05` | ×range | 绝对 prominence 阈值 |
| `min_rel_prominence` | `0.25` | ×最大 prominence | 抑制噪声毛刺 |
| `min_height_frac` | `0.10` | ×range | 候选峰最小高度 |
| `edge_frac` | `0.10` | ×峰高 | 边界阈值 = baseline + 10% 峰高 |
| `valley_frac` | `0.05` | ×range | 谷值低于此值即可切分双峰 |
| `apex_tolerance` | `0.20` | min | 峰顶偏离输入 RT 超过此值 → `apex_outside` |
| `detect_absent` | `TRUE` | — | 是否判定"该样本里没有这个峰" |
| `absent_snr` | `5` | ×噪点 | 峰高 / 逐点噪声低于此倍数 → 判为 absent（0 = 关闭强度判据） |
| `absent_min_points` | `3` | 扫描 | XIC 点数少于此值 → 判为 absent |
| `max_features` | `20000` | 行 | **峰表行数**上限（对齐表展开前生效） |
| `max_expanded_rows` | `200000` | 行 | 展开后的**作业规模**上限；超过则中止，不截断 |

> 所有默认值均标注为**起始值**，UI 文案明确它们不是经过验证的最优默认值（config 注释同步说明）。

**作业规模规则（2026-10-19 修正）**：此前上限作用在展开后的行上，3450 个特征 × 20 个 raw
被截断成 5000 行，实际只跑完 2 个文件。现在上限拆成两级，逻辑收敛在可测试的
`pq_plan_job()` 里：

1. `max_features` 作用在**峰表行数**上，超出部分丢弃并在日志写明丢了多少；
2. `max_expanded_rows` 作用在**展开后的行数**上，超出则**直接中止**并说明"未处理任何行"；
3. 两者都不会静默截断：要么完整跑，要么不跑。

### 2.3 结果列（`Results` sheet / CSV 前 14 列为任务书要求列，其后为诊断列）

`feature_id, sample_id, mz, input_rt, start_rt, apex_rt, end_rt, n_points, peak_cor, SNR,
presence, boundary_status, score_status, failure_reason`
+ `rt_unit, n_xic_points, file, rt_window, mz_tol, xic_aggregate, n_scans_in_window,
n_scans_missing, n_mz_matched, n_scans_multi, median_ppm_dev, peak_height, xic_noise,
presence_snr, n_candidates, edge_touched, apex_offset`（可追溯性字段）

**低评分峰不会被删除或过滤**，只做着色与排序。

### 2.4 对齐表支持（MS-DIAL / MZmine alignment result）

MS-DIAL 的对齐导出是**一行一个 feature**：m/z 和 RT 是跨样本的平均代表值
（`Alignment ID` / `Average Mz` / `Average Rt(min)`），没有样本列。这需要三层处理：

1. **输入层广播**：`Sample scope` 默认 `Auto` —— 峰表映射了 sample_id 就按列匹配；
   没有映射（或显式选 `Every feature in every raw file`）就把每个 feature
   展开到所有 raw 文件（`pq_expand_features()`），变成 feature × 样本逐行评估。
   展开**只发生在输入层**，XIC/定界/评分代码完全不变。
2. **结果层汇总**：`pq_feature_summary()` 把逐样本结果压回一行一个 feature：
   `n_samples / n_scored / n_unsuccessful / n_boundary_ok / n_ambiguous /
   pct_scored / pct_boundary_ok`，以及 **median 与 worst 同时给出**的
   `peak_cor`、`SNR`，`median/median_abs/max_abs apex_offset`（对齐 RT 准不准）、
   `median_ppm_dev`。一致性类别 `consistent / variable / poor / single_sample /
   not_evaluated` 由 `pq_summary_thresholds()` 的**描述性默认值**驱动
   （0.8 / 0.8 / 0.5），界面与导出都注明这不是通过/不通过判定。
   排序把 `poor` 排最前，方便核查。
3. **参数提示**：对齐 RT 是平均值，样本间会漂移，UI 在非 `by_column` 模式下
   常驻提示允许样本间 RT 漂移；`median_abs_apex_offset` 与 `max_abs_apex_offset`
   用来量化漂移大小，模块不替用户决定"多大算大"。

配套修复：`height`/`area` 的列名猜测改为**只认锚定模式**（`^height$`、`^averageheight$` 等），
避免把 MS-DIAL 每样本的 `<样本名> Height` 列误绑到可选 height 字段。

### 2.5 样本里本就没有这个峰（presence）

对齐表要求"每个 feature 在每个样本里都打分"，但实际有大量样本**本来就不含该化合物**
（不同分组、低于检出限、该次进样没离子化）。把这些行当成"评分失败"会带来两个后果：
feature 级汇总被拖垮（5/20 个样本有峰看起来像 75% 失败率），人工核查时也分不清
"打分失败"和"这个样本没有"。

因此新增独立的 presence 判定层（`R/peak_quality/presence.R`，与论文评分代码完全分离，
不参与任何算术）：

| `presence` | 含义 | 评分 | 计入失败清单 |
|---|---|---|---|
| `present` | 峰确实存在 | 正常评分 | — |
| `absent` | 该样本没有这个峰 | 不评分（`score_status = "absent"`） | **否** |
| `unknown` | 文件/扫描不可用，无法判断 | 不评分 | 是（`file_error` 等） |

判定顺序（每步都写进 `failure_reason`，阈值全部可在 UI 调整）：

1. RT 窗口内没有 MS1 扫描 → `unknown`；
2. 整个窗口**没有任何离子**落在 m/z 容差内 → `absent`；
3. XIC 点数 `< absent_min_points`（默认 3）→ `absent`；
4. 峰高 / 逐点噪声 `< absent_snr`（默认 5）→ `absent`；
   峰高 = 峰顶强度 − 窗口基线；噪声 = `1.4826·MAD(diff)/√2`，从同一条 XIC 估计，
   因此判据与信号绝对强度无关；
5. 其余 → `present`。

两条保护：
* 噪声判据仅在 XIC **≥ 6 点**时启用——点太少时差分被峰本身主导，估计不可信，
  否则一个"窄但真实"的峰会被误判为 absent；
* `absent_snr = 0` 或关掉 `detect_absent` 即完全禁用，退化为"窗口里有离子就评分"。

`absent` 行**始终保留在结果表里**（带原因与 `peak_height / xic_noise / presence_snr`
三个审计列），只是不参与评分；它们单独导出到 `AbsentPeaks` sheet 与
`peak_quality_absent.csv`，不进入 `Failures`。"只显示需要核查的行"也**不包含** absent，
因为那不是问题。

`pq_feature_summary()` 相应改为：`n_present / n_absent / n_unknown / pct_absent` 单列，
`pct_scored` 与 `pct_boundary_ok` 的分母改为 **n_present**，中位数/最差值只用 present 行；
全部样本都 absent 的 feature 归入新类别 `absent_everywhere`。

---

## 3. 作者原始评分代码：来源、版本、调用与修改

### 3.1 来源

| 项 | 论文原始实现 | 实际执行版本 |
|---|---|---|
| 论文 | Kumler et al., *Picky with peakpicking*, **BMC Bioinformatics 24:436 (2023)**, doi:10.1186/s12859-023-05533-4 | 同左 |
| 仓库 | `https://github.com/wkumler/MS_metrics` | `https://github.com/wkumler/squallms` |
| commit | `491deaf1d5f27f9d276e58acb4c1dfca2a2e21b9`（2023-08-02） | `2f4038ce401b2415c36daeab5928957c214a3205`（2026-09-02，v0.99.7） |
| 文件 | `feature_extraction.R` | `R/extractChromMetricsFunctions.R` |
| 函数 | `qscoreCalculator(rt, int)` | `qscoreCalculator(rt, int)` |
| 许可 | **无 LICENSE 文件**（GitHub license API 返回 404） | **MIT + file LICENSE**（© 2024 William Kumler） |

### 3.2 为什么执行 squallms 版本

`MS_metrics` 没有许可证，因此**没有再分发其源码**。作者维护的后续包 `squallms` 在 MIT 下公开同一函数，
两版数学逐行等价，仅有两处非算法差异：

1. squallms 版在评分前剔除 `rt`/`int` 为 NA 的扫描；
2. squallms 返回命名数值向量，`MS_metrics` 返回 list。

因此 `vendor/squallms_qscore.R` 逐字收录 squallms 版（文件头写明 commit、许可、差异及
`Local modifications: NONE`），同时保留 `MS_metrics` 版本**仅作数值基准**：用它实际运行 9 组固定输入，
把结果存成 `tests/peak_quality/fixtures/qscore_oracle.csv`（如 clean = 2626.04854464574 /
0.999999789314696、noisy = 17.8854172802664、4 点 → NA、全平 → 报错），
由 `test_05_scoring.R` 逐值回归 — 只分发数值，不分发无许可源码。

### 3.3 调用方式（适配层与原始代码严格分离）

```r
pq_score_xic(rt, intensity)
  └─ pq_prepare_scoring_input()   去 NA、按 RT 排序、重复 RT 取最大强度
                                   （记录 n_dropped_na / n_duplicate_rt）
  └─ qscoreCalculator(rt, int)    ← vendor 中原样函数，不包裹、不改写
  └─ 规范化：peak_cor / SNR 提取；异常 → score_status="failed" + failure_reason
```

`score_adapter.R` 只做「转换输入 → 调用 → 规范化输出」三件事，
**没有**重写 Beta 拟合、残差公式、归一化、`maybe_skews` 循环或缺失值处理。
上游对 `length(rt) < 5` 返回 NA、对全平 XIC 抛 `incompatible dimensions` 的行为均原样保留
（前者记为 `skipped`，后者记为 `failed`），**不伪造分数**。

### 3.4 语义边界

第一版只计算原始峰形指标 `peak_cor` 与 `SNR`。
**二者都不是 Good 概率**，模块任何位置（UI、图注、导出、报告）都不做此解释。

---

## 4. XIC 提取策略与边界识别算法

### 4.1 XIC 提取

- **读取层复用**：只调用 `shiny_app/server/FeatureGeter_server.R` 的 `read_ms_file()`，
  模块内没有任何第二套 raw/mzML 解析器。RT 由该层统一为**分钟**（mzML/mzXML 的秒已在此处换算）。
- **只取 MS1**：`pq_ms1_index()` 以 `msLevel == 1` 过滤；MS2 记录的 `precursorMZ`
  **绝不**作为 MS1 强度参与 XIC。
- **m/z 窗口**：按 m/z 排序后 `findInterval()` 二分定位，ppm 或 Da 二选一（互斥，UI 层面隐藏另一输入）。
- **窗口内多离子聚合**：默认 `max`（每扫描取最高强度），可选 `nearest`（最接近目标 m/z）、
  `sum`、`mean`。**从不隐式求和**；实际策略逐行写入 `xic_aggregate` 列，
  `n_scans_multi` 记录窗口内出现 >1 个离子的扫描数。
- **异常与缺失**：RT 半窗内没有 MS1 扫描 → `no_ms1_scans`；窗口内所有扫描均无信号 → `no_signal`；
  扫描缺失/重复 RT 计入 `n_scans_missing` / 由适配层按「重复 RT 取最大强度」处理并计数。
- **容差、窗口、文件、参数**全部写入结果行；`median_ppm_dev` 记录实际 m/z 偏差中位数。
- **RAW 读取失败**：抛错并被 `tryCatch` 捕获为 `file_error` + 原因，不会静默跳过或输出伪造数据。

### 4.2 边界识别（自研，与论文评分代码完全分离）

实现于 `peak_detect.R`，不引用也不修改 `vendor/` 中任何内容：

1. baseline = 窗口内最小强度，range = max − min；
2. 可选移动平均平滑（`smooth_points`，仅用于找峰与定界）；
3. 找局部极大 → 计算 prominence；
4. **三重过滤**：prominence ≥ `min_prominence_frac`×range、≥ `min_rel_prominence`×最大 prominence、
   高度 ≥ `min_height_frac`×range（第三步专治基线波动与噪声毛刺）；
5. **双侧行走** `pq_side_bound()`：向左/右推进，直到「穿越阈值（baseline + edge_frac×峰高）」
   或「进入可接受谷值（≤ valley_frac×range）」；触达窗口边缘则记为 `window_edge`；
6. **候选选择**：`order(round(|apex_rt − input_rt|, 6), −prominence)` — **取最接近输入 RT 的候选，
   不是最高峰**；仅在等距（1e-6 min 内）时用 prominence 打破平局，避免浮点噪声影响可重复性；
7. 所有候选（含未选中）都进 `Candidates` 表，供图形与表格核查。

**状态判定优先级**：`no_clear_apex` > `apex_outside` > `ambiguous` > `boundary_unclear`
> `too_few_points` > `ok`。多候选落在 `apex_tolerance` 内时标 `ambiguous` 并列出所有 apex RT，
不擅自认定其一。算法确定性（无随机数）、可配置、可图形检查（Peak view 叠加显示起止点/峰顶/区间线）。

---

## 5. 新增测试及实际测试结果

### 5.1 执行结果（本轮实际运行）

```
Rscript tests/peak_quality/run_all.R
    test_01_pipeline.R     OK  63 checks: 63 passed, 0 failed, 0 skipped
    test_02_xic.R          OK  37 checks: 37 passed, 0 failed, 0 skipped
    test_03_boundaries.R   OK  29 checks: 29 passed, 0 failed, 0 skipped
    test_04_peak_table.R   OK  34 checks: 34 passed, 0 failed, 0 skipped
    test_05_scoring.R      OK  37 checks: 37 passed, 0 failed, 0 skipped
    test_06_real_raw.R     OK  13 checks: 13 passed, 0 failed, 0 skipped
    test_07_aligned.R      OK  51 checks: 51 passed, 0 failed, 0 skipped
    test_08_presence.R     OK  53 checks: 53 passed, 0 failed, 0 skipped
    8/8 test files passed            → 合计 317 项断言全通过
```

（test_07 为对齐表专项：列名识别、展开、管道运行、汇总算术与一致性类别、导出；
test_08 为作业规模与 presence 专项：`pq_plan_job()` 的截断/中止规则、5 条 presence
判据、absent 行不评分不失败、汇总分母、AbsentPeaks 导出。）

浏览器端（puppeteer-core + 系统 Edge，真实驱动 7788 端口上的应用）：

```
node tests/peak_quality/ui_smoke.js
  ---- UI smoke: 19 checks, 19 passed, 0 failed ----
  实际运行日志：Done in 6.2 s. scored=7, absent=2, ambiguous=2,
                unclear boundary=1, no signal=2, unmatched=0
  状态卡片：10 ROWS EVALUATED / 7 SCORE OK / 2 NO PEAK IN SAMPLE /
            2 AMBIGUOUS / 1 BOUNDARY UNCLEAR / 1 NOT SCORED (OTHER)
  console / page errors: 0
```

**对齐表真实数据端到端**（网页内实际操作）：8 行对齐表（无样本列，
`Alignment ID` / `Average Mz` / `Average Rt(min)`）× 4 个真实 `.raw`
→ 自动广播为 32 行，**161.8 s** 完成，`scored=32, ambiguous=0, unclear boundary=3,
no signal=0`，0 console 错误。feature 汇总：7 个 `consistent`、1 个 `variable`
（该 feature 边界可靠样本仅 25%，apex 偏移中位数 0.13 min —— 对齐 RT 漂移被如实呈现）；
其中 feature 1 的 `median_peak_cor = 0.942` 而 `min_peak_cor = 0.737`，
中位数与最差值的差别一目了然。XLSX 含 `FeatureSummary` sheet（共 8 sheet），
ZIP 含 `feature_summary.csv` 与 32 张单峰 PNG。

### 5.2 任务书 16 项要求的覆盖

| # | 要求 | 覆盖位置 |
|---:|---|---|
| 1 | 正常单峰 | `F_CLEAN`（test_01/03） |
| 2 | 高噪声 | `F_NOISY`（test_01/03） |
| 3 | 多局部峰 | `F_TWO`、`F_MULTI`（test_03 断言 `ambiguous`） |
| 4 | 肩峰 | `F_SHOULDER`（test_03） |
| 5 | 输入 RT 偏差 | `F_LATE`、`F_SHIFT`（test_03 断言 `apex_outside`） |
| 6 | 无信号 | `F_NOSIGNAL`（test_01/02 断言 `no_signal`） |
| 7 | 窗口内多离子 | test_02 四种聚合策略 + `n_scans_multi` |
| 8 | 点数不足 | `F_NARROW`（test_03 断言 `too_few_points`） |
| 9 | mzML / mzXML | test_02、`ui_smoke`（S1.mzML / S2.mzML / S1_copy.mzXML） |
| 10 | Thermo .raw | **`test_06_real_raw.R` 用本机真实 `P173.raw`（57 MB）实跑 13 项全通过**，未伪造 |
| 11 | RT 秒 / 分钟 | `features_sec.csv` vs `features_min.csv` 结果一致（test_04） |
| 12 | 列名映射 | 18 个下拉；测 MZmine / MS-DIAL / 通用三种表头（test_04） |
| 13 | 多文件多样本 | `ui_smoke`（2 文件）+ test_01 多样本匹配 |
| 14 | 边界不明状态 | `F_EDGE` → `boundary_unclear`，并统计各状态覆盖（test_01） |
| 15 | 作者函数回归 | `qscore_oracle.csv` 9 组数值逐值比对（test_05） |
| 16 | 现有模块回归 | 见第 6 节 |
| 17 | **对齐表（MS-DIAL 对齐结果）** | `test_07_aligned.R`：列名识别 / 展开 / 管道 / 汇总算术 / 导出，51 项 |

### 5.3 真实数据端到端演示（网页内实际操作）

除合成 fixture 与单文件 RAW 测试外，还通过浏览器自动化**在真实网页里**完成了一次全流程演示：

- **输入**：真实 Thermo 文件 `P173.raw`、`P181.raw`（各 57 MB，来自 `G:/method_ms2/MSDIAL_TEST`）；
  峰表 `peak_quality_demo_features.csv`（16 行 = 8 特征 × 2 样本）。
  该峰表**不是 MS-DIAL/MZmine 导出**，而是由 `tests/peak_quality/demo/make_demo_peak_table.R`
  从 P173.raw 的 MS1 扫描中按文档化规则（0.01 Da 分箱、≥6 扫描、强度 ≥1e6、
  m/z 与 RT 互相分离）挑出的真实 m/z + 真实峰顶 RT，专用于真实数据演示；
  目录中原有的两个 `glyco_flavonoid_features*.csv` 是 MS2 特征表（只有 precursor_mz、无 RT），
  不能用作 XIC 输入，故未采用。
- **参数**：10 ppm、窗口内取 max、RT 半窗 0.30 min、最少 5 点、RT 单位 min（其余默认）。
- **过程与结果**（网页日志）：16 行全部处理，**68.9 s** 完成（含两个 57 MB raw 的解析），
  `scored=16, ambiguous=0, unclear boundary=1, no signal=0, unmatched=0`，0 个 console/page 错误。
- **结果观察**：16/16 得到 `peak_cor`（0.74–0.99）与 SNR（10.9–18.6）；
  1 行 `boundary_unclear`（DEMO_03/P173，右边界触达窗口边缘且峰顶偏 0.128 min，被如实标记而非强行定界）；
  P181 全部特征的中位数 ppm 偏差约 **−2.2**，而 P173 接近 0 —— 与两次进样间的质量轴漂移一致，
  说明诊断列确实在记录真实信息。
- **导出物**：CSV（3.6 KB）、XLSX（22.8 KB）、ZIP 报告（241 KB，
  内含 16 张单峰 PNG + 汇总 PDF + 6 个 CSV + provenance.txt + sessionInfo.txt）。
- 驱动脚本：`tests/peak_quality/demo/demo_real_data.js`（可重复执行）。

**更大规模的演示峰表**：`tests/peak_quality/demo/make_demo_peak_table.R` 已改为可传参
（`Rscript make_demo_peak_table.R <每样本数量> <输出csv> <样本列表>`），
并已生成 `G:/method_ms2/MSDIAL_TEST/peak_quality_demo_features100.csv`：
**400 行 = P173/P176/P181/P528 每样本各随机抽 100 个真实特征**（`set.seed(20261019 + k)`，可复现），
m/z 109–1357、RT 3.008–14.997 min、无重复无缺失。
注意各样本抽的是**各自**的特征，不能跨样本比较同一 feature；需要跨样本比较时改为共用一组特征即可。

### 5.3b 全规模验证（20 个真实 raw × 3450 个对齐 feature）

**背景**：上一轮网页内用 `peak_quality_demo_aligned20.csv`（MS-DIAL 对齐导出格式，
3450 个 feature、3 列 `id / Average Mz / Average Rt(min)`）配合 20 个真实 `.raw` 运行时，
日志出现 `Peak table truncated to the first 5000 rows (limit)`，实际只跑完 2 个文件。
这是**上限作用在展开后行数**上的缺陷，已修正（见 2.2 与 7.3）。

`tests/peak_quality/demo/run_full_scale.R` 可脱离网页复现该作业：

```bash
Rscript tests/peak_quality/demo/run_full_scale.R        # 全部 20 个 raw
Rscript tests/peak_quality/demo/run_full_scale.R 2      # 只取前 2 个（快速验证）
```

已实测：

| 规模 | 行数 | 耗时 | 结果 |
|---|---:|---:|---|
| 2 个 raw | 6900 | 128 s（解析 82 s） | 6900 行全部返回；scored 4152 / absent 2537；2675 个 feature 至少一个样本有峰 |
| **20 个 raw（全量）** | **69000** | **1249 s（20.8 min）** | **69000 行全部返回**；scored 40592 / absent 26576 |

20 文件全量的其余统计：

- `presence`：present 42424 / absent 26576（38.5%）——这个比例说明"样本里本来没有这个峰"
  在实际数据中非常普遍，把它算作评分失败会严重失真；
- `boundary_status`：ambiguous 38474、boundary_unclear 7118、no_signal 1776、
  too_few_points 1555、no_clear_apex 666、apex_outside 338、ok 19073；
- feature 级汇总：`variable` 2926、`consistent` 408、`single_sample` 72、`poor` 20、
  `absent_everywhere` 21、`not_evaluated` 3（3450 个 feature，其中 3429 个至少在一个样本有峰）；
- 已评分行 `peak_cor` 中位数 0.8392；
- XLSX 导出 69000 × 29 单元格 → 40.0 MB；进程峰值内存约 **6.4 GB**（含 openxlsx 工作簿）。

> ambiguous 占比高是数据的真实性质：对齐 RT 是跨样本平均值，±0.30 min 搜索窗里常有
> 多个候选峰。要收紧就减小 `rt_window`（代价是 RT 漂移大的样本容易漏峰），
> 模块不做"取最高峰"这种未经说明的替代选择。

### 5.4 测试数据可追溯性

- `fixtures/` 由 `make_fixtures.R` 确定性生成（5–8 min、0.005 min 步长、601 扫描，每 10 扫插入 1 个 MS2），
  脚本内标注 **SYNTHETIC**，与真实数据严格区分；
- `qscore_oracle.csv` 由**作者原始 `MS_metrics` 代码在本机真实运行**产出，非手算；
- `test_06` 使用仓库外真实 Thermo 文件 `G:/method_ms2/MSDIAL_TEST/P173.raw`，未复制进仓库。

---

## 6. 现有模块回归测试结果（本轮实际运行）

| 测试 | 结果 |
|---|---|
| `test1_mzml_mzxml.R` | 9/9 PASS（mzML scan_table / 质心谱往返 / profile 自动质心化 41→2 峰 / mzXML / 大端交错 / 离子模式 / 非法扩展名报错 / MS2 表 / MS1 分钟合并+10ppm+>10000） |
| `test3_ms1_equivalence.R` | PASS：`ORIGINAL logic == NEW refactor (98614 rows, all columns identical)` |
| `test4_discovery.R` | 2/2 PASS（扩展名匹配 + 重复样本跳过并写日志） |
| `test_ui_theme.R` | 63 passed, 0 failed |
| `test_ui_theme_standalone.R` | 21 passed, 0 failed |
| `test2_golden_raw.R` | MS2 输出 **5/5 PASS**：`MS2_Group_Info.csv` 24915 行一致；`P173/P176/P181/P528.msp` 逐行一致（234557 / 225932 / 230060 / 217061 行）。**MS1 部分失败**：`P173 MS1 rows: new 98614 vs ref 61767` |

**关于 MS1 xlsx 的失败 — 已确认为历史基准问题，非本次回归**：

1. `shiny_app/server/FeatureGeter_server.R`、`R/config.R`、`R/dmetfinder_functions.R`
   在本轮 `git diff --name-only` 中**完全未出现**，MS1 计算路径零改动；
2. 该数值与前几轮完全相同（同一 98614 / 61767），说明不是本次变动引入；
3. 参考文件 `Clean_MS1_Data_Group*.xlsx` 时间为 2026-05-22 16:14，属旧版代码产物；
   同一目录下的 `MS2_Group_Info.csv`(16:12) 与 4 个 `.msp` 则与当前代码逐行一致。

---

## 7. 未解决问题、依赖兼容性、性能限制

### 7.1 遗留问题

1. **`Clean_MS1_Data_Group*.xlsx` 缺少有效黄金基准**（见第 6 节）。建议后续用当前代码重新生成一份
   并单独提交为基准，否则该项回归会长期处于「已知失败」状态。本次未改动该基准文件。
2. **MS_metrics 无许可证**：论文原始源码未随仓库分发，仅以数值 oracle 形式回归。
   若将来需分发原始源码，须先联系作者取得许可。
3. **`squallms` 未安装为包依赖**：只 vendored 了 `qscoreCalculator` 单函数，
   因此不影响用户环境的包解析，但也无法自动跟随上游更新。升级需重新比对
   `qscore_oracle.csv` 并更新 `PQ_PROVENANCE` 中的 commit。
4. **无并行后端**：`params$sequential = TRUE` 为硬性现状，批量按 feature 串行。
   UI 已明示「Files are processed one after another; this architecture has no parallel backend」，
   未做任何「已并行」的表述。

### 7.2 依赖兼容性

| 依赖 | 状态 |
|---|---|
| `rawrr`（.raw） | 必需，另需 Thermo RawFileReader .NET 运行时；缺失时 `.raw` 行会记为 `file_error` 而非崩溃 |
| `mzR`（.mzML/.mzXML） | 通过 `requireNamespace()` 惰性加载，未写入 `library()`；未安装时仅影响这两种格式，**不影响应用启动** |
| `zip`（ZIP 报告） | 软依赖，缺失时自动回退 `utils::zip` |
| `plotly` / `DT` / `openxlsx` | 应用已在用，无新增版本冲突 |
| R 4.6.0 / shiny 1.14 / bslib 0.11（BS5） | 已实测 |

### 7.3 性能

- 真实基线：`P173.raw`（57 MB）`read_ms_file()` 约 **30–54 s / 8308 scans（2077 MS1）/
  16.5 MB 对象**；该成本**每个文件只付一次**。
- **调度方式（2026-10-19 优化）**：行按 raw 文件分组，逐文件处理完后**立刻释放**上一个
  解析结果，内存峰值只等于 1 个文件（此前 N 个文件同时缓存 ≈ N × 16.5 MB）；MS1 扫描索引
  也随文件缓存复用，不再每行重建。
- **实测规模**（`tests/peak_quality/demo/run_full_scale.R`，真实 Thermo 数据）：
  3450 个对齐 feature × 2 个 raw = 6900 行 **128 s**；
  3450 × **20 个 raw = 69000 行** **1249 s（20.8 min）**，全部返回，进程峰值内存约 **6.4 GB**
  （其中 openxlsx 导出 69000×29 单元格的工作簿占相当一部分）。内存紧张时可分批运行，
  或用 `max_expanded_rows` 卡住规模——它会中止而不是截断。
- 交互表在浏览器内最多渲染 20000 行（`PQ_DISPLAY_ROWS`），超出部分只在表格标题说明；
  CSV / XLSX / ZIP **始终包含全部行**。单峰下拉最多 10000 个候选（`PQ_PEAK_CHOICES`，可搜索）。
- ZIP 报告内每峰 PNG 默认最多 200 张（`max_plots`），避免大批量时打包时间失控。

### 7.4 方法学限制（UI/报告中已明示）

- `peak_cor` / `SNR` 为原始峰形指标，**不是** Good 概率或通过/不通过判定；
- `apex_tolerance`、`rt_window` 的效果依赖输入峰表 RT 的准确度；
- `xic_aggregate = sum` 在共流出离子多时会高估强度，默认 `max` 更保守；
- 边界算法为通用启发式，肩峰/共流出场景只标 `ambiguous`，不做解卷积；
- **presence 判据是启发式**：`absent_snr = 5` 只是默认起点，低丰度但真实的峰可能被判
  absent。判据、阈值、`peak_height / xic_noise / presence_snr` 全部导出，可复核；
  拿不准时把 `absent_snr` 设为 0 即退化为"窗口里有离子就评分"。

---

## 8. 启动与操作说明

### 8.1 启动

```bash
cd "G:/20170828 P_35D Seeds _screen 10Y and 10B _190315/DMetFinder1.0.3/DMetFinder"
# 或在 RStudio 中打开 app.R 点 Run App
Rscript -e 'shiny::runApp(".", port=7788, host="127.0.0.1", launch.browser=TRUE)'
```

浏览器打开 `http://127.0.0.1:7788`，顶部导航最右侧第三个页签即 **Peak Quality**。

### 8.2 完成一次峰形评估的 7 步

1. **1. RAW FILES** — 选择 `Scan a folder` 并填入 raw 所在目录（或切到 `Upload files` 多选），
   点 `Scan folder`；就绪文件数与列表会显示在下方。
2. **2. PEAK TABLE** — 上传峰表（CSV / TSV / TXT / XLSX / XLS）。
   只有 `feature_id`、`mz`、`rt` 是必需的；**不需要** start/end RT（会自动识别）。
   没有模板可先点 `Download an empty template`。
   若峰表里的 `sample_id` 与文件名不能自动对应，可上传可选的 `sample_id → file map`(CSV)。
3. **3. FIELD MAPPING** — 上传峰表后会出现 9 个下拉，自动猜测列名，请逐一核对
   （尤其是 `rt` 与 `rt (min)`）；
   然后在 `RT unit in the peak table` 选择 **minutes** 或 **seconds**。
   下面的 **Sample scope** 决定行怎么匹配样本：
   - `Auto`（默认）：峰表映射了 sample_id 就按列匹配；没映射就视为对齐表，
     每个 feature 在所有 raw 文件里各评一次；
   - `Every feature in every raw file`：强制按对齐表处理（广播）；
   - `Match rows by the sample_id column`：强制要求 sample_id 列。
   对齐表会额外得到 **Per feature** 汇总视图（Results 页签内可切换）。
4. **4. EXTRACTION PARAMETERS** — 设 m/z 容差（ppm 或 Da，**二选一**）、窗口内聚合策略、
   RT 半窗（默认 0.30 min）、最少扫描点数、`Maximum features per run`（作用在**峰表行数**上）
   与 `Maximum rows per run`（展开后的作业规模，超出直接中止）。
5. **5. PEAK PRESENCE** — 决定"某样本里本来没有这个峰"怎么处理：
   `Report samples without the peak as absent`（默认开）+ 噪声倍数（默认 5）+
   最少 XIC 点数（默认 3）。不确定时把噪声倍数设为 0 即关闭强度判据。
6. **6. BOUNDARY DETECTION** — 一般保持默认即可；数据噪声大时可开 `smooth_points`（仅影响定界）。
7. 点 **Run peak quality assessment**；日志实时输出进度与汇总
   （例如 `Done in 6.2 s. scored=7, absent=2, ambiguous=2, unclear boundary=1,
   no signal=2, unmatched=0`），逐文件解析也会单独打一行
   （`File 3/20 P181.raw: 2077 MS1 scan(s) in 42.0 s`）。
8. 查看与导出：
   - **Results** 页签：结果表（低分峰着色；`All rows / Peak present only / Absent only`
     三档 presence 过滤；`Show only rows needing review` 只筛真问题，不含 absent），
     `Per sample` / `Per feature` 两种视图，`CSV` / `XLSX` / `Full report (ZIP)` 三个下载；
   - **Peak view** 页签：选 feature + sample → 交互图（原始曲线、扫描点、输入 RT、峰顶、起止点、
     XIC 窗口）、残差图（仅当显示拟合曲线时出现，图注标明 display-only）、
     指标 KV 面板（含 presence 与 height/noise）、候选峰表；
   - **Inputs & mapping** 页签：样本↔文件匹配表、被拒绝的峰表行及原因；
   - **Parameters & provenance** 页签：本次全部参数与提交信息（论文、两处 commit、许可）。

### 8.3 输出物

| 导出 | 内容 |
|---|---|
| `peak_quality_<date>.csv` | 结果表（29 列，前 14 列为任务书要求列 + `presence`） |
| `peak_quality_<date>.xlsx` | 9 sheet：Results / FeatureSummary / Candidates / **AbsentPeaks** / Failures / Parameters / SampleMapping / FieldMapping / Provenance |
| `peak_quality_report_<date>.zip` | 8 个 CSV（含 `feature_summary.csv`、`peak_quality_absent.csv`）+ `provenance.txt` + `sessionInfo.txt` + `peak_quality_report.pdf` + `peaks/*.png`（每峰一张，默认上限 200） |

> 注意：全平 XIC（如 `F_NOSIGNAL` 之外的极端平段）会让上游抛 `incompatible dimensions`，
> 该行会明确显示 `score_status = failed` 及原因，**不会**被填成 0 或 NA 冒充"已评分"。

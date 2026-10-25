# Peak Quality Assessment — 第二阶段（CPC）与第三阶段（跨样本峰组）交付报告

**日期**：2026-10-19
**范围**：按任务书四、五、六、七节实现
**决策依据**：`PEAK_QUALITY_ALGORITHM_AUDIT.md` 5.1 已确认的三个决策（area 原样+标注 / sn 只输出不过滤 / DNN 只做图像+诊断）
**状态**：已实现、已测试；**未提交、未推送**

---

## 0. 一句话结论

Kumler 与 CPC 现在在**同一批候选峰**上并行运行，结果进入**同一套长表结构**但**不经任何方式合成为总分**；
CPC 的 `area` / `sn` 两个作者缺陷按决策**原样输出并标注**，`min_sn` 过滤**从不启用**；
DNN 阶段只做**峰组图像构造 + 可视化 + 缺失诊断**，`quality_probability` 恒为缺失（作者未发布权重）。

---

## 1. 交付物清单

### 新增源码（`R/peak_quality/`，8 个文件）

| 文件 | 作用 |
|---|---|
| `method_registry.R` | 三种方法的唯一权威登记：输入形态、原生指标与单位、许可、commit、**当前会话是否可执行** |
| `cpc_adapter.R` | CPC 适配层：可用性探测、参数对象构造、`chromFromTrace` + `processChromatogram` 调用、边界代码映射、逐行结果 |
| `unified_results.R` | 统一长表 / 原生指标长表 / 宽表比较 / 一致性与边界差异统计 / 列字典 |
| `compare_methods.R` | 在已存 XIC 上批量跑 CPC、组装比较结果、提取分歧案例 |
| `peak_group.R` | 跨样本峰组：成员收集、图像构造（作者契约）、缺失与漂移诊断 |
| `plot_compare.R` | 峰组热图 / 成员轨迹图 / 同一峰两方法并排指标表 |
| `eic_smooth.R` | **分析前 XIC 平滑**（默认关闭）：Savitzky-Golay / 移动平均、端点拟合、长度不足时拒绝并记录原因 |

### 修改文件（全部为**追加**，无重写）

| 文件 | 改动 |
|---|---|
| `app.R` | 追加 6 行 `source()` |
| `plot_peak_quality.R` | `pq_plot_peak_quality()` / `pq_plot_peak_base()` 增加可选 `cpc_row`（默认 NULL，向后兼容） |
| `export_peak_quality.R` | 两个导出函数增加可选参数 + 5 张新工作表 / 6 个新 CSV |
| `peak_quality_ui.R` | 新增「7. Scoring methods」「8. Cross-sample peak group」两组控件 + 2 个新标签页 |
| `peak_quality_server.R` | 方法可用性渲染、CPC 并跑、比较/峰组标签页、导出参数 |
| `tests/peak_quality/helpers.R` | 追加 6 个 source + 合成数据夹具 |

### 新增测试

| 文件 | 内容 | 断言 |
|---|---|---|
| `test_09_cpc_adapter.R` | 登记表、参数、边界代码、真实 CPC 调用、两个缺陷复现、批量与限流 | 51 |
| `test_10_unified.R` | 统一结构、raw_score 语义、指标长表、宽表比较、列字典、错位拒绝 | 42 |
| `test_11_peak_group.R` | 成员、图像契约逐条、填充/丢弃/归一化、诊断、无概率 | 43 |
| `test_12_eic_smooth.R` | SG 权重与公开核一致、端点拟合、拒绝而非填充、默认不变、presence 不变、记录与导出 | 78 |
| `ui_smoke_methods.js` | 浏览器：勾选 CPC/DNN → 运行 → 比较页 → 峰组页 → 导出 | 30 |
| `ui_smoke_smooth.js` | 浏览器：新分组位置、三项选择、窗口约束、警告提示对比度、可选中与可还原 | 26 |

---

## 2. 统一输出接口（任务书第四节）

### 2.1 字段与语义

统一表一行 = 一个 `(feature, sample, method)`。

| 列 | 说明 |
|---|---|
| `feature_id` `sample_id` `mz` `input_rt` | 与峰表一致 |
| `start_rt` `apex_rt` `end_rt` | **该行所属方法自己判定的边界**（Kumler 用本项目的定界结果，CPC 用它自己的） |
| `n_points` | 该方法用于打分的扫描点数 |
| `method` | `kumler` / `cpc` / `dnn` |
| `raw_score` | 该方法的**单个**原生标量，名称见 `raw_score_name` |
| `quality_probability` | **仅当模型真的输出概率时填写** |
| `boundary_status` | 方法无关的边界判定词表 |
| `score_status` | `ok / absent / skipped / failed / not_detected / too_few_points / not_run / unavailable` |
| `failure_reason` | 为什么没有分数，或边界问题是什么 |
| `raw_score_name` `method_version` `method_params` `presence` `engine_version` `file` | 追溯信息 |

列含义同时写入 `pq_unified_dictionary()`，并作为 XLSX 的 `ColumnDictionary` 表与 ZIP 的 `column_dictionary.csv` 一起导出。

### 2.2 关于 `raw_score` 的一处必须说明的取舍

| 方法 | `raw_score` | `raw_score_name` | 理由 |
|---|---|---|---|
| Kumler | `peak_cor` | `peak_cor` | 论文两个指标中的第一个；**它是相关系数，不是概率** |
| CPC | **空** | 空 | 包不给单一标量，只给指标组。**没有**拿 `sn` 顶替，因为 `sn` 有已知实现缺陷（审查 2.4） |
| DNN | 空 | 空 | 没有模型权重，不产生任何预测 |

**"具体指标名称另存"** 落在 `MethodMetrics` 长表：一行一个 `(feature, sample, method, metric, value, unit, note)`，
`cpc_area` 的 `unit` 恒为 `intensity x scan count`，`cpc_sn` 的 `note` 写明"作者值，从不用于过滤"。

**不允许比较、不允许平均**：代码里不存在任何跨方法的求和、加权、排名或总分列；测试 `test_10` 显式断言
"统一表与比较摘要中不存在 total/combined/composite 列"。

---

## 3. CPC 集成（任务书第二节）

### 3.1 调用路径（不改读取层，不造 XCMSnExp）

```
pq_extract_xic()  →  整窗 XIC（rt, intensity）
      ↓  同一份清洗（去 NA、排序、重复 RT 取最大）
cpc::chromFromTrace(st = rt, trace = y, param = cpcChromParam(p = 峰顶下标, ...))
cpc::processChromatogram(chrom)
      ↓  读 @results 槽
cpc_* 列 + 边界代码 + 状态
```

关键设计：**CPC 拿到的是整个 RT 搜索窗，不是 Kumler 打分用的峰切片**。否则 CPC 的边界会被输入本身钉死，
"两方法边界差异"就没有意义了。Kumler 与 CPC 共享的是**同一个候选峰顶**（`p = 该候选峰的 apex 下标`），
不是同一段切片。

### 3.2 参数

| 参数 | 值 | 说明 |
|---|---|---|
| `smooth_method` / `smooth_times` | `savgol` / 2 | 作者默认 |
| `smooth_win` | 自动 | 按作者本意 `w≈2.354σ`，σ 由轨迹自身 `FWHM/2.355` 估计，钳制在作者 `[5,21]` |
| `min_pts` / `min_inf_width` | 7 / 3 | 作者默认 |
| `min_sn` | 10（**仅记录**） | `filterPeaks()` / `characterize_xcms_peaklist()` 从不调用，**没有峰因 sn 被移除** |
| `min_w` / `max_w` | 5 / 21 | 必须显式传入，见 3.4 |

### 3.3 边界代码映射（保留原值，同时给统一词表）

CPC 的 C++ 层返回 0–3，`classes.R` 映射为 `B/V/S/R`：

| 代码 | 含义 | 统一 `boundary_status` |
|---|---|---|
| `B` | 回到基线 | `ok` |
| `V` | 谷底（紧邻共洗脱峰） | `ambiguous` |
| `S` | 肩峰 | `boundary_unclear` |
| `R` | 圆形峰 | `boundary_unclear` |

原始代码同时保存在 `cpc_front_code` / `cpc_tail_code`，不丢失信息。

### 3.4 实现期新发现的问题（补充记录）

1. **`min_w` / `max_w` 必须显式传**。`cpcChromParam()` 不传时 S4 槽位为 `NULL`，
   `processChromatogram()` 在 `if (getParam(...,"smooth_win") < getParam(...,"min_w"))` 处抛
   `argument is of length zero`，且报错位置与真实原因无关，极难定位。适配层与测试均已固定该行为。
2. **平滑窗口不能取 `n/3`**。窄峰上会过度平滑（实测 FWHM 偏高约 9%、峰高偏低 5%）。
   改为按作者本意用轨迹自身 FWHM 推导后，FWHM 与真值差 < 3%、峰高差 < 3%。

### 3.5 可用性：外部包，不 vendored

`cpc` 是 **GPL (≥2)** 的编译包，且强依赖 `xcms`。因此：

- 源码**不复制**进本仓库，只调用安装好的包；
- 界面用 `find.package()` 探测（**不加载**，避免每次重绘都去拉 xcms）；
- 隔离库用 `options(dmetfinder.cpc.lib=)` 或环境变量 `DMETFINDER_CPC_LIB` 指定；
- 未安装时复选框**置灰**并显示原因，不会假装可用，也不会阻断 Kumler 的运行。

本机验证环境：`cpc 0.1.0` + `xcms 4.10.1`，装在 `.workbuddy/reference/rlib`（用户主 R 库零污染）。

### 3.6 性能

| 指标 | 实测 |
|---|---|
| 首次调用（含 `loadNamespace("cpc")` → xcms） | ≈ 10 s |
| 随后每条 XIC（61–121 点） | **6–10 ms** |
| 行数上限 | `cpc_max_rows`（默认 20000），超出的行标 `not_run` 并写明原因，**不丢行** |

---

## 4. 跨样本峰组（任务书第三节，本阶段只做到图像）

### 4.1 与作者 `peakGroupImageMatrixAndPlot.R` 的逐条对照

| 作者步骤 | 本实现 | 测试断言 |
|---|---|---|
| 只保留有信号的样本，0 信号**剔除**而非补 0 | `n_signal` 之外的成员进 `dropped` | "a member without signal is removed" |
| `approx(method="linear", rule=2, ties="mean")` 插值到等间隔 RT 网格 | 同 | "rule = 2 pads the edge with a constant" |
| 不足固定行数补 0 | `pad_rows`（0=不补；作者用 30/63） | "can be padded to 63 rows" + "padded rows carry no sample id" |
| 除以**全局**最大值 | 同 | "normalised by its global maximum" |
| 追加一行窗口掩码 | `mask`（默认全 1；可传 `mask_rt` 收窄） | "a narrower mask marks only the columns inside it" |

图像尺寸两套发布配置**并列记录**在 `PQ_DNN_IMAGE_SPEC`：论文 64×64（63 样本 + 1 掩码行），
作者 R 脚本默认 31×200。默认按论文 64 列；界面可改。

### 4.2 缺失情况诊断

每个 feature 一行：`n_rows_in_table / n_signal / n_absent / n_no_xic / n_dropped_zero_signal /
n_image_rows / n_image_cols / n_padded_rows / n_extrapolated / n_multi_peak_members /
apex_rt_median / apex_drift_median_abs / apex_drift_max_abs / admissibility`。

`admissibility` 词表：

| 值 | 含义（任务书 3.1 要求的几种情形） |
|---|---|
| `ok` | 至少 `min_series` 个样本有信号，可构造图像 |
| `single_member` | 只有 1 个样本有信号 → **明确提示不适用**，不出图、不出概率 |
| `no_signal` | 该 feature 在任何样本都没有信号 |
| `image_failed` | 图像构造失败（原因另存） |
| `no_window` | 没有可用的 RT 窗口 |

另外统计：RT 漂移（各成员 apex 相对中位数的偏差）、`n_extrapolated`（未覆盖整个窗口、被 `rule=2` 外推的成员数）、
`n_multi_peak_members`（成员内部存在多个**有显著 prominence** 的极大值，即共洗脱/多峰）。
"多个极大值"用与定界器一致的相对 prominence 阈值（5%），避免把噪声纹波误判为共洗脱（有专门的反向测试）。

### 4.3 为什么不出概率

作者仓库 19 个文件**不含任何权重**，`ApplyPeakPredictionModel.R` 仍是占位符
`modelFile <- "modelFileName.h5"`；且需要人工标注训练集与 Python/TensorFlow 环境。
因此本阶段：**能构造、能看、能诊断，不能分类**。`quality_probability` 恒缺失，
界面与 `pq_method_available("dnn")` 都明说原因。

---

## 5. 界面（任务书第五节）

| 要求 | 实现 |
|---|---|
| 方法选择 | 侧栏「7. Scoring methods」：Kumler（常开）、CPC（可勾选/置灰）、DNN（图像） |
| 查看原始 XIC | 原有 Peak view 不变 |
| 查看各方法峰顶与边界 | Peak view 叠加 CPC 边界（紫色点线）与 CPC apex（紫色点划线），与 Kumler 绿色实线区分 |
| 查看 CPC 峰形指标 | Peak view 的「Same peak, both methods」并排表 + Compare methods 的宽表/长表 |
| 查看 Kumler 参考曲线及残差 | 原有 display-only beta 拟合与残差（未改） |
| 查看跨样本峰组图像 | Peak group 标签页：热图 + 成员轨迹 + 单组诊断 + 全特征诊断 |
| 查看分类结果、缺失原因、方法分歧 | `admissibility`/`reason`；Compare methods 的「Rows where the methods disagree」+ `d_*_rt` |
| 导出统一结果表与参数记录 | XLSX 16 张表 / ZIP 17 个文件，含 `Parameters`、`ColumnDictionary`、`Methods`、`Provenance` |

---

## 6. 验证（任务书第六节）

### 6.1 固定 XIC 对照（合成高斯峰，真值 apex=4.5 min、σ=0.06、amp=2e5）

| 指标 | CPC 输出 | 真值 | 偏差 |
|---|---|---|---|
| `rt` | 4.5000 | 4.5000 | 0 |
| `fwhm` | 0.1433 | 0.1413 | +1.4% |
| `height` | 197 636 | 200 000 | −1.2% |
| `tf` | 1.0104 | 1.0 | +1.0% |
| 边界代码 | `B` / `B` | 基线分离 | 正确 |
| `area` | 3.6e6 | RT 积分 1.8e4 | **比值 ≈198，即"强度×点数"** |
| `sn` | 8.00（低 S/N 峰） | — | `min_sn=10` 仍返回，**证明未过滤** |

采样率翻倍实验：RT 梯形积分比值 **0.956**（不变），CPC `area` 比值 **1.915**（近似翻倍）
→ 审查 2.3 的"按下标积分"缺陷被稳定复现，且已被我们的标注覆盖。

### 6.2 自动化测试

| 套件 | 结果 |
|---|---|
| `tests/peak_quality/run_all.R`（11 个文件） | **11/11 通过，452 项断言** |
| 其中新增 `test_09/10/11` | 51 + 42 + 43 = **136 项** |
| `ui_smoke.js`（原有流程） | **19/19** |
| `ui_smoke_methods.js`（新流程，勾选 CPC+DNN） | **30/30** |

浏览器实测日志（fixture 2 raw × 10 行）：`scored=7, absent=2, ambiguous=2`；
`CPC: ok=6, not detected=1, …`；比较页 `both scored=6, kumler only=1, neither=1, median |Δapex|=0`。

### 6.3 明确**没有**做的事

- 没有宣称任何分类准确率（无权重、无本项目标注集）
- 没有把作者训练集上的性能外推到油菜/植物数据
- 没有把 CPC 或 DNN 的源码复制进仓库
- 没有修改 Ms1Geter / Ms2Geter / DMetFinder 的任何既有逻辑与输出
- 没有提交或推送 Git

---

## 7. 继续推进需要的输入

1. **人工标注集**（好峰/坏峰/不确定，含独立测试集划分）——没有它，DNN 路线无法进入训练；
2. **是否允许安装 Python 运行时**（TensorFlow/keras + 隔离子进程），用于将来的推理骨架；
3. **CPC 是否随发行版分发**的许可决定（GPL-2+ 会传染；当前策略是"可选外部依赖"）。

在这三项确定之前，第四阶段（多方法比较 → 人工复核 → 批量导出）中的
"多方法比较 + 批量导出"已完成，"人工复核标注"尚未开始。

---

## 8. 新增：分析前 XIC 平滑（回应"是否考虑对峰形平滑"）

### 8.1 原来的状况（先纠正一个可能的误解）

项目里**原本就有**一个 `smooth_points` 参数，但它**不平滑被评分的强度**：

- 它只用于**定位峰顶**（`pq_detect_peaks()` 内部对轨迹做移动平均后找局部极大），
- 以及在图上画一条"仅用于显示"的辅助线，
- 送到 Kumler 打分函数的是**原始强度**（`pipeline.R` 里原本写着 *author scoring on the raw (unsmoothed) peak slice*）。

CPC 自身有 `savgol` 平滑（`smooth_method="savgol"`, `smooth_times=2`，窗口按 FWHM 自动推导），那是 CPC 算法的一部分，
不是本项目的开关。所以：**确实没有"先把 EIC 平滑再分析"的选项**——用户的判断是对的。

### 8.2 新增的开关

侧栏新增 **「5. XIC smoothing before analysis」**（默认 `none`，即完全不改变现有行为）：

| 项 | 取值 |
|---|---|
| `eic_smooth_method` | `none` / `savgol`（局部二次拟合）/ `movavg`（居中移动平均） |
| `eic_smooth_window` | 奇数扫描点数，默认 7，范围 3–31（偶数自动进到下一个奇数） |
| `eic_smooth_order` | 仅 savgol，默认 2，上限 3（阶数 ≥ 窗口-1 时不平滑并记录原因） |

**作用范围（一条分析轨迹，一个答案）**

```
原始 XIC ──┬─→ presence（峰高、逐点噪声、有没有峰）   ← 始终用原始
           └─→ 平滑 ──→ 边界检测 ──→ 打分切片 ──┐
                                    ├→ CPC 输入   ← 与 Kumler 同一条轨迹
                                    └→ 峰组图像   ← 模型输入用分析轨迹
```

- 平滑开启后：边界、`peak_cor`、`SNR`、CPC 输入、峰组图像**全部**用平滑轨迹；
- **presence 不受影响**：峰高与噪声（`1.4826·MAD(diff)/√2`）始终在原始轨迹上计算，
  且 presence 使用**原始轨迹自己的检测结果**（`det_raw`），因此"有没有峰"的判定与开关无关。
  这一点在真实 .raw 上逐位验证过（见 8.6）。

### 8.3 为什么必须这样划界

presence 的噪声估计依赖**相邻点差分**。平滑去掉的正是高频成分，如果让 presence 看见平滑轨迹，
噪声估计会被人为压低 → 纯噪声也会被判成"有峰"。所以：

> 平滑改变的是**分数**，不是**有没有峰**。

同理，开启平滑后 `peak_cor` / `SNR` **不再是作者的原始数据输出**。这一点被强制记录：
结果表新增 `eic_smoothing` / `eic_smoothing_applied` 两列、统一表新增 `xic_smoothing` 列、
Kumler 参数串追加 `xic_smoothing=savgol_w7_o2`、Parameters 页与 provenance 文本都会声明
"these scores are NOT the author's raw-data output"。

### 8.4 端点处理（不凭空造点）

| 方法 | 端点做法 |
|---|---|
| Savitzky-Golay | 用**完整窗口**拟合多项式，再在端点的真实位置求值（不是外推、不是复制邻居） |
| 移动平均 | 用窗口内**实际存在的点**取均值（截断窗口）；与旧的 `pq_movavg()` 保留原始端点不同，避免出现阶跃 |

- 轨迹点数 < 窗口 → **不平滑**，写日志并在行内记 `eic_smoothing_applied = FALSE`，**不补 0**；
- 轨迹含非有限值 → 不平滑并记录原因；
- 二次拟合在陡降处可能下冲到负值 → 钳到 0 并记 `n_clamped`（强度不能为负，负基线会破坏检测器的比例计算）。

### 8.5 两种方法对真实峰形的效果（合成高斯 + 实测）

165 scans/min、峰 FWHM ≈ 41 个扫描点、噪声为峰高的 2.4%：

| 窗口 | savgol 峰高保留 | savgol FWHM | savgol 噪声残留 | movavg 峰高保留 | movavg 噪声残留 |
|---|---|---|---|---|---|
| 5 | 99.8% | 0.95× | 62% | 98.6% | 36% |
| 7 | 99.9% | 0.98× | 46% | 98.1% | 28% |
| 9 | 99.1% | 0.98× | 41% | 97.4% | 23% |
| 11 | 98.9% | 0.98× | 36% | 96.9% | 22% |

结论：**Savitzky-Golay 保形明显更好**（峰高几乎不掉），所以默认方法选它；
移动平均噪声压得更狠但会把峰压扁，对形状类指标不利。

### 8.6 真实数据验证（P173.raw，6 个真实特征）

| feature | presence | peak_cor 关→开 | SNR 关→开 |
|---|---|---|---|
| P173_F001 | present→present | 0.2218 → 0.3582 | 1.4 → 1.7 |
| P173_F002 | present→present | 0.6035 → 0.7245 | 3.9 → 9.9 |
| P173_F003 | present→present | 0.4173 → **0.3288** | 10.6 → 12.3 |
| P173_F004 | present→present | 0.4472 → 0.5140 | 3.6 → 8.2 |
| P173_F005 | present→present | 0.7411 → 0.7864 | 6.6 → 14.2 |
| P173_F006 | present→present | 0.5046 → 0.8069 | 3.6 → 7.6 |

- `presence` / `peak_height` / `xic_noise` 在两次运行中**逐位一致**（`all.equal` 为 TRUE）；
- 分数并非"一律变好"：F003 的 `peak_cor` 下降了（0.4173 → 0.3288），因为平滑把峰顶移动了
  （3.251 → 3.270 min）且边界随之变化。这是**换了一条轨迹**的结果，不是"改进"，
  所以报告不给"平滑更好"的结论，只给"平滑会改变哪些数、以及如何追溯"。

### 8.7 实现中踩到的三个坑（已固化）

1. **用"平滑后的峰顶下标"去读原始强度会把峰高读成 0**：噪声轨迹上平滑后的极大点可能落在原始值被
   `pmax(y,0)` 截断为 0 的位置。正确做法是让 presence 用**原始轨迹自己的检测结果**，公式不动。
2. **`selectize` 接管 `selectInput`**：原生 `<select>` 只剩当前值一个 option，UI 断言必须从
   `.selectize-dropdown .option` 读，并且要点击选项而不是 `page.select()`。
3. **`.side-group__title` 被 CSS 转成大写**，`innerText` 返回的是**渲染后**文本，
   任何断言都必须忽略大小写。

### 8.8 验证汇总

| 项 | 结果 |
|---|---|
| `run_all.R` | **12/12 文件、531 断言、0 失败**（新增 test_12 共 78 项） |
| 默认行为回归 | test_08 presence 仍 53/53，`test_12` 断言默认运行"分析轨迹即原始轨迹（同一对象）" |
| UI | `ui_smoke_smooth.js` **26/26**；警告提示对比度 6.84:1（WCAG AA） |
| 绘图 | 关闭时只画原始；开启后叠加 "XIC analysis trace (Savitzky-Golay w=7)"；PDF/PNG 基础图正常 |


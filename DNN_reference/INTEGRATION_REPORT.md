# 接入报告 — DNN 作为独立方法接入 Peak Quality

> 记录「改了哪些文件、为什么改、DNN 结果如何与既有结论共存」。
> 对应任务书阶段 D + E + G 的代码侧。
>
> 日期：2026-10-21

---

## 1. 模块边界

新增四个文件，职责单一，谁都不越界：

| 文件 | 职责 | 不做什么 |
|---|---|---|
| `R/peak_quality/pq_dnn_data.R` | 把已有 XIC 拼成作者格式的峰组图（31×200） | 不读原始文件、不训练、不打分 |
| `R/peak_quality/pq_dnn_integration.R` | 模型发现/校验、调 Python、结果挂表、状态与释义 | 不改任何既有指标 |
| `DNN_reference/source_code/pq_dnn_train.py` | 训练（命令行，一次性） | 不被 UI 调用 |
| `DNN_reference/source_code/pq_dnn_predict.py` | 批量推理（读固定 .h5） | 不训练、不改阈值以外的任何东西 |

「训练」与「推理」是两个独立动作，这条在代码上就是两个文件，没有共同入口。

---

## 2. 峰组图怎么来的

### 2.1 复用了已有 XIC，不重读文件

`pq_dnn_batch(rows, detail, ...)` 接收的 `detail` 是 Peak Quality 管线**已经算出来**的
逐 (feature, sample) 结果，里面带着抽取好的 XIC。因此构建一个峰组图不需要再碰原始
文件，成本是几百个浮点数而不是一次文件解析。这满足「按原始文件分组读取」的既有设计。

### 2.2 严格照作者几何

| 参数 | 值 | 来源 |
|---|---|---|
| 网格点数 | `floor(1 / 0.005)` = **200** | `peakGroupImageMatrixAndPlot.R:402` |
| 网格中心 | `(rtMax + rtMin) / 2` | `:399` |
| 网格范围 | 中心 ± `RtDur/2` = ±0.5 min | `:405-407` |
| 插值 | `approx(method="linear", rule=2, ties=mean)` | `:344` |
| 非正 RT | 置 0 | `:350` |
| 点数 ≤ 2 | 整行 0 | `:355` |
| 成员筛选 | 窗口内最大强度 > 0 | `:418` |
| 成员上限 | 30 行；超过则前 21 高强度 + 9 随机 | `:428`, `propHighPeaks=0.7` |
| 补齐 | 不足 30 行补 0 行 | `:462` |
| 归一化 | 全矩阵除以最大值 | `:478` |
| 窗口标记行 | 第 31 行，窗内 1 窗外 0 | `:486` |
| 导出 | 0 写成 NA | `:497` |

**唯一的偏离**：作者从 MZmine 峰表读 `windRtMin/windRtMax`，我们没有那张表，改用
「该 feature 所有样品检测到的峰边界并集」，无边界时回退到「输入 RT ± 0.5 min」。
选了哪条路径写在每组的 `rt_bounds_from` 列里（`detected_peak_edges` /
`input_rt_fallback`），不留给读者猜。

**随机性**：作者的 `sample()` 无种子。这里加了 `seed` 参数并默认固定，使结果可复现；
同一种子同一次抽样有测试锁死。

### 2.3 31×200 与 64×64 之间：转置，不是缩放

作者 R 流产出 31×200（行 = 30 样品 + 标记行，列 = 200 个时间切片），
论文模型吃 64×64。**仓库里没有转换代码**，但两者的轴向关系是可以由数据确定的：

| 证据 | 结果 |
|---|---|
| 最后一**行**是否只含 0/1（1304 张） | 只有 428 张命中 |
| 最后一**列**是否只含 0/1（1304 张） | **1304 张全部命中** |
| 真实测试集转置后重算 AUC | 0.9867 → **0.8755** |

结论：模型的 64×64 是 **行 = 64 个时间切片，列 = 63 个样品 + 末列窗口标记**，
与 R 流的布局正好转置。

`pq_dnn_to_model_geometry()` 的做法：

* 时间轴 200 → 64，按下标等距取样（`ci <- round(seq(1, 200, length.out = 64))`）；
* 样品轴**不压缩、不插值**：样品保持身份占前 30 列，其余列**补 0**
  （读作"该样品此处无信号"）。补 0 是诚实的，插值出并不存在的样品不是；
* 标记列取自原生标记行，与样品列用同一组下标压缩。

正确性有往返验证：把真实 64×64 图拆成 31 行原生布局再转回，前 30 列与标记列
**逐元素相同，最大绝对差 0**。`test_15` 用 10 项断言锁住这个语义。

即便如此，**这是我们的重建，不是作者的**。所有经过该转换的行一律
`dnn_applicability = approximate_resampled_input`，绝不写 `native_geometry`。

**这条修正是有代价换来的**：第一版直接对 31×200 做 2-D 最近邻缩放（样品留在行上），
三个干净的合成峰只拿到 0.4638 / 0.4107 / 0.4445，全被判为不可接受；
改成转置式转换后同样三个峰拿到 0.9643 / 0.9284 / 0.9687。
模型不会因为朝向错了而报错，它只会静默给低分——所以这条必须写进代码而不是注释。

---

## 3. DNN 结果如何挂到表上

### 3.1 八个新列，只增不改

```
dnn_model_version  dnn_input_status  dnn_prediction  dnn_score
dnn_threshold      dnn_source        dnn_applicability  dnn_error
```

`pq_dnn_attach()` 只做 `rows[[col]] <- ...` 这八次赋值。测试
`test_16_dnn_integration.R` 逐列断言 `peak_cor`、`SNR`、`quality_class`、
`quality_rule` 在挂载前后**完全相同**。

### 3.2 关联键是 `feature_id`，不是 (feature, sample)

模型的评价单位是**峰组**，所以一个 feature 的所有样品行共享同一个分数。
这是语义决定的，不是实现偷懒——把它拆成逐样品分数会伪造一个模型从未给出过的量。

### 3.3 状态而不是 0 分

| 情况 | `dnn_input_status` | `dnn_score` |
|---|---|---|
| 正常打分 | `ok` | 模型输出 |
| 这个 feature 没进本次推理 | `not_in_model_run` | `NA` |
| 图构建失败（窗内无信号） | `no_signal_in_window` | `NA` |
| 形状与模型不符 | `shape_mismatch` | `NA` |
| 根本没有权重 | `unavailable` | `NA` |

**没有一种情况会写成 0。** 0 分是一个判断，缺测不是判断。

### 3.4 明确禁止的映射

任务书禁止「true peak → high_quality」。代码里不是靠注释约束，而是靠**结构**：
`pq_dnn_attach()` 从未读取 `quality_class`，也从未写入它。`quality_class` 由
`pq_classify()` 单独产生，两者之间没有数据通路。测试用断言把这个通路缺失固化下来。

---

## 4. 模型发现与校验

`pq_dnn_find_model()` 要求三件事同时成立才认一个模型可用：

1. `.h5` 文件存在；
2. 同名 `_train_log.json` 存在；
3. 日志里记的 `model_sha256` 与文件实际 SHA-256 一致。

任何一条不满足，状态就是 `model_load_failed` 并给出具体原因。这样做是为了防止
「换了一个权重文件但日志还是旧的」这类静默错误——那会让导出的
`dnn_model_version` 变成假话。

无权重时，UI、CSV、XLSX、ZIP 四处显示的字符串完全一致：

```
DNN prediction unavailable: model weights not available
```

---

## 5. 界面

新增第 8 个页签 **DNN**（在 Peak group 之后、Inputs & mapping 之前）：

| 区块 | 内容 |
|---|---|
| Model state | 可用/不可用横幅 + **上次运行状态行** + 键值表（状态、路径、SHA、训练时间、种子、测试 AUC、Python 运行时、对 `quality_class` 的影响） |
| What the score means | 分数不是校准概率的说明；作者三个阈值（0.5 / 0.4 / topleft）都列出 |
| Peak-group predictions | 一 feature 一行的预测表 + CSV 下载；无模型时显示固定提示语 |

运行入口在左侧方法区：勾选 `DNN: score cross-sample peak groups (Kantz 2019)`
后出现阈值输入（默认 0.5，即 `ApplyPeakPredictionModel.R` 的取值），点 Run 即执行。

「上次运行状态行」是这一轮补的，理由很直接：预测表为空时，读者无法区分
「模型看不上任何峰」和「模型根本没跑」。状态行把这两件事分开，并说明本次输入
是否经过几何转换。

页面上**仍然不存在任何「训练」按钮**。训练只能从命令行发起。

---

## 6. 导出

### 6.1 XLSX / CSV

`pq_result_columns()` 在 `quality_reason` 之后插入八个 `dnn_*` 列。位置是有意的：
先给单峰证据，再给单峰判定，再给峰组级方法，最后是状态列。

### 6.2 Provenance

`pq_provenance_lines()` 新增 `dnn` 参数，默认 `"auto"`，自动追加以
`DNN method` 打头的段落，内容包括：

- 论文 DOI、代码 commit、代码许可证、数据集编号与许可证
- 当前 DNN 状态（`available` / `model_not_trained` / `model_load_failed`）
- 有权重时：权重路径、SHA-256、训练时间、种子、TensorFlow 版本、测试 AUC
- 分数语义（模型输出，非校准概率）与三个阈值的出处
- 输入几何与重采样标注
- **「effect on results: none」** 这一行，明说 DNN 不改任何既有指标

无权重时同样输出该段，只是内容变成「没有权重」和「渲染出的峰组图不是预测」。

---

## 7. 纪律核对

| 任务书要求 | 实现 | 证据 |
|---|---|---|
| 不自动删峰 | 没有删除路径 | 无 `subset`/`filter` 作用在 `rows` 上 |
| 不跨方法合成总分 | 无加权/求和/排名 | `pq_dnn_attach` 只赋值 |
| 不把 unknown 当噪声 | DNN 不触碰 `quality_class` | `test_16` 断言 |
| 不伪造概率 | 文案与列名统一为「score」，明确非校准概率 | `pq_dnn_score_note()` |
| true peak 不映射为 high_quality | 结构上无通路 | `test_16` 断言 |
| 缺测不写 0 | 状态列 + `NA` | `test_16` 断言 |
| 训练与推理分离 | 两个脚本、无共同入口 | 文件结构 |
| 不隐式训练 | UI 无训练入口 | UI 代码 |
| 权重版本可追溯 | SHA-256 双端校验 | `pq_dnn_find_model()` |
| 导出含模型版本 | provenance + `dnn_model_version` | 导出代码 |

---

## 8. 与既有测试的兼容

`tests/peak_quality/helpers.R` 的加载列表新增两个文件，顺序在 `quality_class.R`
之后、`compare_methods.R` 之前（`score_adapter.R` 的 `pq_provenance_lines()` 在运行时
查找 `pq_dnn_provenance_lines()`，因此加载顺序不影响正确性，只影响可读性）。

既有 14 个测试文件未改动任何断言。`test_15`、`test_16` 为新增。

---

## 9. 未接入的部分（明确列出）

1. **`buildNeuralNetworkModel.R` 那条 31×200 训练路径未实现**。它需要 31×200 的人工标注，
   我们没有，也不打算用 64×64 的标注冒充。
2. **没有真实数据的独立验证**。权重可用，链路可用，但没有带标签的 DMetFinder 数据，
   所以"在你自己的数据上准不准"这个问题的答案仍然是"未知"。
   详见 `VALIDATION_REPORT.md` 第 8 节：缺的不是代码，是标签。
3. **没有做批次/仪器漂移检测**。若用户数据与作者数据分布差异过大，模型不会报警，
   只会给分数。当前唯一的缓解手段是 UI 上的几何提示与模型卡里的第 4 节。

已在本轮补上的（此前列为未接入）：

| 原先缺口 | 现在的状态 |
|---|---|
| `method_dnn` 复选框不驱动构图 | 已驱动：勾选后走 `pq_dnn_apply()`，结果写回 `results()` |
| 峰组图未落盘到 `processed_data/matrices` | 已落盘到 `processed_data/matrices/<run_tag>/`，预测到 `processed_data/predictions/<run_tag>/` |
| UI 里没有推理触发 | 有：DNN 复选框 + 阈值输入；页签里有「上次运行」状态行 |
| `pq_dnn_apply()` 一键编排 | 新增，含五个明确失败状态（`no_rows` / `model_not_trained` / `no_windows` / `no_usable_images` / `export_failed`） |
| DNN 源文件未在 `app.R` 加载 | 已加 `pq_dnn_data.R` + `pq_dnn_integration.R` 两行 |

---

## 10. 全量测试

`Rscript tests/peak_quality/run_all.R` → **16/16 文件通过，739 项断言全过**。

| 文件 | 断言数 | 覆盖 |
|---|---|---|
| test_01–test_14 | 611 | 既有功能，本轮**未改动任何断言** |
| test_15_dnn_data | 74 | 峰组几何、网格、插值、成员抽样、导出约定、**模型布局转换与往返** |
| test_16_dnn_integration | 54 | 八列挂载、`quality_class` 不变、状态而非 0 分、近似输入标注、失败路径不伪造分数 |

本轮测试自身修掉的两个缺陷（记录在此，因为它们会让测试说谎）：

* `test_15` / `test_16` 原先**缺少 `pq_summary()` 收尾与失败退出码**——里面的断言即使
  失败也不会让 `run_all.R` 报错。补上后计数才可信（74 / 54）。
* `test_15` 里曾有一条 `... || TRUE` 的断言，恒为真。已替换为真实断言
  （"原生标记行没有作为一行存活"）。

代码侧同时修掉一个被测试暴露的真 bug：`images[[k]] <- NULL` 会**删除**列表元素而非
存入 NULL，导致后续下标越界；已改为 `images[k] <- list(...)`。

---

## 11. 2026-10-21 更新（DNN + CPC + Kumler 三方法整合）

本节覆盖上面若干条已过时的表述。详细记录见根目录
`THREE_METHOD_IMPLEMENTATION_REPORT.md`。

### 11.1 权重不再是"不存在"

前面几节按"作者未发布权重、本构建只画图"写成。权重此后已**本地训练并通过校验**
（`models/edml15.h5`，SHA-256 `308549505003…`，seed 20190301，
测试 AUC 0.9867，论文 0.988）。相应地：

- `pq_method_available("dnn")` 不再硬编码 `FALSE`，改为查询权重文件并校验它与
  `*_train_log.json` 的哈希一致；不一致时报 `model_load_failed` 并给原因。
- `PQ_METHODS$dnn$probability` 由 `TRUE` 改为 **`FALSE`**：作者从未校准网络，
  输出是分数不是概率。这一条此前写错了，会让统一表把分数当概率。
- 无权重时的对外 token 统一为 **`model_not_available`**，具体原因放在
  `cause`（`model_not_trained` / `model_load_failed` / 哈希不符）。

### 11.2 八列变十列

`pq_dnn_attach()` 现在写 10 列：新增 `dnn_status` 与 `dnn_scope`。
`dnn_scope` 在**每一行**（含失败行）恒为 `peak_group`，因为同一个组分数会被重复到
该 feature 的每个样品行上，不标范围就会被读成"每样品概率"。

### 11.3 新增几何守卫（本文件第 4 节遗漏的关键一环）

`pq_dnn_validate_input()` / `pq_dnn_validate_batch()` 检查 5 项：形状、**标记轴**、
标记非空、值域 [0,1]、样品区有信号。任一项不过则 `pq_dnn_apply()` 在
**导出矩阵与启动 Python 之前**返回 `input_geometry_invalid`。

原因见 `test_18`：方形矩阵转置后尺寸完全正确，Keras 不会报错，只会返回一个
看起来合理的低分。第一次接入时（样品轴放错）三个干净合成峰正是因此拿到 0.41–0.46。

### 11.4 三张表与页面

新增 `R/peak_quality/result_tables.R`：`pq_group_results()`、`pq_sample_results()`、
`pq_method_metrics()`、`pq_provenance_block()`。界面新增第 9 个页签
**Three methods**（GroupResults / SampleResults / 并列摘要，无总分），
DNN 页签新增**模型输入热图**与**输入检查表**。

### 11.5 测试

18 个测试文件、891 项断言。新增 `test_17`（97）与 `test_18`（51）。
另外发现并修掉一个影响可信度的缺陷：`test_01`–`test_12` 共 11 个文件原先
**没有失败退出码**，断言失败不会让 `run_all.R` 变红（`test_11` 当时就是
"status OK / 3 failed"）。现已全部补上 `if (!ok) quit(status = 1)`。

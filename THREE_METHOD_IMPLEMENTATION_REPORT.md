# 三方法 Peak Quality 实施报告（DNN + CPC + Kumler）

日期：2026-10-21　项目：`G:\...\DMetFinder1.0.3\DMetFinder`　分支：`main`（未提交）

本报告对应任务书第八节验收顺序 A–G。文中每个数字都能由仓库内的脚本或测试复现；
脚本路径与测试名一并给出。凡未实测的部分，明确标注"未实测"，不写"应该可用"。

---

## 0. 结论速览

| 方法 | 能否真实运行 | 粒度 | 数据来源 | 本次状态 |
|---|---|---|---|---|
| Kumler | **能**，且已跑过真实 .mzML | `single_sample`（每 feature×sample） | `R/peak_quality/vendor/squallms_qscore.R`，逐字 vendored | 原有实现，本次只补状态字段与表格 |
| CPC | **能**（2026-10-21 装入隔离库 `C:/rlib/cpc` 并跑通） | `single_sample` | 外接 GPL 包，**未 vendored** | 缺包时返回 `not_installed`，不产出指标、不降级为低质量；有包时真实产出 `cpc_*` 指标 |
| DNN | **能**，已用已训练权重跑通端到端 | `peak_group`（每 feature 一次） | 本地训练权重 `models/edml15.h5`，与训练日志 SHA-256 互校 | 本次补状态/范围字段、几何守卫、界面输入图 |

论文基准仍然复现：训练 AUC **0.9946**、校准 AUC **0.9830**、测试 AUC **0.9867**
（论文 0.992 / — / 0.988），权重 SHA-256 `308549505003…`，seed 20190301，40 epochs，CPU 23.1 s。

CPC 环境（2026-10-21 装好）：`cpc` 0.1.0 + `xcms` 4.10.1 + `MSnbase` 2.38.1，R 4.6.0 +
Rtools45 本机编译，隔离库 `C:/rlib/cpc`（25 个包 / 95 MB）。R 主库与用户库未写入任何包。

---

## 1. 审查基线（阶段 A）

开工前的实际状态（`git status`）：

- **工作树有未提交改动**：`.gitignore`、`R/config.R`、`R/dmetfinder_functions.R`、`app.R`、
  `server/*`、`shiny_app/*`、`ui/*` 为已修改；`R/peak_quality/`、`tests/`、`DNN_reference/`、
  四份 `PEAK_QUALITY_*.md` 为未跟踪。**本次没有提交也没有推送**。
- 已读完：`PEAK_QUALITY_ALGORITHM_AUDIT.md`、`DNN_reference/MODEL_CARD.md`、
  `REPRODUCTION_REPORT.md`、`VALIDATION_REPORT.md`、`INTEGRATION_REPORT.md`。

已存在且**本次复用、未重写**的部分：

| 既有能力 | 文件 |
|---|---|
| XIC 提取（仅 MS1）、文件缓存、按文件调度 | `xic_extract.R`、`pipeline.R` |
| 峰边界/峰顶检测、presence 判定（用原始轨迹） | `peak_detect.R`、`presence.R` |
| Kumler 适配器（不改算法，只整形） | `score_adapter.R` |
| CPC 适配器（调 `cpc::chromFromTrace` + `processChromatogram`） | `cpc_adapter.R` |
| 方法登记（唯一来源） | `method_registry.R` |
| 峰组图（作者 31×200 布局）×2 | `pq_dnn_data.R` |
| DNN 桥（发现/校验权重、导出矩阵、调 Python、回填） | `pq_dnn_integration.R` |
| 统一长表、宽表、字典 | `unified_results.R` |

审查发现并修复的**过时结论**（都在本次改动里）：

1. `method_registry.R` 仍写着"作者未发布权重，所以 DNN 永远不可用"，`pq_method_available("dnn")`
   硬编码 `FALSE`。这与实际状态矛盾——权重已本地训练并通过校验。已改为**查询权重文件**，
   且只有当权重 SHA-256 与训练日志一致时才算可用。
2. `information$probability = TRUE` 是错的：作者代码里没有任何校准步骤（无 isotonic、无 Platt），
   输出是分数不是概率。已改为 `FALSE`，并把这一点写进注册表与导出。
3. `test_09`、`test_11` 里有 3 条断言依赖"权重不存在"，已按新契约为"可用性跟随权重"。

---

## 2. 改动清单

| 文件 | 改动 | 原因 |
|---|---|---|
| `R/peak_quality/method_registry.R` | dnn 条目重写（commit `94237bf`、数据 MassIVE CC0、权重来源、局限）；`probability=FALSE`；新增 `pq_method_scope()`；`pq_method_available("dnn")` 改为查权重（带 path+size+mtime 记忆化） | 登记表必须是"能否执行"的唯一权威，不能与事实脱节 |
| `R/peak_quality/pq_dnn_data.R` | 新增 `pq_dnn_validate_input()` / `pq_dnn_validate_batch()` / `pq_dnn_model_geometry()` | 方向或尺寸错误的输入**不会让 Keras 报错，只会静默给低分**，必须显式拦截 |
| `R/peak_quality/pq_dnn_integration.R` | `pq_dnn_attach()` 增加 `dnn_status`、`dnn_scope`（每行恒为 `peak_group`）；`pq_dnn_apply()` 在导出/预测前跑守卫，失败返回 `input_geometry_invalid` | 任务书 2.1.5 / 2.1.11；无合法输入时不得输出误导性分数 |
| `R/peak_quality/result_tables.R`（新） | `pq_group_results()`、`pq_sample_results()`、`pq_method_metrics()`、`pq_provenance_block()` | 任务书第四节四张表 |
| `R/peak_quality/unified_results.R` | `pq_metrics_long()` 增加 `status` / `scope` / `model_version` 三列 | 长表必须能说明"这个值是没算还是算失败" |
| `R/peak_quality/cpc_adapter.R` | 缺包状态 `unavailable` → `not_installed`；新增 `pq_cpc_status_family()`；**新增 `pq_cpc_smooth_win_info()` 与 `smooth_win_source`**（`fwhm` / `one_third_fallback` / `user`） | 任务书 2.2.9 状态词表；平滑窗来源必须可追溯（真实数据上它决定检出率，见 3.2） |
| `R/peak_quality/compare_methods.R` | `pq_run_cpc()` 统计每行的窗来源并打一行日志，返回值多一个 `smooth_win_source` 表 | 让"大面积 not_detected"在日志里可解释，而不是看着像数据干净 |
| `.Renviron`（新，已 gitignore） | `DMETFINDER_CPC_LIB=C:/rlib/cpc` | 安装位置只写一处；R 从项目根启动即生效 |
| `.workbuddy/tools/install_cpc.R`（新） | 隔离库一键安装：校验源码包 SHA → CRAN 依赖 → Bioc `xcms` → 源码编译 `cpc` → 冒烟 | `cpc` 不在 CRAN/Bioc，必须记录可复现路径 |
| `.workbuddy/tools/verify_cpc.R`、`verify_cpc_module.R`、`verify_cpc_real.R`（新） | 包 / 适配层 / 真实 .raw 三层验证 | 3.2 的每个数字都由它们产生 |
| `R/peak_quality/export_peak_quality.R` | XLSX 增加 `GroupResults` / `SampleResults` 工作表；`MethodMetrics` 自动生成；provenance 改为按"实际执行了哪些方法"生成；导出列补 `dnn_status` / `dnn_scope` | 任务书第四节 D、第六节 11 |
| `R/peak_quality/plot_compare.R` | 新增 `pq_plot_model_input_image()` + 静态版 | 让"模型到底吃进了什么"可核对，而不是只有诊断图 |
| `R/peak_quality/peak_quality_ui.R` | DNN 页签增加"模型输入图"与"输入检查"两张卡；新增第 9 个页签 **Three methods** | 任务书第五节 |
| `R/peak_quality/peak_quality_server.R` | `group_results_tbl` / `sample_results_tbl` / `three_method_tbl` 与对应输出、下载；DNN 输入图与检查表；导出传 `methods_run`、`paths` 与 `pq_method_metrics()` | 同上 |
| `app.R` | 补 `source("R/peak_quality/result_tables.R")` | 否则界面一触发就"找不到函数" |
| `tests/peak_quality/helpers.R` | 加载新文件 | 同上 |
| `tests/peak_quality/test_09`、`test_11` | 3 条过时断言按新契约重写 | 旧断言锁的是"没有权重"，已不成立 |
| `tests/peak_quality/test_17_three_method_tables.R`（新） | 97 项 | 表格契约、粒度、无总分、导出 |
| `tests/peak_quality/test_18_dnn_input_guard.R`（新） | 50 项 | 方向错误必须失败、无权重不得伪造 |
| `tests/peak_quality/test_01…12`（11 个文件） | 末尾补 `if (!ok) quit(status = 1)` | **这 11 个文件的断言失败原本不会让 `run_all.R` 报错**，见第 7 节 |
| `.workbuddy/tools/build_tbtools_plugin.sh` | 增加权重打包的显式许可闸门 | 任务书第七节 4 |
| `tests/peak_quality/pq_tabs_smoke.js` | 期望页签加入 `Three methods` | 界面冒烟 |

---

## 3. 三个方法各自的真实性

### 3.1 DNN（Kantz et al. 2019）

- **权重**：`DNN_reference/models/edml15.h5`，2,868,928 B，
  SHA-256 `30854950500303208824d5f77d065d7b0b459edeadafecb4b6331edd65fae50a`。
  侧车 `edml15_train_log.json` 记录同一哈希，`pq_dnn_find_model()` 三重校验
  （文件存在 + 日志存在 + 哈希一致）任一不过就判 `model_load_failed`。
- **环境**：TensorFlow 2.21.0 / Keras 3.15.1，Windows 原生 CPU（TF ≥ 2.11 在 Windows 无 GPU）。
  venv 在 `C:/Users/Shenshulin/pqdnn-venv`（短路径避开 260 字符限制），指针文件 `DNN_reference/.venv_path`。
- **结构**：与作者一致——32→pool→16→pool→64→2，`categorical_crossentropy` + `nadam`，
  `save_best_only`、`patience=10`。改动仅 5 处且均为 API 消失/路径写死，逐条列在
  `pq_dnn_train.py` 的 `deviations` 里。
- **输入几何（关键）**：作者 R 流产出 31×200（30 样品 + 1 标记行，200 个 RT 切片）；
  `.mat` 里是 64×64，且**标记在最后一列**（1304/1304 张全如此）。两者是**转置关系**。
  `pq_dnn_to_model_geometry()` 做这件事，并把 `image_native_rows/cols` 与
  `image_resampled=TRUE` 逐组记录。
- **为什么必须加守卫**：第一次接入时按"样品在行"直接做二维缩放，三个干净合成峰拿到
  0.41–0.46（全判不可接受），而模型**没有任何报错**。改成转置式后拿到 0.93–0.97。
  现在 `pq_dnn_validate_input()` 检查 5 项（形状 / 标记轴 / 标记非空 / 值域 [0,1] / 样品区有信号），
  任一项不过就整批拒绝，返回 `input_geometry_invalid` 且**不导出矩阵、不启动 Python**。
- **粒度**：每 feature 一次，`dnn_scope` 在每一行（含失败行）都写 `peak_group`。
- **`dnn_score` 语义**：模型对"可接受峰"类的输出，**未校准**，不等于概率。

### 3.2 CPC（Pirttilä et al. 2022）

- **状态：已安装，并已在本机真实跑出数值。** 隔离库 `C:/rlib/cpc`（`cpc` 0.1.0 +
  `xcms` 4.10.1 / `MSnbase` 2.38.1 / `signal` 1.8.1 / `pander` 0.6.6，R 4.6.0 + Rtools45
  本机源码编译）。项目根 `.Renviron` 写 `DMETFINDER_CPC_LIB=C:/rlib/cpc`，
  `pq_cpc_available()` 返回 `ok=TRUE, version="0.1.0"`。**R 主库（`R-4.6.0/library`）与
  用户库（`~/AppData/.../win-library/4.6`）里没有写入任何包**——隔离库是唯一落点。
- 安装路径（GPL 包，故意不 vendored，因它 `importClassesFrom("xcms")` 硬依赖 xcms）：
  **`cpc` 不在 CRAN、也不在 Bioconductor**（2026-10-21 实测两处索引均无此包），只能从作者
  GitHub `krispir/cpc` 取源码编译。仓库内固定一份源码包
  `.workbuddy/reference/cpc_src.tar.gz`（SHA-256 `2ee9c41b3310…`），一键安装：

  ```bash
  Rscript .workbuddy/tools/install_cpc.R                 # 默认目标库 C:/rlib/cpc
  Rscript .workbuddy/tools/install_cpc.R D:/some/lib      # 换位置
  ```

  脚本先校验源码包哈希（不符即拒绝），再装 CRAN 依赖 → Bioconductor `xcms` → 源码编译 `cpc`，
  最后做一次 `chromFromTrace/processChromatogram` 冒烟。若目标库不在默认位置，把
  `.Renviron` 里的路径改过去即可；也可用 `options(dmetfinder.cpc.lib=)` 临时覆盖。
- 验证脚本两份，日志在 `.workbuddy/reference/`：
  `verify_cpc.R`（只验包本身）、`verify_cpc_module.R`（走 DMetFinder 适配层验数值），
  输出 `cpc_verification.log`。

**实测数字**（合成轨迹，`verify_cpc_module.R`；rt 单位秒）：

| 输入 | CPC 输出 |
|---|---|
| 单峰 h≈1000 σ=1.2 | rt 60.00 [54.40, 64.55]、FWHM 2.83、area 59 960、**sn 5.30**、B/B |
| 肩峰（+500，σ=1.0） | 合成一个峰：FWHM 2.96、area 84 975、sn 5.12、B/B |
| 双峰（59.5 / 61.5） | 只报第一个：rt 59.50、area 1 348、`tcode=V` → `boundary_status=ambiguous` |
| 纯噪声 σ=60 × 30 条 | **30/30 全部 `detected`**（FWHM≈0.12、sn≈1.9），0 条 `not_detected` |
| 3 样品 × 2 特征批量（`pq_run_cpc`） | 5 `ok` + 1 `absent`，单批 0.1 s；首次 `loadNamespace` 8.9 s（拉 xcms） |

由此得到三条**实测结论**，其中第 3 条是审计阶段没能确认的：

1. **`cpc_area` 的量纲缺陷成立且可量化**：同一条形状把采样间隔减半，`cpc_area`
   59 960 → 119 902（比值 **2.000**），而 RT 梯形积分 4 208 → 4 208（比值 1.000）。
   即它确实是"强度×扫描点数"，**不能跨采样率、跨仪器比较**，也不能当峰面积用。
2. **`cpc_sn` 的噪声池缺陷成立**：一条只有基线偏置、几乎无噪声的合成峰，`sn` 只有 5.30，
   **低于作者默认 `min_sn=10`**。若启用作者那个过滤器，这类干净峰会被系统性误杀——
   这比审计阶段"峰越宽 sn 越小"的推断更硬。`min_sn` 只写进参数对象、**从不启用**
   （代码里不调用 `filterPeaks()` / `characterize_xcms_peaklist()`）。
3. **不启用过滤时 CPC 几乎不"拒峰"**：30 条纯噪声 100% 返回 `detected`。所以
   `cpc_*` 列有数值 **不等于** 那里真有峰，CPC 不能当作"有无峰"判据，也不是质量分数。
   它在三方法里的不可替代之处只有一处：**边界语义**（`B/V/S/R` 四码 → `cpc_boundary_status`），
   这是 Kumler（相关系数）和 DNN（分数）都给不出的信息。双峰那行的 `V` 码就是例子。

**真实数据实测**（`verify_cpc_real.R`，`G:/method_ms2/MSDIAL_TEST/P173.raw`，日志
`cpc_real_p173.log`）：在整段 RT 上均匀取 8 个 MS1 扫描、各取该扫描里最强的 m/z 作为特征
（真实存在的离子，不是编的靶标），走完整流程后交给 CPC：

| 样本 | 结果 |
|---|---|
| 8 条真实 XIC（每条 33–67 个扫描点，Δrt≈0.009 min） | **CPC 只对 2 条返回 `ok`**，6 条 `not_detected` |
| 那 2 条 | FWHM 0.059 / 0.175 min，sn 12.0 / 7.5（后者同样低于作者 `min_sn=10`） |
| 检出取决于平滑窗 | 自动窗（11–21 点）→ 2/8；**显式 `smooth_win=7` → 7/8**；`win=5` → 6/8；不平滑 → 4/8 |

根因不是作者算法，是**适配层的自动窗推导**：作者用 XCMS 峰表里的 `sigma` 定窗，我们没有
XCMS 峰表，就按"半高宽 → 窗"自行推导。真实 XIC 的基线是斜的，半高宽的两个交点常常框不住，
于是退到 `n/3`（11–21 点）——这个宽度足以把只有 6–10 个点宽的窄峰抹平，C++ 侧给出
`current_peak = -1`，R 侧记 `not_detected`。

处理方式（**不调参凑结果**）：

- 默认窗推导**保持不变**（改成"让它更容易检出"等于把 not_detected 洗成 ok，属调参）；
- 但把窗的来源写进结果：`pq_cpc_settings()` 新增 `smooth_win_source`
  （`fwhm` / `one_third_fallback` / `user` / `+clamped_to_trace`），随参数表进 provenance；
- `pq_run_cpc()` 每次运行打印一行：`CPC smoothing window: 4 of 8 trace(s) ... fell back
  to one third of the trace ...`，并提示可用 `cpc.smooth_win` 显式覆盖；
- 因此"CPC 大面积 `not_detected`"在日志里是可解释的，而不是看起来像"数据很干净"。

**注意**：7/8 vs 2/8 说明窗选择主导检出率，但这 8 条真实 XIC **没有真值标签**，
所以哪一条是"被窗抹掉的真峰"、哪一条是"本来就是噪声"，**本轮无法判定**。不许把这组数字
读成"CPC 的真实检出率"。

- 调用方式：`cpc::chromFromTrace(st=rt, trace=intensity, param)` +
  `cpc::processChromatogram()`，**不使用 XCMS 对象**，因此可以吃我们自己的 XIC。
- 另外两条仍按原样报告、未"修正"的作者行为：
  - `cpc_area` 按**扫描点下标**积分（`classes.R:1030` 变量名拼写错误 `intergral_x` 导致
    `peak_integral()` 回退到 `x = 1:ny`）；
  - `cpc_sn` 的噪声池取自"最不弯曲的 95% 轨迹"，宽峰仍会混进峰体。
- **诚实标注**：真实 .raw 上验证的是"**能算、能跑、失败可解释**"，不是"科学有效"。
  要判定 CPC 在真实数据上的优劣，仍需要带人工标注的峰组——与 DNN 的 E2 卡在同一个前提上。

#### 3.2.1 首次真实全量运行（2026-10-21）

数据 `G:/method_ms2/MSDIAL_TEST`，20 个 `.raw`，峰表 8 行 → 展开为 **160 行**，
整轮 1041.9 s（解析占 82%，每文件约 50 s / 2073–2080 张 MS1；CPC 1.3 s，DNN 24 s）。

| 指标 | 结果 | 占比 |
|---|---|---|
| `cpc_status = ok` | 127 | 79.4% |
| `not_detected` | 32 | 20.0% |
| `absent`（Kumler 层判定无峰，CPC 不跑） | 1 | 0.6% |
| `invalid_input` / `error` | 0 | — |

- **平滑窗没有退化成 `n/3`**：159 条轨迹**全部**由峰宽推出（`fwhm=159`），零回退。
  此前 `verify_cpc_real.R` 在 P173 上 8 条里 6 条回退，是**那个探针脚本**的 XIC 窗口设置
  造成，不代表流水线行为——两者不可互相代表，这里更正。
- **修掉一处日志缺陷**：`pq_run_cpc()` 原先把所有非 `ok` 一律计为 `failed`，
  于是同一轮日志里出现 `failed=32` 而下一行汇总写 `failed=0`。现改为按
  `pq_cpc_status_family()` 分族计数（`ok / not_detected / absent / invalid_or_error /
  not_run`）。`not_detected` 是**有效答案**，不是崩溃，必须在日志里分开。
- 这 32 条 `not_detected` 里有多少是**假阴性**仍然未知——缺真值标签，本轮依旧不能判定。

### 3.3 Kumler（Kumler et al. 2023）

- `R/peak_quality/vendor/squallms_qscore.R` 逐字 vendored（commit `2f4038ce…`，MIT），
  适配器 `score_adapter.R` 只做整形：排序、去重（同 RT 取最大强度，**不求和不造信号**）、
  少于 5 点直接 `skipped`（作者自己的 `length(rt) < 5` 守卫）。
- `peak_cor` 是相关系数，**不是概率**；`SNR` 是作者自定义口径（`2*height/N` 系），
  与 CPC 的 `sn` **不可比**。
- 复现性由 `tests/peak_quality/fixtures/qscore_oracle.csv` + `test_05_scoring.R` 锁定。
- 平滑：默认 `none`。开启后每行记录 `xic_smoothing` 标签，并明确"这不是作者原始输出"。

---

## 4. 统一数据流程（任务书第三节）

| 步骤 | 实现 | 位置 |
|---|---|---|
| 1 读峰表 | `pq_read_table()` / `pq_standardize_features()` | `peak_table.R` |
| 2 字段映射 | `pq_guess_mapping()`，未映射字段进 `bad` 表而非丢弃 | `peak_table.R` |
| 3 样品名→原始文件 | `pq_match_samples()`，`exact`/`ambiguous`/`unmatched` 三态 | `peak_table.R` |
| 4 仅 MS1 | `pq_load_ms_file(ms_level = 1)` + `pq_ms1_index()` | `xic_extract.R` |
| 5 原始 XIC 与可选分析轨迹**分存** | `xic` 与 `xic_analysis` 两个对象，`detail` 里并列保存 | `pipeline.R` |
| 6 每 feature 建峰组 | `pq_dnn_batch()`（按 feature_id 分组） | `pq_dnn_data.R` |
| 7 DNN 每组一次 | `pq_dnn_apply()` → `pq_dnn_run_predict()` | `pq_dnn_integration.R` |
| 8 CPC 每样品一次 | `pq_run_cpc()` / `pq_cpc_score()` | `compare_methods.R` / `cpc_adapter.R` |
| 9 Kumler 每样品一次 | `pq_score_xic()` | `score_adapter.R` |
| 10 合并但保留各自状态/范围 | `pq_group_results()`、`pq_sample_results()`、`pq_method_metrics()` | `result_tables.R` |

硬约束的落实方式：

- **粒度**：`dnn_scope` 恒 `peak_group`，`pq_method_scope()` 恒返回 `single_sample`（CPC/Kumler）。
  长表里 DNN 行的 `sample_id` 是空串，**不借用某个样品的 id**。
- **缺失 ≠ 噪声**：`presence` 的 `present / absent / unknown` 三态贯穿到 `presence_status`；
  `absent` 行的 `kumler_status`/`cpc_status` 也是 `absent`，指标留 NA，绝不写 0。
- **MS2 precursor 不参与**：`pq_load_ms_file(ms_level = 1)` 只取 MS1。
- **对齐表平均 RT ≠ 每样品峰顶**：`rt_reference` 与 `sample_rt_apex` 分列，`rt_reference_source`
  记录是 `aligned_table` 还是 `per_sample_median`。

---

## 5. 三张表与导出

### GroupResults（每 feature 一行）

`feature_id, mz, rt_reference, rt_reference_source, n_samples, n_present, n_absent,
n_unknown, dnn_status, dnn_scope, dnn_model_version, dnn_input_status, dnn_prediction,
dnn_score, dnn_threshold, dnn_applicability, dnn_error`

`n_present + n_absent + n_unknown == n_samples` 由 test_17 断言。

### SampleResults（每 feature×sample 一行）

任务书要求的字段全部在内（`raw_file`、`sample_rt_apex`、`presence_status`、
`kumler_peak_cor`、`kumler_snr`、`kumler_status`、`cpc_rt/rtmin/rtmax/fwhm/wb/a/b/tf/
height/area/sn`、`cpc_status`、`xic_smoothing`、`ppm_tolerance`、`rt_window`、
`method_errors`），另加 `mz_tolerance`（原始字符串，因 "5 Da" 与 "5 ppm" 不可换算）、
`cpc_reason`、`cpc_boundary_status`、`cpc_status_family`（四词表）、
`dnn_scope` / `dnn_score` / `dnn_status`。

### MethodMetrics（长表）

`feature_id, sample_id, method, metric, label, unit, value, note, status, scope, model_version`。
`cpc.area` 的 unit 明确写 `intensity x scan count`；DNN 两行 `dnn_score` / `dnn_prediction`
的 `scope = peak_group`、`sample_id = ""`。

### Provenance

`pq_provenance_block()` 输出：引擎与导出时间、R 版本与平台、
**逐方法 executed=yes/no 与 unavailable 原因**、每个方法的论文/DOI/仓库/commit/许可证/本地改动、
DNN 权重路径与 SHA-256/训练时间/种子/TF 版本/测试 AUC/阈值语义、
CPC 版本与库路径（或未安装）、Python 路径、参数表（含 CPC 平滑参数）。

XLSX / ZIP / CSV 三条导出路径都带这些内容（test_17 逐项断言）。

---

## 6. 界面

Peak Quality 现有 9 个页签：Results / Peak view / Compare methods / By software /
Peak group / DNN / **Three methods** / Inputs & mapping / Parameters & provenance。

- **DNN 页签**：模型状态（含 SHA、训练时间、测试 AUC）、"分数不是概率"说明、
  逐 feature 预测表、**模型输入热图**（行=RT 切片、列=样品、末列=窗口标记）、
  **输入检查表**（每 feature 的 5 项检查结果与失败原因）。页面上**没有训练按钮**。
- **Three methods 页签**：说明卡（三种问题、两种粒度、不做总分）、
  GroupResults 表、SampleResults 表、逐 feature 并列摘要（Kumler 中位 `peak_cor` +
  有效样本数、CPC 中位 FWHM + 有效样本数、DNN 分数与类别）。所有列前缀归属于单一方法，
  没有一列由两个方法合成。
- CPC / Kumler 的**单峰视图**仍在 "Peak view"（`pq_plot_peak_base(..., cpc_row=)` 同时画
  峰顶与左右边界、CPC 边界色带、可选 beta 拟合与残差）。CPC 未安装时该页显示状态而非空图。

### 6.1 已修：跑完 DNN 后结果页整页报错

**症状**（2026-10-21 深夜，第一次真实全量运行后）：

```
Warning: Error in if: missing value where TRUE/FALSE needed     # 质量卡片
Warning: Error in [: incorrect number of dimensions              # Peak quality 表格
```

**只在勾选 DNN 并成功评分后出现**，且与数据无关（全量 160 行、合成 8×20、逐值注入都试过，
纯函数层面全部正常）。

**根因**：`results()` 的形状被一个分支改坏了。正常运行把它设为
`pq_process_features()` 返回的 **list(rows, detail)**，全文件 30 处按 `det$rows` 读；
DNN 成功那一支写的却是 `results(dr$rows)`——**裸 data.frame**。于是 `det$rows` 变成
`NULL`，而 `pq_classify_rows(NULL, cpc)` 在 0 行分支里 `out <- rows`（NULL）再逐列赋值，
把一个 **长度 8 的 list**（既不是表也不是 NULL）返回给界面：

- `nrow(list)` 不是 0 → `if (is.null(rows) || nrow(rows) == 0)` 抛第一条；
- `list[i, , drop = FALSE]` 抛第二条。

**修法**（三条都在代码里，不只打补丁）：

1. DNN 成功后改为 `det$rows <- dr$rows; results(det)`，保住 list 形状；
2. `pq_classify_rows()` 遇到 NULL **直接返回 NULL**，不再产出 list；
3. `display_rows()` / `quality_cards` / `status_cards` 加 `is.data.frame` 守卫，
   形状不对时写日志并显示"无结果"，不再红屏。

**为什么以前没抓到**：界面冒烟只有 2 个 fixture，DNN 被几何守卫拒了
（`the peak-group image is not a matrix (F_LATE)`，`dr$ok = FALSE`），
根本没走到那一行；而冒烟当时只断言日志里有 `Done in`，**没有断言表格真的渲染出来**。
现补 3 条（表必须有行、Results 页不得有 `.shiny-output-error`、DNN 分支必须被走到），
共 33 条；单元层新增 6 条锁返回类型（`test_13`）与 2 条**静态检查**
"`results()` 不得被赋裸表"（`test_17`）。

---

## 7. 测试

`Rscript --vanilla tests/peak_quality/run_all.R` → **18/18 文件通过，907 项断言全过，
0 failed / 0 skipped**（2026-10-22 01:47，修完「DNN 后结果页报错」的复跑；
本轮 `test_09` 52→60（锁日志文案）、`test_13` 63→69（锁返回类型）、
`test_17` 97→99（静态检查 `results()` 不被赋裸表））。

```
test_01 63  test_02 37  test_03 29  test_04 34  test_05 37  test_06 13
test_07 51  test_08 53  test_09 60  test_10 42  test_11 44  test_12 78
test_13 69  test_14 17  test_15 74  test_16 56  test_17 99  test_18 51
```

浏览器冒烟 `tests/peak_quality/ui_smoke_methods.js`：**33/33 通过**，应用日志
**0 个 `Warning: Error`**。

新增 147 项：

- `test_17`（97）——GroupResults 一 feature 一行、SampleResults 一 feature×sample 一行、
  三态 presence 不合并、absent 不降级为失败、`ppm` 与 `Da` 不混用、平滑标签逐行记录、
  DNN 只有一个值重复到组内各行、**无 total/combined/rank/weighted 列**、
  DNN 不改 `quality_class`、导出含三表与 provenance、论文基准仍在容差内。
- `test_18`（50）——64×64 模型布局通过；**转置被判 `orientation_error`**；31×200 被判
  `shape_mismatch`；值域越界、空图、标记全零分别被拒；`pq_dnn_apply()` 在守卫失败时
  **不导出、不预测、不给任何分数**；无权重时 `model_not_trained` 且不伪造类别。

浏览器冒烟：`pq_tabs_smoke.js`，9 个页签全部渲染，0 个页面错误（`28→` 见运行日志
`.workbuddy/tests/pq_shots3/`）。

### 顺带修掉的测试完整性缺陷（重要）

`test_01`–`test_12` 这 11 个文件原本**没有失败退出码**：它们末尾只调 `pq_summary()`，
返回 `FALSE` 也不会让进程非零退出，`run_all.R` 因此把这些文件的失败全部报成 `OK`。
本次第一次全量运行时 `test_11` 就是"status OK / 3 failed"——那 3 条正是依赖
"永远没有权重"的过时断言。现在 18 个文件统一 `if (!ok) quit(status = 1)`，
失败会真正让 run_all 变红。

---

## 8. 许可证（任务书第七节）

| 对象 | 许可 | 结论 |
|---|---|---|
| 数据集 `EDML_trainTestCalData15.mat`（MassIVE MSV000084186） | **CC0 1.0** | 数据可自由使用 |
| 作者代码（JainLab 仓库，commit `94237bf`） | **University of California，仅研究/教育/非营利**；商业用途需书面许可 | 不能默认随插件分发 |
| 本仓库训练出的权重 | 作者代码的衍生作品 | 按**较严**一侧处理：研究/非营利 |
| Kumler 源码 | **MIT** | 可分发（已 vendored，附 `LICENSE.squallms`） |
| CPC | **GPL (>= 2)** | 外接调用，不 vendored；不改变本项目许可 |

**CC0 数据集 ≠ 权重可自由再分发**，这一点已写进 `MODEL_CARD.md` 与导出 provenance。

构建脚本 `build_tbtools_plugin.sh` 现在是**显式闸门**而不是默认行为：

- 默认：不复制 `DNN_reference/`，打印原因，插件内 DNN 显示 `model_not_available`
  并提示如何本地配置；若插件里存在旧拷贝会**主动删除**并说明。
- `DMETFINDER_PACKAGE_DNN_WEIGHTS=1`：先打印许可条款与"责任在你"，再复制
  `models/`、`source_code/`、`MODEL_CARD.md`，并写入 `PACKAGING_NOTICE.txt`。

---

## 9. 科学局限（不得写成"科学有效性已验证"）

1. **分数随样品数单调升高**：同一干净峰 3 样 0.902 → 6 样 0.978 → 12 样 0.997 →
   20 样 0.9997 → 30 样 1.000。作者训练图固定 63 个样品列，少样品时列被补零，
   模型读作"很多样品没有信号"。**不同样品数的队列之间分数不可比。**
   这条已在真实数据上得到验证：2026-10-21 那次 20 样 / 8 峰组 / 160 行的运行，
   **160 行全部高于 0.5，一个都没有被拦下**。而且 DNN 是峰组级，160 行其实只对应
   **8 个不同的分数**——"0 at or below the threshold" 不是"这 160 个峰都好"，
   而是**阈值在这个队列上分不开任何东西**。服务端日志已改成同时打印
   `min / median / max / range`，`range < 0.10` 时直接 WARNING 说明该列不可当筛子用。
2. **绝对丰度不是输入变量**：每张图按自身最大值归一化（实测 2770 张极大值都恰好 1.0），
   所以"低丰度真峰误判率"在这个模型上**无定义**，不能报这个指标。
3. **双峰/肩峰仍被接受**：实测双峰 0.91–0.9999、肩峰 0.98 均通过，与论文自述失效形态一致。
4. **未校准**：`dnn_score` 不是概率；作者三个阈值（0.5 / 0.4 / ROC topleft）并存，
   本实现默认 0.5 且**可调**，每个导出都写实际用的阈值。
5. **输入是近似**：31×200 → 64×64 的转换在公开材料里**没有作者代码**，
   逐行标 `dnn_applicability = approximate_resampled_input`。
6. **E2 外部验证做不全**：作者引用的 `EDML_Test15.mat` / `EDML_RestSetTest15.mat`
   在公开数据里不存在；真正的外部验证需要**带人工标注的 DMetFinder 峰组**，目前没有。
7. **CPC 只做到"能跑、失败可解释"，没做到"在真实数据上验证"**：包已装，合成轨迹、
   真实 `P173.raw`、以及 20 个真实 `.raw` 的全量运行都跑过。实测确认了三条：`area` 是
   强度×扫描点数（采样间隔减半 → area ×2.000，RT 积分不变）；干净合成峰的 `sn` 只有
   5.30（< 作者默认 10）；**不启用过滤时纯噪声 30/30 都被判 `detected`**。
   全量运行（160 行）里 `ok=127 / not_detected=32 / absent=1`，平滑窗 159/159 均由峰宽推出、
   零回退（详见 3.2.1；此前 8 条探针里 6 条回退是探针脚本自身的窗口设置，不代表流水线）。
   结论：`cpc_*` 数值不能当"有无峰"或"质量好坏"的判据，只能当**边界语义与形状描述**用；
   那 32 条 `not_detected` 里哪条是假阴性仍不可判定——没有标签。
8. **没有批次/仪器漂移检测**：分布偏离作者数据时模型不报警，只给分数。

---

## 10. 剩余问题与待确认

1. **CPC 安装决策**：已按用户指示完成（隔离库 `C:/rlib/cpc`，`.Renviron` 已接线，
   见 3.2）。剩下的不是安装问题，而是**真值问题**：要复核 `cpc_area` / `cpc_sn` 在真实
   .mzML 上的表现，需要一条带人工标注的真实峰组——与第 3 条的标签缺口是同一个。
2. **插件是否打包权重**：许可决策，需用户明示。当前默认不打包；本轮按用户要求**未动**
   TBtools 插件相关内容。
3. **31×200 原生几何上重训**：需要带标注峰组；这是消除局限 1、3、5 的唯一正路。
4. **提交与推送**：本次**未提交、未推送**。改动清单见第 2 节。
5. **`data_for_paper/`（162 MB）** 仍在工作树未跟踪状态，与本次改动无关。

# Peak Quality Assessment — 算法兼容性审查报告（阶段一）

**日期**：2026-10-19
**范围**：Kumler et al. 2023（`MS_metrics` / `squallms`）、Pirttilä et al. 2022（CPC）、Kantz et al. 2019（DNN）
**状态**：本阶段**只做审查与可行性验证，未改动任何集成代码**。现有 Kumler 实现、Ms1Geter / Ms2Geter / DMetFinder 均未受影响。

> 审查用的源码副本与探针脚本放在 `.workbuddy/reference/`（不纳入 git），
> 实测日志见 `.workbuddy/reference/cpc_build.log`、`probe_cpc_*.R`。

---

## 1. 三方法技术对照表

| 审查项 | **Kumler 2023**（已集成） | **CPC / Pirttilä 2022** | **DNN / Kantz 2019** |
|---|---|---|---|
| 原始输入格式 | 任意 `(rt, int)` 向量 | `XCMSnExp` 对象；**另有官方的非 XCMS 入口** `chromFromTrace(st, trace, param)` | MZmine 2 对齐峰表 + `.mzXML`；Python 路径要 `.mat` |
| 依赖 XCMS 对象 | 否 | **是（包层面强依赖）**；数据路径可绕开 | 否 |
| 需要完整原始文件 | 否，只要 XIC | 包层面 `mzR` 直读；走 `chromFromTrace` 时不需要 | **是**，需逐文件 MS1 全表 |
| 可否评估单条 XIC | **可以** | **可以**（`chromFromTrace`，已实测跑通） | **不可以**，必须跨样本峰组 |
| 需要多样本对齐峰组 | 否 | 否 | **是**，且是该方法的立论基础 |
| 依赖人工标注训练集 | 否（无监督） | 否（规则+阈值） | **是**，作者用 `peakReviewApp` 标注了 1304+740+726 例 |
| 输出指标 | `peak_cor`、`SNR` | `rt/rtmin/rtmax/fwhm/wb/area/height/a/b/tf/sn` + 边界代码 `B/V/S/R` | 单值 `predProb` ∈ [0,1]（**有概率**） |
| 运行时依赖 | 纯 R，无外部依赖 | R + **C++11 编译**；`xcms`、`MSnbase`、`signal`、`pander`、`Rcpp` | `keras`（→ Python + TensorFlow）、`lcmsMetab`、`data.table`、`pROC`、`abind` |
| 版本 / 模型文件 | squallms 0.99.7（单函数 vendored） | cpc **0.1.0**；**无预训练模型**（无监督） | **无模型权重**，只有训练脚本 |
| 许可证 | **MIT**（squallms） | **GPL (≥2)**（写在 DESCRIPTION，仓库无 LICENSE 文件） | **加州大学版权：仅教育/科研/非营利，商用需向 UCSD 申请授权** |
| 与当前读取层兼容度 | **高**：直接吃我们已有的 XIC | **中高**：我们已有 `rt/int` 向量，喂 `chromFromTrace` 即可（已实测） | **低**：需 mzXML + 跨样本峰组 + Python 环境 + 自训练模型 |

### 1.1 许可证差异是硬约束

三种许可互不相同，其中 DNN 的条款**明确禁止未经授权的商业使用**。若 DMetFinder 未来有商业化可能，DNN 模块必须以可选、可卸载、明确提示的形式存在，且不得随主发行版分发其代码。CPC 为 GPL-2+，与项目现有代码的兼容性需确认（会导致派生作品整体 GPL 化）。

---

## 2. CPC：可行，但有两个必须记录的实现缺陷

### 2.1 安装可行性（已实测）

| 步骤 | 结果 |
|---|---|
| `BiocManager::install("xcms")` | **成功**，xcms 4.10.1，全部 Windows 二进制，**2.4 分钟**，无需编译 |
| `signal` / `pander` | 成功（CRAN 二进制） |
| `cpc`（GitHub master 编译） | **成功**，`* DONE (cpc)`，`loadNamespace` = OK，版本 0.1.0 |
| 编译工具链 | Rtools45 已就绪（`has_build_tools() = TRUE`） |
| 隔离库 | `.workbuddy/reference/rlib`（23 个包），**未触碰用户主库** |

注意：`remotes::install_github()` 在本机因 GitHub tarball API 超时而失败，改用
`codeload.github.com/.../tar.gz` 下载后 `install.packages(type="source")` 即可。
这是网络问题，不是代码问题。

### 2.2 非 XCMS 数据路径（关键结论）

`cpc` 在 NAMESPACE 层面 `importClassesFrom("xcms")`，**因此安装与加载都必须有 xcms**。
但源码中存在专门为外部色谱图设计的入口：

```r
chromFromTrace <- function(st, trace, param = cpcChromParam())
# 文档原文: "for external processing of chromatograms without XCMS"
ch <- processChromatogram(chromFromTrace(st = rt, trace = y, param = prm))
res <- ch@results     # 注意: getResults() 是 S4 泛型, 直接读 slot 更稳
```

**实测（合成高斯峰，真值 apex=4.5 min、sigma=0.06、amp=2e5、噪声 sd=1500，n=121）**：

| 指标 | CPC 输出 | 真值/理论 | 判定 |
|---|---|---|---|
| `rt` | 4.5000 | 4.5000 | 准确 |
| `rtmin` / `rtmax` | 4.2917 / 4.7083 | ±2.9σ | 合理 |
| `height` | 198 399 | 200 000 | −0.8% |
| `fwhm` | 0.1435 | 0.1413 | +1.6% |
| `tf` | 1.0031 | 1.0（对称峰） | 准确 |
| `a` / `b` | 0.1291 / 0.1295 | 近似相等 | 准确 |
| **`area`** | **3 605 868** | 30 080 | **见 2.3，量纲不对** |
| **`sn`** | **13.39** | 理论约 100+ | **见 2.4，峰宽依赖** |

结论：**边界识别、峰高、FWHM、拖尾因子可信；area 与 sn 有实现缺陷。**

### 2.3 缺陷一：`area` 按下标积分，不乘 ΔRT

`R/classes.R` 第 1030 行把后边界的插值追加到了 **`intergral_x`**（少一个 `t`），
新建的局部变量，真正的 `integral_x` 没有变长。于是 `length(x) != length(y)`，
触发 `peak_integral()` 的兜底：

```r
if (nx != ny) x = 1:ny      # 自变量被换成扫描下标
```

实测对照：

| 计算方式 | 结果 | 与 CPC 比值 |
|---|---|---|
| CPC `area` | 3 605 868 | 1 |
| 按**扫描下标**梯形积分 | 3 609 912 | **0.9989** ← 就是这个 |
| 按 **RT（分钟）**梯形积分 | 30 083 | 119.87 |
| 理论面积 `amp·σ·√(2π)` | 30 080 | — |

**采样密度翻倍（n=121 → 241），`area` 精确翻倍（比值 2.000）。**

影响：`area` 的量纲是"强度 × 扫描点数"，**跨不同扫描速率的数据不可比**。
在我们这种一次跑 20 个 raw 的场景里，若扫描速率不一致，`area` 排序会失真。

### 2.4 缺陷二：`sn` 的噪声池被峰自身污染

CPC 的 S/N 定义为 **2h/N**（欧洲药典 2019），代码中 N 来自：

```r
noise_sel <- which(abs(d2) <= quantile(abs(d2), .95))   # 只排除 5%
xic_noise <- c_peak_to_peak_noise(noise_sel - 1, x@xic, w = 1)
sn        <- 2 * height / xic_noise
```

论文写的是 "all **non-peak** scans"，但实现只排除了二阶导绝对值最大的 5%。
峰占窗口比例稍大时，峰内点大量留在"噪声池"里，N 被峰自身的斜率撑大。

实测（**真实噪声完全不变**，sd 恒为 1500，仅改峰宽）：

| sigma (min) | S/N | 噪声池点数 | 峰区留在池中比例 | 反推 N |
|---|---|---|---|---|
| 0.010 | 64.24 | 115 | 20% | 3 280 |
| 0.020 | 38.86 | 115 | 44% | 8 461 |
| 0.040 | 20.31 | 115 | 68% | 19 147 |
| 0.060 | 13.39 | 115 | 79% | 29 631 |
| 0.100 | 8.08 | 115 | 87% | 49 378 |
| 0.150 | 6.50 | 115 | 92% | 61 147 |

**N 被高估 19 倍，S/N 被压低 10 倍，而噪声从未变化。**
后果：CPC 默认 `min_sn = 10` 过滤时，宽峰会系统性误杀、窄峰会被放行；`sn` 不可跨峰宽比较。

---

## 3. DNN：当前无法"复用作者模型"，只能自训练

### 3.1 阻断点

| 阻断点 | 证据 |
|---|---|
| **无预训练权重** | 仓库 19 个文件，**无任何 `.h5/.hdf5/.pkl/.rds/.onnx`**；`ApplyPeakPredictionModel.R:18` 是 `modelFile <- "modelFileName.h5"` **占位符** |
| **必须自建标注集** | `WorkFlow.md` 要求先用 `peakReviewApp.R` GUI 人工逐图标注 Good/Bad/Borderline，再训练 |
| **训练数据在外部** | README 指向 MassIVE `doi:10.25345/C5FD2F`，Python 脚本读 `EDML_trainTestCalData15.mat` |
| **需要 Python** | R 侧 `library(keras)` 本身就走 reticulate → TensorFlow；本机 `keras/tensorflow/reticulate` **均未安装** |
| **许可证限制** | UC Regents，非营利/教育可用，商用需授权 |
| **次级依赖无许可** | `lcmsMetab` 仓库**无 LICENSE**、2019-07 后停更 |

### 3.2 输入契约（已从源码逐行确认）

论文与 R 脚本**不是同一套默认参数**，这点极易误判：

| | 论文（Anal. Chem. 2019） | R 脚本**默认值** | Python `EDML_deep_learning2.py` |
|---|---|---|---|
| 图像尺寸 | **64 × 64** | `c(31, imageWidth)` | `input_shape = (64, 64, 1)` |
| 行含义 | 行 1–63 = 63 个样本，**行 64 = 窗口掩码** | `maxSignalFiles = 30` + 1 行掩码 = **31** | 64 |
| 列/切片 | 每列一个 RT 分箱（未给宽度） | `numRtSlices = floor(RtDur/minRtSep) = 1/0.005 = 200` | 64 |
| 输出层 | — | 1 单元 + **sigmoid**，binary crossentropy，epochs 40, batch 512 | **softmax 2 类**，categorical crossentropy，epochs 500, batch 128, nadam |
| NaN 处理 | — | 0→NA 存储 | **NaN 填 −2** |

**因此 R 脚本要复现论文必须显式改参数**：`maxSignalFiles = 63`、
`RtDur/minRtSep = 64`。用默认值跑出来的不是论文那个模型。

构造流程（`peakGroupImageMatrixAndPlot.R`）：

1. 每个峰组取窗口内**有信号**的文件（`intensity > 0`），**信号为 0 的文件被直接剔除，不是补 0**
2. 每文件按 `approx(method="linear", rule=2, ties=mean)` 插值到等间隔 RT 切片（`rule=2` 会把边界值外推成平台）
3. 不足 `maxSignalFiles` 行**补 0**
4. **除以整个矩阵的最大值**归一化（全局 max，非逐行）
5. 追加一行二值窗口掩码
6. 模型若接收 >30 个文件，按强度取 top-N + 随机抽样

### 3.3 作者自报性能（**不可外推到我们的数据**）

Cohort 1（N=78，人血浆 HILIC）：训练 1304 例（652 真 / 652 假）、校准 740、测试 726（47:27:26）。
训练 AUC **0.992**、测试 AUC **0.988**；最优阈值 0.4725 → TPR 0.945 / FPR 0.04。
独立 Cohort 2（N=526）3000 个峰组：保留 **88%** 真峰、消除 **89%** 假峰。

作者原文明确：换仪器/方法 **必须重新生成训练集并重新调参**，不能直接迁移。
因此**在油菜/植物代谢组数据上引入该模型，必须先有本项目自己的独立标注集**，
否则任何"准确率"声明都不成立。

---

## 4. 与当前 DMetFinder 读取层的兼容性

| 需求 | 现状 | 结论 |
|---|---|---|
| `.raw` | `read_ms_file()`（rawrr）已验证，`P173.raw` 57 MB / 54 s | 满足 |
| `.mzML` / `.mzXML` | `read_ms_file()`（mzR）已验证 | 满足 |
| 单条 XIC | `pq_extract_xic()` 输出 `xic$rt` + `xic$intensity` | Kunler、CPC 都可直接吃 |
| 跨样本峰组 | **无** | DNN 需要新建聚合层 |
| Python 运行时 | **无**（reticulate/keras/tensorflow 均未装） | DNN 需要隔离子进程或独立服务 |

**Kumler 与 CPC 的数据需求完全一致**（都是 `rt` + `int`），可以共用同一份
`pq_extract_xic()` 结果——这是"Compare Methods"能做到"同一批候选峰上运行多方法"的基础。
DNN 则完全不同：它不评单峰，评的是"跨样本峰组图像"。

---

## 5. 分阶段计划（按任务书第五节，逐阶段验收）

| 阶段 | 内容 | 前置条件 | 风险 |
|---|---|---|---|
| **一（本报告）** | 源码/依赖/输入兼容性审查 | — | 已完成 |
| **二** | CPC 适配层 + 统一结果结构（Kumler + CPC 并跑） | **需先决定 2.3 / 2.4 两个缺陷的处理方式** | 见下方问题 |
| **三** | 跨样本峰组准备 + DNN 推理 | **需先有 Python 环境与训练数据**，否则只能做"图像构造 + 可视化"，不能出概率 | 高 |
| **四** | 统一结果表、多方法比较、人工复核 | 二、三完成 | 中 |
| **五** | 回归测试与性能评估 | 全部完成 | 低 |

### 5.1 决策点（**已由用户确认**，2026-10-19）

**Q1 — CPC 的 `area` 缺陷怎么处理？**
- **A（推荐）原样使用 + 显式标注**：结果列写 `area_cpc_index_units`，注释说明量纲为"强度×扫描点数"，不跨扫描速率比较。完全符合"不修改作者算法"。代价是 `area` 实用性受限。
- **B 原样计算 + 旁列给出 RT 校正面积**：保留作者的 `area`，同时用 `fwhm`/`rtmin`/`rtmax` 在我们侧算一个 `area_rt`（乘 ΔRT），明确标注它是本项目的派生量、非作者输出。
- **C 修改 vendored 代码修正拼写**：**不建议**，会破坏"作者原始算法"的可追溯性。

> **决定：A。** 结果列名 `cpc_area`，指标字典 `unit = "intensity x scan count"`，
> UI/导出/报告统一注明"不跨扫描速率比较"。**不**新增 `area_rt` 派生列。

**Q2 — CPC 的 `sn` 缺陷怎么处理？**
- 它的默认过滤阈值 `min_sn = 10` 会在宽峰上系统性误杀。可选：
  - **A（推荐）只输出 `sn`，不启用 CPC 的 `min_sn` 过滤**，由用户在结果表里自行判断；
  - **B 提高噪声池纯度**（把 `quantile` 的 0.95 调低，例如 0.5）——但这是改作者参数语义，需在 UI 明示为"本项目变体"；
  - **C 照搬 `min_sn = 10`**——会在我们的数据上误杀宽峰，不建议。

> **决定：A。** 只输出 `cpc_sn`。`min_sn` 仍写入 CPC 参数对象（作者默认 10，
> 用于追溯），但 `filterPeaks()` / `characterize_xcms_peaklist()` **从不调用**，
> 因此没有任何峰因为 `sn` 被移除。设置中记录 `filters_applied = FALSE`。

**Q3 — DNN 这一阶段做到哪？**
- **A（推荐）先做"峰组图像构造 + 可视化 + 缺失情况诊断"**，不出概率、不训练。这样 UI 能展示跨样本峰组，为将来接入模型留好接口，且不虚构任何分类结果。
- **B 同时搭 Python 子进程骨架**（空模型占位），验证环境隔离方案。
- **C 直接开始自建标注集与训练**——工作量最大，且需要你提供可信的标注与数据划分。

> **决定：A。** 只做图像构造 + 可视化 + 缺失诊断。`quality_probability` 对 DNN
> 保持缺失；`pq_method_available("dnn")` 永远返回不可用并给出原因。

---

## 6. 本阶段明确**没有**做的事

- 没有修改任何现有代码（`git status` 与上一轮一致）
- 没有把 CPC 或 DNN 的算法搬进 `R/peak_quality/`
- 没有宣称任何分类准确率
- 没有把作者的默认参数当作论文配置
- 没有使用 CPC 的 `min_sn` 过滤（尚未接入）

---

## 7. 第二阶段实现记录（2026-10-19 追加）

> 详细交付见 `PEAK_QUALITY_METHODS_REPORT.md`。此处只记录与审查结论的对应关系。

| 审查发现 | 落地方式 |
|---|---|
| CPC 必须加载 xcms，但有不依赖 XCMS 的入口 | 用 `cpc::chromFromTrace()` + `cpc::processChromatogram()`，**不构造 XCMSnExp 对象** |
| CPC 是 GPL (≥2) | **不 vendored**，作为外部可选包调用；`DMETFINDER_CPC_LIB` / `options(dmetfinder.cpc.lib=)` 指向隔离库 |
| `area` 用扫描下标积分 | 原样输出 `cpc_area`，单位标注 `intensity x scan count`，测试用"RT 梯形积分不变、CPC area 随采样率增长"验证该缺陷被复现 |
| `sn` 噪声池被峰污染 | 原样输出 `cpc_sn`，**不启用** `min_sn` 过滤；测试用一个 `sn=8.0 < min_sn=10` 的峰证明它仍被返回 |
| DNN 无权重 | 只做图像构造/可视化/缺失诊断；`quality_probability` 恒为缺失 |
| 论文 64×64 vs 脚本 31×200 | 在 `PQ_DNN_IMAGE_SPEC` 中并列记录，图像实际尺寸写入每一张图与诊断表 |

实现期新发现（补充到 2.2 节）：

- `cpcChromParam()` 若不显式传 `min_w` / `max_w`，S4 槽位会是 `NULL`，
  `processChromatogram()` 随即在 `if (getParam(...,"smooth_win") < getParam(...,"min_w"))`
  处报 `argument is of length zero`。适配层因此**始终显式传入** `min_w = 5`、`max_w = 21`
  （作者类原型值），并在测试中固定这一行为。
- 平滑窗口不能简单取 `n/3`：那会在窄峰上过度平滑（实测 FWHM +9%）。
  改为按作者本意 `w ≈ 2.354σ`，σ 由**轨迹自身的 FWHM/2.355** 估计，
  于是 `w ≈ 峰在扫描点上的 FWHM`，仍钳制在作者 `[5, 21]` 区间内。


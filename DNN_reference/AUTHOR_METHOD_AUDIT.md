# 作者方法审计 — Kantz et al. (2019) LC-MS Peak DNN

> 本文件记录**从作者代码与数据中逐行确认**的事实，每条都指向具体文件与函数。
> 凡未实测的部分一律标注「未验证」，不做推断性描述。
>
> 审计时间：2026-10-21
> 审计对象：`DNN_reference/source_code/repo`（GitHub，commit `94237bf45e790a8332e45a2f2842116f46a18aa9`）
> 以及 `DNN_reference/source_data/`（MassIVE MSV000084186 下载）

---

## 0. 一句话结论

作者**没有发布可直接推理的预训练权重**。仓库里 `ApplyPeakPredictionModel.R:18`
的 `modelFile <- "modelFileName.h5"` 是占位符，不是文件名。要得到 `.h5` 只能按
`EDML_deep_learning2.py` 用配套数据从头训练。作者公开的是**训练代码 + 训练数据**，
不是模型成品。

---

## 1. 资源清单与来源

| 资源 | 来源 | 状态 |
|---|---|---|
| 代码 | `https://github.com/JainLab/Manuscript-DNNs-for-Classification-of-LCMS-Peaks` | 已克隆，commit `94237bf` |
| 数据 | `https://massive.ucsd.edu/ProteoSAFe/dataset.jsp?accession=MSV000084186`（DOI 10.25345/C5FD2F） | 已下载核心文件，清单见 `DATA_MANIFEST.csv` |
| 论文 | DOI `10.1021/acs.analchem.9b02983` | 未下载全文（无需，方法以代码为准） |

**数据集规模**：1,222 个文件 / 12.83 GB。其中 604 个 `.mzML` + 604 个 `.mzXML`
（Cohort1 78 样本、Cohort2 526 样本）+ 1 个 `.mat` + 参数与重命名脚本。

**许可**：
- 数据集：**CC0 1.0 Universal**（数据集页面明确声明）
- 代码：**不是 CC0**。`LICENSE.txt` 是 University of California 的
  「educational, research and non-profit purposes」授权，商业使用需单独联系
  UCSD Office of Innovation and Commercialization。二者不可混为一谈。

---

## 2. 数据格式与人工标注

### 2.1 原始谱图 → MS1 表（`mzXMLtoTables.R`）

`writeMS1Table()`（`:73`）对每个 mzXML/mzML 做：

```r
dt.header <- data.table(header(mzRobj))
vect.MS1scanNums <- subset(dt.header, msLevel == 1, select = c("seqNum"))$seqNum
dt.rtMzIntensityMS1[, mz        := round(mz, 4)]
dt.rtMzIntensityMS1[, intensity := round(intensity, 0)]
dt.rtMzIntensityMS1[, scanRT    := round(scanRT/60, 3)]   # 秒 → 分钟
```

每文件一张 CSV，三列：`mz / intensity / scanRT`。**只取 MS1**（`msLevel == 1`），
MS2 前体强度不进色谱。mz 保留 4 位小数，强度取整，RT 以分钟计保留 3 位。

### 2.2 窗口表（`exampleWindowTable.csv`）

```
windowID,windMzMin,windMzMax,windRtMin,windRtMax
window000007085,590.26505,590.28866,1.5192,1.5976
```

窗口来自 MZmine 2 对齐峰表（`PeakWindowGenerator.R` 支持用 apex / 起止边界
多种方式生成，作者在 `WorkFlow.md:52` 说明「哪种最好取决于色谱，需要试错」）。
**一个 window = 一个跨样品对齐后的峰组**，不是单样品里的一个峰。

### 2.3 人工标注在哪里、怎么定义

标注**不在数据文件里**，而是审阅时的产物：

1. `peakGroupImageMatrixAndPlot.R` 为每个窗口画一张 jpg 峰组图；
2. `createPeakReviewTrackingTable.R` 生成审阅表，**默认 `good1bad0` 全填 1**
   （`:51` `good1bad0 = rep(1, times = numImages)`）；
3. `peakReviewApp.R` 逐张看图，**默认判为好**，不满意才按空格标为 bad
   （`WorkFlow.md:59`：「each image is classified as "Good" or acceptable by default」)。

审阅表列（`NeuralNetworkDataPrep.R:234-242` 读取）：

| 列号 | 含义 |
|---|---|
| 2 | `windName`（与矩阵文件名对应，去掉 `.jpg`） |
| 3 | `viewed` 是否已看 |
| 4 | `label` **1 = good，0 = bad** |
| 5 | `windowBad` 窗口边界本身有问题（切到多个峰 / 切断单峰） |
| 6 | `borderline` 好/坏难分 |

**标注单位 = 跨样品的 aligned peak group（窗口）**，不是单个峰、也不是单个
(feature, sample) 对。这一点决定了模型输出的语义是「这一组跨样品峰形整体
像不像真峰」，而不是「某样品某峰质量如何」。

**关键推断风险**：标注是二分类「可否接受」，属于**主观可接受性**判断；
`borderline` 与 `windowBad` 的样本被显式排除（`:266`
`dt.Labels[viewed == 1][windowBad == 0][borderline == 0]`），不入训练也不入测试。
所以模型学到的边界**不覆盖**「边界切错」这一类错误——它默认窗口本身是对的。

---

## 3. 峰组图如何变成模型输入

### 3.1 R 工作流产出 31 × 200（`peakGroupImageMatrixAndPlot.R`）

`PeakGroupMatrix()`（`:366`）逐窗口执行：

| 步骤 | 代码 | 参数 |
|---|---|---|
| RT 中心 | `windRtMid <- (windRtMax + windRtMin) / 2` | `:399` |
| 列数 | `numRtSlices <- floor(RtDur / minRtSep)` | `RtDur=1`，`minRtSep=0.005` → **200** |
| RT 网格 | `round(seq(mid-0.5, mid+0.5, length.out=200), 4)` | 固定 1 分钟宽，与窗口实际宽度无关 |
| 成员筛选 | `dt.maxIntensity.window[intensity > 0]` | 窗口最大强度为 0 的样品**整行剔除** |
| 成员上限 | 超过 `maxLinesHigh+maxLinesOther` 时 | 按强度取前 21 + 随机 9（`propHighPeaks=0.7`，`maxSignalFiles=30`） |
| 每行曲线 | `GenWindowTable()` 取窗口内每个扫描在 **m/z 带内**的最大强度 | `:221` |
| 插值 | `approx(..., method="linear", rule=2, ties=mean)` | `:340`；`rule=2` 表示**区间外取端点值**（不外推、不补 0） |
| 非正 RT | `ifelse(x <= 0, 0, y)` | `:350` |
| 点数不足 | `nrow <= 2` → 整行 0 | `:355` |
| 补齐 | 不足 30 行补 0 行 | `:468` |
| 归一化 | `dataset / max(dataset)` | `:478`，**全局最大值**，不是逐行 |
| 窗口编码 | 追加第 31 行，窗口内 1、窗口外 0 | `:486` |
| 稀疏化 | `dataset[dataset == 0] <- NA` | `:497`，**只为减小文件体积**；读回时 `ReadToMatrix()` 把 NA 还原为 0 |

输出 31 行 × 200 列 CSV。

### 3.2 训练用的是 64 × 64（`EDML_deep_learning2.py:64`）

```python
input_shape=(64,64,1)
```

**实测** `EDML_trainTestCalData15.mat`（MATLAB 7.3 / HDF5，25,797,944 字节，
SHA-256 `afb629bb…adae2`，用 `rhdf5` 读取）：

| 数组 | HDF5 维度 | 元素类型 | 说明 |
|---|---|---|---|
| `trainX` | 64 × 64 × 1304 | float32 | 1304 张峰组图 |
| `trainY` | 1304 × 1 | float64 | 0/1 标签 |
| `calX` | 64 × 64 × 740 | float32 | 校准集 |
| `calY` | 740 × 1 | float64 | |
| `testX` | 64 × 64 × 726 | float32 | |
| `testY` | 726 × 1 | float64 | |

*注：`h5py` 读入时维度会转置为 `(N, 64, 64)`，作者脚本里的
`Xtrain.shape[1], Xtrain.shape[2]` 正是 64, 64，与 `input_shape` 一致。*

**实测数值特性**：

| 检查项 | 结果 |
|---|---|
| 像素值域 | `[0, 1]`，全局最大恰为 1 → 确认「除以矩阵最大值」 |
| 最后一行 | 只含 0/1，样本 1 里 64 列中 46 个为 1 → **窗口标记行确实存在** |
| NaN 数量 | **0**（前 4 个样本逐一检查） |
| `-2` 哨兵值 | 数据中**不存在** |
| 非零占比 | 样本 1/2 约 0.987，样本 3/4 约 0.25 → 不同峰的覆盖差异很大 |
| `trainY` 分布 | **652 / 652 完全平衡** |
| `calY` 分布 | 438 正 / 302 负（**不平衡**） |
| `testY` 分布 | 422 正 / 304 负（**不平衡**） |

两条由此确定的结论：

1. **`Xtrain[np.isnan(Xtrain)] = -2` 在实际数据上是空操作**。脚本写了，数据里
   没有 NaN。它可能是早期版本的遗留，也可能是对别的数据集的防御。无论哪种，
   **-2 不是训练数据的真实取值**，不能把它当作「缺失编码」来解释模型行为。
   `pq_dnn_train.py` 保留这行（忠实复刻）但同时统计 NaN 数量并写进日志。

2. **训练集平衡、校准与测试集不平衡**，这否掉了「`.mat` 直接来自
   `NeuralNetworkDataPrep.R`」的假设。那个脚本按 `numRowMinorityClass` 等量
   抽样，三套都会平衡。1304 = 652 × 2 与论文「1304 examples, 50% true / 50%
   false」一致，说明 652 是**每个类别的样本数**，训练集按类别做成了 1:1。

   同时可以直接测试镜像扩增（`mirrorMatrix` 的列翻转复制）是否留在了这份
   `.mat` 里。结论是**没有**——见 3.2.2，这一点推翻了本文件早期版本的猜测。

### 3.2.2 训练集没有镜像孪生体（实测，修正早期结论）

早期版本的本文件曾据 1304 = 652 × 2 推断「每张训练图都有一个左右镜像的孪生体」。
对数据做了直接检验后，**该推断不成立**：

| 检验 | 方法 | 结果 |
|---|---|---|
| 完全重复 | 对 1304 张图做 float32 字节级 SHA-1 | **1304 个互不相同的哈希，0 组重复** |
| 镜像重复 | 四种朝向（原样／列翻转／行翻转／双翻转）分别哈希 | **0 对命中** |
| 近似重复（套内） | 全量最近邻相关，1304 × 1304 | 最高 **0.9973**（一对，同类标签），>0.99 仅 1 对 |
| 近似重复（跨套） | 训练集 vs 校准集／测试集全量最近邻 | 最高 **0.9999**；测试集 **6/726** 张超过 0.99 |
| 泄漏对 AUC 的影响 | 剔除 >0.99 的 6 张后重算测试集 AUC | 0.9867 → **0.9866**，差 **0.0001** |

也就是说 `EDML_trainTestCalData15.mat` 是**去重后**的数据集：镜像扩增（如果做过）
发生在导出 `.mat` 之前，或者这份导出根本不含扩增。但**近似重复确实存在**——
训练集与测试集之间最大相关 0.9999，有 6 张测试图与某张训练图相关超过 0.99。
这类重复是字节哈希查不出来的，必须用内容相关才能发现。

影响评估：把 6 张相关 >0.99 的测试图剔除后，测试集 AUC 只从 0.9867 降到 0.9866。
**泄漏存在，但量级在万分之一个 AUC 单位，不足以支撑「复现是靠泄漏得来的」这种质疑。**
测试集样本数 726，6 张占 0.8%。

不能证明的部分：图像内容层面的近邻共享（同一台仪器、同一批样品、相邻色谱）是
精确哈希和相关性都排除不了的，那需要真正的外部数据。外部数据并不存在，见 3.4
与 `VALIDATION_REPORT.md`。全部数字由 `pq_dnn_diagnostics.py` 生成，
输出在 `reports/diagnostics_edml15.json`。

### 3.2.1 31×200 与 64×64 之间的关系（已确定轴向，未确定重采样方式）

R 脚本产出 31 行 × 200 列（30 样品 + 1 标记行，列是保留时间切片）。
`.mat` 里是 64 × 64。**两者的轴是转置关系**，这一点最初没有确定，现已通过对
全部 2770 张图的检查确定：

| 证据 | 检查 | 结果 |
|---|---|---|
| 标记行在哪一维 | 逐图检查最后一**行**是否只含 0/1 | 只有 **428 / 1304** 命中 |
| 标记行在哪一维 | 逐图检查最后一**列**是否只含 0/1 | **1304 / 1304** 全部命中 |
| 模型对朝向敏感吗 | 真实测试集转置后重算 AUC | **0.9867 → 0.8755**，掉 0.11 |

**结论：`.mat` 的 64 × 64 中，行 = 64 个保留时间切片，列 = 63 个样品 + 最后一列的
窗口标记。** 这与 R 脚本的 31 × 200（行 = 样品，列 = 时间）正好转置。

仍然不能确证的只剩下"怎么从 200 个切片变成 64 个切片"。仓库里没有任何代码做这件事，
`minRtSep = 1/64` 这个值也没有出现过。本项目采用**按下标等距取样**，并在
`R/peak_quality/pq_dnn_data.R` 的 `pq_dnn_to_model_geometry()` 里逐条写明：

* 保留时间轴 200 → 64 按下标压缩；
* **样品轴不做压缩也不做插值**——样品保持身份，占前 30 列，其余列补 0
  （读作"该样品在此处无信号"）。补 0 是诚实的；插值出并不存在的样品不是。
* 标记列取自原生标记行，与样品列用同一组下标压缩。

转换的正确性做了往返验证：把真实 64 × 64 图拆成 31 行原生布局再转回，
前 30 列与标记列**逐元素完全相同，最大绝对差 0**。

即便如此，**这仍是我们的重建，不是作者的重建**。所有经过该转换的行一律标注
`dnn_applicability = approximate_resampled_input`，不与论文的工作点直接可比。
改用原生 64 × 64 权重以外的路径（例如用 31 × 200 重新训练）不在本阶段范围内。

### 3.3 缺失与零信号的处理（两条路径一致）

- 窗口内**无任何信号** → 不生成矩阵，写一个 `.txt` 说明（`:505`）
- 单样品在窗口内无信号 → 该样品行**不进入矩阵**（不是补 0 行），只在成员不足 30 时才用 0 行补齐
- 导出时 0 → NA；训练时 `NaN → -2`（`EDML_deep_learning2.py:44/52/59`）
  ——**-2 是模型的"缺失"编码值，不是 0，也不是最小值截断**

---

## 4. 训练 / 校准 / 测试的划分

`NeuralNetworkDataPrep.R` 的划分是**按类分层且强行等量**的：

```r
numRowMinorityClass <- min(nrow(dt.LabelsGood), nrow(dt.LabelsBad))
numRowTrain    <- ceiling(numRowMinorityClass * propTrain)   # 0.5
numRowValidate <- ceiling(numRowMinorityClass * propValid)   # 0.25
numRowTest     <- numRowMinorityClass - numRowTrain - numRowValidate
```

即每类只取 **少数类那么多个**，多数类多余样本**直接丢弃**。默认 50% / 25% / 25%。

训练集再经两步扩增（`:146` `expandExamplesMirrorShuffle`）：
1. **镜像**：`mat[, ncol(mat):1]` 列翻转
2. **行打乱**：`mat[c(sample(nrow-1), nrow), ]`，**最后一行（窗口标记行）不动**

`numShuffle=1` 时训练集扩为 4 倍。少数类还会被额外复制到与多数类等量（`:178`
`matchTrainClassSize`）。**训练集里的样本不是独立观测**，这一点直接影响任何
置信区间的解释。

`EDML_deep_learning2.py` 使用的 `.mat` 已含划分好的 `trainX/trainY`、
`testX/testY`、`calX/calY`，脚本本身**不做划分**。

---

## 5. 模型结构与训练参数

### 5.1 网络（两版脚本等效）

`EDML_deep_learning2.py:69-89`（GitHub 版）：

```python
input_shape=(64,64,1); nb_neurons=[32,16]
Conv2D(32, (3,3), relu, padding='same')  → MaxPool(2,2) → Dropout(0.2)
Conv2D(16, (3,3), relu)                  → MaxPool(2,2) → Dropout(0.2)
Flatten → Dense(64, relu) → Dropout(0.5) → Dense(2, softmax)
```

MassIVE 里那份 `EDML_deep_learning2.py` 写的是 `nb_neurons=[32,16,16,32,64,64]`
（6 个值），但循环是 `for i in range(0,2)`，**仍然只建前 2 层**，用的是
`[32, 16]`；`Dense(nb_neurons[len-1])` 恰好等于 `Dense(64)`。所以两版网络结构
**相同**，只是数据集版启用了 `model=multi_gpu_model(model)`（GitHub 版注释掉了）。

| 项 | 值 |
|---|---|
| 损失 | `categorical_crossentropy`（二类 one-hot） |
| 优化器 | `nadam` |
| batch | 128 |
| epochs | 500，`EarlyStopping(monitor='val_loss', patience=10, restore_best_weights=True)` |
| 监控指标 | `mse`, `accuracy` |
| 保存 | `model.save('MLDeepLearningModel15.h5')` |
| 输出语义 | softmax 两列，取 `[:,1]` 当「好峰」分数 |

### 5.2 R 版不同（`buildNeuralNetworkModel.R`）

| 项 | 值 |
|---|---|
| 输入 | `c(31, imageWidth, 1)`，即 31 × 200 |
| 输出 | `Dense(1) + sigmoid`（binary，不是 softmax） |
| 损失 | `binary_crossentropy` |
| 优化器 | `adam` |
| epochs | 40，`patience=5`（无 `restore_best_weights`） |
| batch | 512 |

**这是两套不同的模型**，权重不可互换（输入维度与输出层都不兼容）。

### 5.3 阈值有三个不同来源

| 位置 | 阈值 | 说明 |
|---|---|---|
| `buildNeuralNetworkModel.R:249` | ROC `closest.topleft` 求出的最优值 | 报在训练报告里 |
| `ApplyPeakPredictionModel.R:188` | **硬编码 0.5** | `predProb >= 0.5` 才算好峰 |
| `filterOutBadPeaks.R:40` | **`scoreThresh <- .4`** | 实际滤峰默认值 |

原版自己也不同步。任何「按作者阈值」的说法都必须指明是哪一个。

---

## 6. 依赖与兼容性

`EDML_deep_learning2.py` 依赖：`keras`（独立包，非 `tf.keras`）、`numpy`、
`pandas`、`scipy`、`h5py`、`matplotlib`、`sklearn`、`IPython`。

已知在当前环境（Python 3.13 + TF 2.21 / Keras 3）下的阻塞点：

| 代码 | 问题 | 处理 |
|---|---|---|
| `from keras.utils import multi_gpu_model` | Keras 2.1–2.2 才有的 API，Keras 3 已移除 | 不可用；MassIVE 版启用它会直接 ImportError |
| `from keras.utils.vis_utils import plot_model` | Keras 2.6 起移出 | 需改为 `tf.keras.utils.plot_model` |
| `from IPython.display import clear_output` | 未使用但需装 IPython | 无害，可保留依赖 |
| `h5py.File('....mat','r')` | 要求 MATLAB v7.3（HDF5）格式 | 该 mat 需实测确认 |

R 侧依赖 `lcmsMetab`（UCSD 内部包，**不在 CRAN**）、`keras`、`abind`、`data.table`、
`ggplot2`、`gridExtra`、`pROC`。`lcmsMetab` 提供 `CreateOutputDir`、`WrtTable`、
`UpdateLogText`、`UpdateLogFile`、`runTime`、`NaZeroEmptyRmDup`、`ggThemeLcmsMetab`
——**这些函数在项目里全部缺失，是 R 工作流不可直接运行的根因**。

---

## 7. 与我们 Peak Quality 的语义差距（接入前必须明确）

| 维度 | 作者 DNN | 我们的 Peak Quality |
|---|---|---|
| 评价单位 | 跨样品**峰组**（一个窗口） | 单个 `(feature, sample)` |
| 需要输入 | 同一特征在**多个样品**的 XIC 一起构图 | 单条 XIC 即可 |
| 输出语义 | 「这组峰形整体可接受」的二分类分数 | 逐样品形状指标 + 四类 provisional 判定 |
| 标签来源 | 人工看图，主观可接受性 | 无标签，规则草案 |
| 缺样品时 | 该样品行不进图；全无信号则整窗不出图 | 逐行 `absent` / `unknown` |

**直接推论**：DNN 结果**不能**落在 `(feature, sample)` 行上当作单峰质量。
它只能落在一个 feature 的**峰组**层级，且必须与 Kumler/CPC 单峰指标分开呈现。

---

## 8. 审计中未能确证的事项（不猜）

1. **64×64 输入的生成方式**——仓库无对应代码。31×200 → 64×64 的重采样、
   裁剪或另一套窗口参数，均无证据。
2. **`EDML_Test15.mat` 与 `EDML_RestSetTest15.mat` 的来源**——`EDML_deep_learning2.py:133/148`
   引用，但 MassIVE 数据集**只有 1 个 `.mat`**，这两个文件不存在。
   作者所谓「独立测试集」无法复现。
3. **论文正文报告的指标**——未取全文，代码里只有 AUC 计算，没有分层的
   sensitivity/specificity 表。
4. **`lcmsMetab` 包源码**——UCSD 内部包，未公开，无法核对其 `WrtTable` 等函数
   的确切输出格式。

上述 1–2 项是**复现路径上的硬缺口**，只能按「部分复现」处理，不得声称完整复现。

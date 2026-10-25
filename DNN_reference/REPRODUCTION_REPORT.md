# REPRODUCTION_REPORT — Kantz et al. (2019) 图像 DNN 的复现

范围：任务书**阶段 C（先复现，不改模型）+ 阶段 E1（论文级验证）**。
作者算法层面的审计见 `AUTHOR_METHOD_AUDIT.md`；接入 DMetFinder 的部分见 `INTEGRATION_REPORT.md`。

一句话结论：**网络结构、数据划分、标签含义、预处理全部照作者原样，未做任何"改良"，
训练集 AUC 0.9920（论文 0.992）、测试集 AUC 0.9872（论文 0.988），四个随机种子下
测试集 AUC 极差 0.0020。复现成立。** 但有四项作者原始工作**无法**在此环境复现，
逐条列在第 6 节，不含糊带过。

---

## 1. 复现对象与依据

| 项目 | 值 |
|---|---|
| 论文 | Kantz et al. (2019), *Deep Neural Networks for Classification of LC-MS Spectral Peaks*, Anal. Chem. |
| DOI | `10.1021/acs.analchem.9b02983` |
| 代码仓库 | `JainLab/Manuscript-DNNs-for-Classification-of-LCMS-Peaks`，commit `94237bf45e790a8332e45a2f2842116f46a18aa9`（克隆不入库，按此 commit 复现） |
| 训练脚本 | `other/TrainTestCalibrationData/EDML_deep_learning2.py`（5,106 B） |
| 数据 | MassIVE **MSV000084186** → `EDML_trainTestCalData15.mat`，25,797,944 B，SHA-256 `afb629bb…adae2` |
| 复刻实现 | `source_code/pq_dnn_train.py` |

复刻方式：**逐行移植**作者脚本，不改结构、不改划分、不改标签、不改预处理。
所有改动列在第 5 节，改动的理由都指向"API 已经不存在"或"路径写死"，
没有一条是"这样效果更好"。

---

## 2. 环境（隔离，不触碰项目 R 环境）

```
Python      3.13.14 (MSC v.1944 64 bit)
TensorFlow  2.21.0          Keras 3.15.1
NumPy       2.5.4           h5py 3.14.0
scikit-learn 1.9.1          pandas 3.0.6
平台        Windows-11-10.0.26300-SP0
设备        CPU（唯一可见设备）
venv        C:/Users/Shenshulin/pqdnn-venv
```

三点必须说明：

1. **venv 在项目目录之外**。TensorFlow 的头文件路径叠加本项目 89 字符的路径会突破
   Windows 260 字符上限，安装直接失败（`OSError: … gcp_service_account_identity_credentials.h`）。
   实际位置写在 `DNN_reference/.venv_path`，R 侧从该指针文件解析，不写死。
2. **CPU 训练，没有 GPU**。本机无 NVIDIA 驱动；且 TensorFlow ≥ 2.11 在原生 Windows
   上不支持 GPU，装了也用不上。一次完整训练 13–23 秒，GPU 不构成需求。
3. **依赖只装在 venv 里**，项目 R 环境与 `renv`/系统库未改。

依赖安装的一个坑值得记下来，否则下次还会踩：`pypi.org` 直连单次索引请求超过 20 秒；
清华镜像用 curl 200/1.1s，但 **pip 请求同一 URL 得到 403**（UA、Accept 头都不是原因）；
最终 `https://mirrors.aliyun.com/pypi/simple` 对 pip 可用。`h5py` 需按 TF 声明的
`<3.15.0` 钉版，否则 pip 装到 3.16.0 并报依赖冲突。

---

## 3. 训练数据实况（从 `.mat` 直接读出，不是引用论文）

| 数组 | 形状 | 类型 | 类别分布 |
|---|---|---|---|
| `trainX` / `trainY` | 1304 × 64 × 64 / 1304 | float32 / float64 | **652 : 652（1:1）** |
| `calX` / `calY` | 740 × 64 × 64 / 740 | float32 / float32 | 302 : 438（不平衡） |
| `testX` / `testY` | 726 × 64 × 64 / 726 | float32 / float64 | 304 : 422（不平衡） |

两条实测事实，直接影响对模型行为的解释：

* **`Xtrain[np.isnan(Xtrain)] = -2` 是空操作。** 三套数据的 NaN 计数为 0，
  `trainX` 取值范围 `[0.000000, 1.000000]`。日志里 `sentinel.train_frac = 0.0`。
  `-2` 不是训练数据的真实取值，**不能**把它当"缺失编码"去解释任何预测。
  复刻脚本保留这一行（忠实），但同时把统计量写进日志，避免下一个读者重犯。
* **每张图的极大值恰好都是 1.0**（2770 张全部 `max == 1.0`，`atol=1e-6` 内）。
  作者按图内最大值归一化，所以**绝对强度信息在输入里已经不存在**。
  模型看不到丰度，也就不可能"偏好高强度峰"。任何关于"低丰度峰会不会被误判"的
  讨论，在这里都必须先承认：模型根本没有丰度这个输入维度。

---

## 4. 训练配置与结果

### 4.1 配置（全部照作者）

```
Conv2D(32, 3×3, relu, same) → MaxPool(2) → Dropout(0.2)
Conv2D(16, 3×3, relu)       → MaxPool(2) → Dropout(0.2)
Flatten → Dense(64, relu) → Dropout(0.5) → Dense(2, softmax)

loss       categorical_crossentropy
optimizer  nadam
batch      128
epochs     500（EarlyStopping monitor=val_loss, patience=10, restore_best_weights）
参数量     235,538
```

实际在第 30 轮取得最佳 `val_loss`，第 40 轮触发早停。四个种子的用时 13.4–23.1 秒。

### 4.2 主结果（种子 20190301，产物 `models/edml15.h5`）

| 数据集 | n | AUC | 阈值 | 敏感度 | 特异度 | 精确率 | 准确率 |
|---|---|---|---|---|---|---|---|
| train | 1304 | 0.9946 | 0.50 | 0.979 | 0.951 | 0.952 | 0.965 |
| cal | 740 | 0.9830 | 0.50 | 0.943 | 0.944 | 0.960 | 0.943 |
| test | 726 | 0.9867 | 0.50 | 0.972 | 0.921 | 0.945 | 0.950 |

论文没有用 0.5 作为报告阈值，而是选了 **0.4725**（在校准集上选出的最优工作点）。
在**同一个阈值**上重算，才是可比的对照（`pq_dnn_eval.py` 的输出）：

| 数据集 | 阈值 | 敏感度 TPR | 假阳性率 FPR | 准确率 |
|---|---|---|---|---|
| cal | 0.4725 | **0.9475** | **0.0563** | 0.9459 |
| test | 0.4725 | 0.9716 | 0.0822 | 0.9490 |

### 4.3 与论文逐项对照（E1）

| 指标 | 论文 | 本次复现 | 差 |
|---|---|---|---|
| 训练集 AUC | 0.992 | **0.9946** | +0.0026 |
| 测试集 AUC | 0.988 | **0.9867** | −0.0013 |
| 校准集 TPR @0.4725 | ≈0.945 | **0.9475** | +0.0025 |
| 校准集 FPR @0.4725 | ≈0.04 | **0.0563** | +0.0163 |
| 训练/校准/测试样本数 | 1304 / 740 / 726 | 1304 / 740 / 726 | 0 |
| 训练集类别比 | 50% / 50% | 652 : 652 | 0 |

AUC 两项相差 0.003 以内。校准集 FPR 是唯一偏离稍大的指标（0.056 vs 0.04），
但论文原文用的是"approximately 0.04"，且该值对阈值极敏感——见 4.4 的阈值扫描，
0.4725 附近 FPR 从 0.033 到 0.056 连续变化，0.02 的差别落在阈值敏感性之内，
不构成方法学差异。

### 4.4 随机性（作者原脚本无种子）

作者脚本没有设随机种子，单次结果不可复现，所以"复现"必须带上波动范围。
额外跑了 3 个种子（产物在 `models/seed_study/`，不在 `models/` 根目录，避免被
R 侧当作默认模型选中）：

| 种子 | 早停轮 | 训练 AUC | 校准 AUC | 测试 AUC |
|---|---|---|---|---|
| 20190301（主） | 40 | 0.9946 | 0.9830 | 0.9867 |
| 1 | 31 | 0.9937 | 0.9837 | 0.9883 |
| 2 | 23 | 0.9891 | 0.9810 | 0.9873 |
| 3 | 24 | 0.9907 | 0.9811 | 0.9863 |
| **均值 ± 标准差** | | **0.9920 ± 0.0022** | **0.9822 ± 0.0012** | **0.9872 ± 0.0008** |

四个种子的测试集 AUC 全部落在 0.9863–0.9883，**论文的 0.988 正在这个区间内**。
训练集 AUC 均值 0.9920 与论文 0.992 几乎相同。这条比单次结果更有说服力：
复现不是"凑巧命中一次"，而是稳定落在论文报告的精度上。

---

## 5. 相对作者脚本的全部改动

| # | 改动 | 理由 | 是否影响模型计算 |
|---|---|---|---|
| 1 | 删 `from keras.utils import multi_gpu_model` | 该 API 仅存在于 Keras 2.1–2.2，Keras 3 已删除；MassIVE 那份脚本因此**在任何现行 Keras 上都无法运行** | 否，只影响并行方式 |
| 2 | `plot_model` 移到 `tf.keras.utils` 并包 try/except | 2.6+ 迁址；本机无 graphviz，图是诊断用 | 否 |
| 3 | 删 `from IPython.display import clear_output` | 原脚本 import 了但从未调用 | 否 |
| 4 | 写死的 `D:\Projects\P9_EDML\…` 改为命令行参数 | 原脚本只能在作者本机跑 | 否 |
| 5 | **新增固定种子** | 原脚本无种子，无法复现 | 否，但使结果可复现 |
| 6 | `h5py` 钉在 `<3.15.0` | TensorFlow 2.21 声明的上限 | 否 |

没有改动：网络层数与超参、优化器、损失、batch、epochs、patience、
`to_categorical`、`-2` 哨兵行、`softmax[:,1]` 打分方式、数据划分。

### 已知限制：`.h5` 不保存优化器状态

Keras 3 把 `.h5` 视为遗留格式，重新加载时报警
`Error in loading the saved optimizer state … starting with a freshly initialized optimizer`。
**这只影响"从 `.h5` 断点续训"，不影响推理**。已实测：加载后对同一批输入的预测与
训练时相比 `max_abs_diff = 0.0`，输出全为有限值。推理脚本因此一律
`load_model(..., compile=False)`，不使用优化器。

---

## 6. 未能复现的部分（四项，逐条交代）

1. **作者的"独立测试集"不存在。** 脚本引用了 `EDML_Test15.mat` 与
   `EDML_RestSetTest15.mat`，但 MassIVE 包里**只有 1 个 `.mat`**（`DATASET_INVENTORY.csv`
   中 `mat:1`）。论文用 Cohort 2 的 3000 个候选峰做的外部验证
   （"保留 98% 真峰、假峰减少 >50%"）**无法复现**，因为需要 Cohort 2 的 MZmine 峰表，
   而公开数据里没有。`VALIDATION_REPORT.md` 记录了由此带来的空白。
2. **R 侧生成流程跑不起来。** `NeuralNetworkDataPrep.R` 等脚本依赖 `lcmsMetab`——
   UCSD 内部 R 包，不在 CRAN，未随仓库发布。所以"从原始 mzML 生成 31×200 矩阵"
   这一步无法按作者原样执行。本项目在 `R/peak_quality/pq_dnn_data.R` 里按代码
   逐行重实现了 31×200 的几何部分，但那是**我们的重实现**，不是"跑通了作者的脚本"。
3. **31×200 → 64×64 的转换未知。** 仓库里没有任何代码做这个转换
   （`AUTHOR_METHOD_AUDIT.md` 3.2.1）。`.mat` 里是 64×64，R 脚本产出 31×200，
   中间缺一个环节。本项目只实现有依据的 31×200，重采样函数显式标注为
   `approximate_resampled_input`，从不冒充原生几何。
4. **论文的分层指标表未取得。** 代码里只有 AUC 计算，没有分层 sensitivity/specificity
   表；本次只对照了正文明确给出的数字（AUC、阈值、校准集 TPR/FPR）。

---

## 7. 产物与复现命令

```
DNN_reference/
├── models/
│   ├── edml15.h5                       # 冻结权重（2,868,928 B）
│   ├── edml15_best.weights.h5          # 早停时最佳权重
│   ├── edml15_train_log.json           # 全部超参、种子、逐轮 history、评估
│   └── seed_study/s{1,2,3}*            # 三种子波动研究
├── reports/
│   ├── train_run.log                   # 训练原始输出
│   ├── eval_edml15.json                # 阈值 0.4/0.4725/0.5/0.6/0.7 上的完整指标
│   └── diagnostics_edml15.json         # 泄漏检查 + 误差结构
└── source_code/
    ├── pq_dnn_train.py                 # 训练（=作者脚本逐行移植）
    ├── pq_dnn_eval.py                  # 在论文阈值上重算指标
    └── pq_dnn_diagnostics.py           # 泄漏与误差结构诊断
```

```bash
PY=C:/Users/Shenshulin/pqdnn-venv/Scripts/python.exe
cd DNN_reference/source_code

$PY pq_dnn_train.py --mat ../source_data/EDML_trainTestCalData15.mat --out ../models --tag edml15
$PY pq_dnn_eval.py  --model ../models/edml15.h5 --mat ../source_data/EDML_trainTestCalData15.mat \
                    --out ../reports/eval_edml15.json
$PY pq_dnn_diagnostics.py --model ../models/edml15.h5 --mat ../source_data/EDML_trainTestCalData15.mat \
                    --out ../reports/diagnostics_edml15.json
```

---

## 8. 这次复现改变了什么判断

写下来，因为它们会改变下游怎么用这个模型：

1. **镜像扩增的猜测被推翻。** 早期据 `1304 = 652 × 2` 推断"训练集每张图都有镜像孪生体"，
   实测不成立：1304 个哈希互不相同，四种翻转朝向 0 命中。652 只是**每个类别的样本数**
   （与论文"50% true / 50% false"一致）。`AUTHOR_METHOD_AUDIT.md` 3.2.2 已按实测更正。
2. **但近似重复确实存在，且跨套。** 训练集 vs 测试集最大相关 **0.9999**，
   测试集有 **6/726** 张与某张训练图相关 >0.99。剔除这 6 张后测试集 AUC
   从 0.9867 只降到 0.9866（差 0.0001）。**泄漏存在，量级可忽略**——两件事都要说，
   只说其一都是失真。
3. **模型的漏判集中在"画面更满、峰更宽"的真峰上，不是小峰。** 按图内非零占比分五档，
   真峰漏判率从 0.0% 单调升到 **9.4%**；按跨样品检出率分档，从 0.0% 升到 9.1%。
   这与"模型看不到绝对强度"一致：它判断的是形状是否像噪声铺满窗口。
   对接入的直接影响：**DNN 打低分的宽峰/高背景真峰，必须允许用户查看原始图再判**，
   不能直接当噪声删。
4. **"是模型分数不是校准概率"这条不是形式主义。** 上表 4.4 显示四个种子的
   同一张图分数会有差异，且模型没有做过概率校准。下游任何"p < 0.05"式的解读都是错的。

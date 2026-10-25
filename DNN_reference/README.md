# DNN_reference — Kantz 2019 峰分类 DNN 的复现与接入

这个目录是 DMetFinder Peak Quality 第 8 个页签（**DNN**）背后的全部材料。
它存在的目的不是"多一个模型"，而是让每一个数字都能追到出处。

开始读之前先看三句话：

1. **模型能用，但只能当提示**。它给出的是模型分数，不是校准概率，也不改写
   `quality_class`。DMetFinder 里没有任何路径允许它删峰或给峰贴"高质量"标签。
2. **输入要经过一次无据可依的几何转换**。作者训练用 64×64，DMetFinder 原生产出
   31×200，中间那一步作者没公开。转换是我们重建的，所有受影响的行都标注了
   `dnn_applicability = approximate_resampled_input`。
3. **它在你自己的数据上准不准，目前没有证据**。缺的不是代码，是带标签的数据。

---

## 先读哪一份

| 你想知道 | 读这个 |
|---|---|
| 作者到底怎么做的？每一句结论对应哪行代码？ | [`AUTHOR_METHOD_AUDIT.md`](AUTHOR_METHOD_AUDIT.md) |
| 复现出来和论文差多少？ | [`REPRODUCTION_REPORT.md`](REPRODUCTION_REPORT.md) |
| 换到别的数据上还成立吗？有哪些坑？ | [`VALIDATION_REPORT.md`](VALIDATION_REPORT.md) |
| 怎么接进 Peak Quality？改了哪些文件？ | [`INTEGRATION_REPORT.md`](INTEGRATION_REPORT.md) |
| 用之前要知道什么限制？能商用吗？ | [`MODEL_CARD.md`](MODEL_CARD.md) |
| 下载了哪些文件？校验值？许可证？ | [`DATA_MANIFEST.csv`](DATA_MANIFEST.csv) / [`DATASET_INVENTORY.csv`](DATASET_INVENTORY.csv) |

---

## 核心结论（一分钟版）

**复现成立**：训练集 AUC **0.9920 ± 0.0022**（论文 0.992），测试集 AUC
**0.9872 ± 0.0008**（论文 0.988），四个随机种子的测试 AUC 极差 0.0020。
论文选定的工作点 0.4725 上，校准集 TPR **0.9475**（论文约 0.945）。

**三个必须知道的缺陷**：

| 缺陷 | 量级 | 影响 |
|---|---|---|
| 输入几何要转置重建，作者无公开代码 | 往返误差 0，但无标签验证 | 分数不与论文工作点直接可比 |
| 分数随样品数系统性升高 | 3 样 0.902 → 30 样 1.000 | 不同样品数的队列之间分数不可比 |
| 双峰/肩峰被判为可接受 | 构造实验 0.91–0.9999 | 高分不能排除双峰；这是论文自述的已知失效形态 |

**一个已被推翻的早期猜测**：曾据 `1304 = 652 × 2` 推断训练集是镜像扩增，
实测 1304 张图互不相同、四种翻转朝向 0 命中。652 只是每个类别的样本数。
已按实测改写 `AUTHOR_METHOD_AUDIT.md` 3.2.2。

---

## 目录结构

```
DNN_reference/
├── source_data/          下载的原始资源（.mat、参数、清单）
├── source_code/
│   ├── repo/             作者仓库原样快照 @94237bf（含 LICENSE.txt，勿改）
│   ├── pq_dnn_train.py   训练（作者脚本逐行移植）
│   ├── pq_dnn_predict.py 批量推理（只读冻结权重）
│   ├── pq_dnn_eval.py    在论文阈值上重算指标
│   └── pq_dnn_diagnostics.py 泄漏检查与误差结构
├── reference_docs/       论文相关材料（空：全文未纳入版本库）
├── processed_data/
│   ├── matrices/         每次运行导出的峰组矩阵 CSV（按 run tag 分目录）
│   └── predictions/      每次运行的推理输出
├── models/               冻结权重 + 训练日志 + 种子波动研究
├── reports/              训练原始日志、评估 JSON、诊断 JSON
└── _wheels/              离线安装用的 wheel（构建产物，已被 .gitignore 忽略）
```

配套的 R 侧代码不在本目录：

- `R/peak_quality/pq_dnn_data.R` — 峰组图构建 + 模型布局转换
- `R/peak_quality/pq_dnn_integration.R` — 模型发现校验、调 Python、结果挂表、一键编排

---

## 复现全部数字

Python 环境在**项目之外**（TensorFlow 头文件路径会突破 Windows 260 字符上限），
位置记在 `.venv_path`：

```bash
PY=C:/Users/Shenshulin/pqdnn-venv/Scripts/python.exe
cd DNN_reference/source_code

# 训练（约 20 秒，CPU）
$PY pq_dnn_train.py --mat ../source_data/EDML_trainTestCalData15.mat \
                    --out ../models --tag edml15

# 论文阈值上的指标
$PY pq_dnn_eval.py --model ../models/edml15.h5 \
                   --mat ../source_data/EDML_trainTestCalData15.mat \
                   --out ../reports/eval_edml15.json

# 泄漏与误差结构
$PY pq_dnn_diagnostics.py --model ../models/edml15.h5 \
                          --mat ../source_data/EDML_trainTestCalData15.mat \
                          --out ../reports/diagnostics_edml15.json
```

R 侧端到端演示（合成数据，含正负对照）：

```bash
Rscript .workbuddy/tools/demo_dnn_pipeline.R
```

`source_data/*.mat` 需要先按 `DATA_MANIFEST.csv` 里的地址从 MassIVE 取回，
并核对 SHA-256 `afb629bb…adae2` 与大小 25,797,944 B。

---

## 许可证：数据集和代码不是一回事

| 资产 | 许可 | 商用 |
|---|---|---|
| 数据集 MSV000084186 | **CC0 1.0** | 可以 |
| 作者代码 @94237bf | **UC Regents，仅教育/研究/非营利** | **不可以**，须书面许可 |
| 本项目脚本 | 作者脚本的衍生作品 | 同上 |
| `models/edml15.h5` | 状态不明确 | 按最严处理 |

因此**是否把冻结权重 `.h5` 提交进公开仓库，是一个需要你决定的问题**，
本目录没有替你决定。要分发（含 TBtools 插件渠道）请先读 `MODEL_CARD.md` 第 6 节。

---

## 已知未完成

1. 作者的外部测试集（`EDML_Test15.mat`、`EDML_RestSetTest15.mat`）在公开数据里不存在，
   论文基于 Cohort 2 的外部验证**无法复现**。
2. 31×200 原生几何上没有训练过。要做这件事需要**带人工标签的峰组**，目前没有。
3. 没有批次/仪器漂移检测。数据分布偏离作者数据时，模型不报警，只给分数。

---

## TBtools 插件里没有 DNN（这是有意为之）

`.workbuddy/tools/build_tbtools_plugin.sh` 的分发清单是
`app.R README.md R ui server shiny_app www demo_data`——**不含 `DNN_reference/`**。
因此插件版启动后，DNN 页签会如实显示：

```
DNN prediction unavailable: model weights not available
```

这不是 bug，也不要靠"把 `.h5` 塞进插件包"来消除它：

* 冻结权重是由作者代码训练出来的衍生作品，其许可状态不明确，而作者代码是
  **UC Regents 仅教育/研究/非营利**（见 `MODEL_CARD.md` 第 6 节）；
* 插件是面向公众分发的渠道，是否落入 "commercial use" 需要由你判断并承担，
  不应该由一个构建脚本默默决定；
* Python 运行时也不在项目内（venv 在 `C:/Users/<you>/pqdnn-venv`），
  插件用户不会有这个路径。

需要让插件用户也能用 DNN 时，正确顺序是：先解决许可，再决定是否把 Python
依赖与权重一起打包，最后才改 `APP_ITEMS`。在那之前，缺省关闭是更安全的默认。

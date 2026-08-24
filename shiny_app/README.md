# MSGeter

基于 R Shiny 的质谱（Mass Spectrometry）数据处理工具，提供 MS1 特征提取与 MS2 谱图匹配两大功能模块。

## 功能模块

### Ms1Geter

提取原始质谱数据（`.raw` 文件）中的 MS1 与 MS2 信息，并输出后续分析所需的中间文件。

**输入：**

| 输入项 | 说明 |
| --- | --- |
| 工作目录 | 存放 `.raw` 文件及结果输出的目录 |
| 样本分组文件 | CSV 或 XLSX 格式，必须包含 `Sample`（样本名，与 `.raw` 文件名一致）和 `Group`（分组名）两列 |

**输出（写入工作目录）：**

- `MS2_Group_Info.csv` — 所有样本 MS2 扫描信息汇总表（扫描号、保留时间、母离子 m/z 等）
- `MS2_MGF/` 目录 — 每个样本对应的 `.msp` 谱图文件（含 NAME / PRECURSORMZ / IONMODE / RETENTIONTIME / 峰列表）
- `Clean_MS1_Data_Group*.xlsx` — 按分组输出的清洗后 MS1 数据（按保留时间窗口去重、ppm 消卷积、强度过滤）

### Ms2Geter

基于目标特征列表，从 MSP 文件中提取匹配的二级谱图，生成用于建库的 MSP 文件。

**输入：**

| 输入项 | 说明 |
| --- | --- |
| `MS2_Group_Info.csv` | Ms1Geter 导出的扫描信息汇总表 |
| `demo.csv` | 目标特征列表，必须包含 `sample`（样本名）、`m/z`（母离子质荷比）和 `RT`（保留时间）列 |
| MGF 文件夹 | 存放 Ms1Geter 生成的 `.msp` 文件的目录 |
| 输出文件名 | 生成的 MSP 文件名称 |

**匹配逻辑：**

- 按样本名筛选 MS2 扫描信息
- 按 m/z 容差（0.01 Da）筛选候选扫描
- 按保留时间差、m/z 差排序，取最优匹配扫描
- 从对应 MSP 文件中提取该扫描的谱图

**输出：**

- 目标 MSP 文件（写入所选 MGF 文件夹），每个谱图块包含：
  - `NAME` — 样本名 + 扫描号
  - `FEATURE_INFO` — 样本名、RT、m/z 溯源信息
  - `PRECURSORMZ`、`IONMODE`、`RETENTIONTIME`
  - 峰列表（m/z intensity）

## 环境要求

- R (>= 4.0)
- Shiny 相关依赖包：
  - shiny、shinyFiles
  - readxl、dplyr、openxlsx、stringr、tools、data.table、purrr
  - rawrr（需配套 Thermo RawFileReader 的 .NET 库）

## 使用说明

```r
# 在项目根目录下运行
shiny::runApp()
```

启动后浏览器打开 Shiny 界面（默认 `http://127.0.0.1:xxxx`），进入对应标签页操作：

1. **Ms1Geter**：设置工作目录 → 上传样本分组文件 → 点击 `Run Analysis`，完成后在工作目录查看输出文件。
2. **Ms2Geter**：上传 `MS2_Group_Info.csv` 与 `demo.csv` → 选择包含 MSP 文件的文件夹 → 设置输出文件名 → 点击 `Run Extraction`，处理日志显示在右侧面板。

## 项目结构

```
shiny_app/
├── app.R                        # 应用入口（加载模块、定义 UI 与 server）
├── ui/
│   ├── FeatureGeter_ui.R        # Ms1Geter 界面
│   └── Ms2Geter_ui.R            # Ms2Geter 界面
└── server/
    ├── FeatureGeter_server.R    # Ms1Geter 逻辑（raw 解析、清洗、导出）
    └── Ms2Geter_server.R        # Ms2Geter 逻辑（扫描匹配、MSP 提取）
```

## 注意事项

- 上传文件大小上限已设置为 100 MB（见 `app.R` 中的 `shiny.maxRequestSize`）。
- 样本名需与 `.raw` 文件名保持一致（不含扩展名）。
- Ms1Geter 当前针对特定扫描类型（`FTMS - p ESI Full ms [100.0000-1500.0000]`）编写，如需适配其他仪器方法请对应调整 `FeatureGeter_server.R` 中的扫描类型判断。
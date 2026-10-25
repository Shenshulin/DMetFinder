# DMetFinder 1.0.3 源码拆解：模块 / 输入 / 输出

> 面向维护者。所有输出结构均由原版 `DMetFinder.exe` 实跑产物逐个 sheet 核对得出，
> 行数取自 `demo_data/groupA.xlsx`、`groupB.xlsx`（A/B 各 10 个样品）。

---

## 0. 先分清"哪一份是源码"

工作目录 `DMetFinder1.0.3/` 下同时躺着三份东西，容易混淆：

| 路径 | 是什么 | 语言 / 规模 | 状态 |
| --- | --- | --- | --- |
| `DMetFinder.exe` + `jre/` | **原版商用程序**（exe4j 打包，内嵌两个 jar） | Java 8 / 33 个业务类 3,239 行 | 权威基准，不可改 |
| `.workbuddy/reverse/decompiled/corvida/` | 上者的反编译产物（CFR 0.152） | Java 源码 | 只读参考 |
| `DMetFinder/`（内层） | **R Shiny 重写版**（git 仓库） | R / 12,686 行 | 在用，主目录 |
| `R/`、`ui/`、`server/`、`app.R`（外层根目录） | 8 月 13 日的旧拷贝 | R / 约 500 行 | **已废弃**，勿改 |

后续所有讨论以 `DMetFinder/` 为准；外层那份 `R/dmetfinder_functions.R` 只有 13 KB，
是重写前的简化版，跟现在的 60 KB 完全不是一回事。

---

## 1. 原版 Java 源码：33 个类，分 7 层

### 1.1 包结构与职责

```
corvida
├── desktop        界面（Swing）
├── core
│   ├── Config     全局参数实体
│   ├── calc       流程编排 + 打分接口
│   ├── collection 离子集合、矩阵、二分检索
│   ├── model      8 个数据模型（同时定义 Excel 表头）
│   ├── io         Excel 读写
│   └── utils      BigDecimal 语义、T 检验、排序键
```

| 层 | 类 | 行数 | 职责 |
| --- | --- | --- | --- |
| desktop | `MainFrame` | 331 | 主窗：A/B 文件、输出目录、日志框、"开始计算" |
| | `ConfigDialog` | 487 | 参数编辑对话框（28 项） |
| | `AppConfig` | 97 | 记住上次路径与最近配置列表 |
| | `MyPanel` | 40 | 背景图面板 |
| core | `Config` | 85 | 28 个参数 + fastjson 读写 |
| calc | **`IonCalculator`** | 728 | **唯一编排者**：Process / p80CompareWith / mergeDiff |
| | `IStd` | 18 | 打分接口 |
| collection | `IonsManager` | 34 | 接口 |
| | `IonsManager2` | 184 | 强度矩阵、唯一化、按 count 排序、按 key 切换 |
| | `Helper` | 206 | `binarySearch` / `sort` / `toMapF` |
| | `V` | 9 | 比较器 |
| model | `Ion` | 36 | 离子（8 个键 + 强度 + count + 矩阵行） |
| | `MatrixRow` | 28 | 一个离子在各样品上的强度行 |
| | `P50Score` | 41 | 50% 离子打分（13 列） |
| | `IonScore` | 44 | 全离子两维度打分（21 列） |
| | `MergedScore` | 30 | 两套打分的合并视图 |
| | `Isotope` | 54 | 同位素（26 列） |
| | `P80CompareInfo` | 19 | 跨组比对单条（21 列） |
| | `IonDiff` | 20 | 差异行（41 列） |
| io | `IoHelper` | 90 | `ReadSamples` / `writeToExcel`（8 线程异步） |
| | `AnalysisIonListener` | 69 | EasyExcel 行监听器 → `Ion` |
| | `CustomCellWriteHandler` | 45 | 把 null 写成 `NullCellValue` |
| | `ICanConvert2ExcelRow` | 13 | 表头 / 行的统一接口 |
| utils | `BigDecimalHelper` | 206 | `truncate` / `divideD` / `values*` 系列 |
| | `TTest` | 69 | P 值 |
| | `Mutil` / `Log` / `CalcTools` / `Stds` | 124 | 杂项、日志、常量 |
| | `RtMz/NoMz/RtNoMz/Mz PickerSetter` | 100 | 四种排序键的访问器 |

依赖方向单向：`desktop → core.calc → core.collection / core.model / core.io / core.utils`。
**没有 service 层，所有流程都压在 `IonCalculator` 一个类里**——这也是 R 版把 728 行拆成
11 层 37 个函数的原因。

### 1.2 原版执行链

```
MainFrame.onOK                                    (Swing 按钮)
  └─ IonCalculator.Process(aPath, bPath, outDir, config)
       ├─[线程1] A组.Process()
       │    ├─ IoHelper.ReadSamples          → List<Ion> + sampleNames
       │    ├─ IonsManager2.createIntensityMatrixInfo
       │    ├─ p50p80FilterIonsWrap   → A组-筛选50%和80%离子.xlsx   (3 sheet)
       │    ├─ scoringIonsWrap        → A组-离子打分.xlsx           (3 sheet)
       │    └─ calcIsotopesWrap       → A组-同位素离子查找.xlsx     (1 sheet)
       ├─[线程2] B组.Process()                → 同结构 3 个文件
       ├─[线程3] A.p80CompareWith(B)   → A组-80%离子与B组总离子比对分析.xlsx
       ├─[线程4] B.p80CompareWith(A)   → B组-80%离子与A组总离子比对分析.xlsx
       ├─ mergeDiff(A,B)（内部再开 2 个线程）
       │                              → A组-B组差异离子筛选汇总.xlsx  (2 sheet)
       └─ IoHelper.waitAllWriteThreads()     // 写盘另走 8 线程池
```

一次完整跑批：A 组约 14 s、B 组约 11 s、比对与差异约 3 s，**总 20 s 左右**，
产出 9 个 xlsx 约 150 MB（同位素表与打分表都是全离子量级，单表 35 万行）。

---

## 2. R 版源码：11 层

`R/dmetfinder_functions.R`（1,401 行，37 个函数）按 Java 结构逐层对应：

| 层 | 行 | R 函数 | 对应 Java |
| --- | --- | --- | --- |
| 0 常量 | 31 | `.dmf_fix_offset` / `.dmf_truncate_*` | 字面量 |
| 1 数值语义 | 43 | `dmf_truncate` `dmf_divide` `dmf_score` `dmf_integer_string` `dmf_decimal_parts` | `BigDecimalHelper` |
| 2 区间检索 | 171 | `dmf_window_bounds` `dmf_argmin_in_window` `dmf_bsearch_java` | `Helper.binarySearch` + `IonsManager2.findIons` |
| 3 数据读取 | 341 | `dmf_read_samples` | `AnalysisIonListener` + `IoHelper.ReadSamples` |
| 4 强度矩阵 | 449 | `dmf_create_matrix` | `buildIntensityMatrix` + `MatrixRow` |
| 5 筛选唯一化 | 501 | `dmf_sort_by_count` `dmf_distinct_pass` `dmf_distinct_ions` `dmf_subset_ions` | `filterIons` + `distinctIons` |
| 6 打分 | 565 | `dmf_score_p50` `dmf_score_all_ions` | `scoringP50Ions` / `averageScore4AllIons` / `mergeScore` |
| 7 同位素 | 712 | `dmf_calc_isotopes` | `calcIsotopes` |
| 8 跨组比对 | 818 | `dmf_compare_p80` `dmf_merge_diff` | `p80CompareWith` / `mergeDiff` |
| 9 输出表 | 966 | `dmf_sheet` `dmf_hdr` `dmf_cols_*` `.dmf_sheet_*` | 各 `toSheetData` |
| 10 写盘 | 1149 | `dmf_write_sheets` | `IoHelper.writeToExcel` |
| 11 主流程 | 1189 | `dmf_merge_config` `dmf_process_group` `dmetfinder_run` | `IonCalculator.Process` |

调用方式：

```r
res <- dmetfinder_run("demo_data/groupA.xlsx", "demo_data/groupB.xlsx",
                      "out", config = NULL,               # NULL = default_config
                      group_names = c("A组", "B组"),
                      progress = function(frac, detail) …)  # 供 Shiny 进度条
res$files    # 9 个输出文件的绝对路径
res$sheets   # 19 个 sheet 的 data.frame，供界面预览
```

`server/dmetfinder_server.R`（197 行）只做三件事：接文件、拼配置、把 `progress`
接到 `incProgress`，再预览 / 打包下载。**业务逻辑一行都不在服务端。**

---

## 3. 输入

### 3.1 两个 Excel 文件

| 项 | 说明 |
| --- | --- |
| 数量 | 恰好 2 个：A 组、B 组各一份 |
| 格式 | `.xlsx` / `.xls`（EasyExcel 读取；R 端用 `readxl`） |
| 读取范围 | **只读第一个 sheet**（`.sheet()` 无参） |
| 表头 | 第 1 行视为表头，**自动跳过**（EasyExcel `headRowNumber` 默认 1） |
| 布局 | 每 **6 列** 为一个样品块，横向排列 |
| 列数 | 样品数 × 6（demo 为 10 样品 → 59 列，最后一列为空可缺） |

### 3.2 单个样品块的列契约

| 列序 | 表头 | 取值方式 | 类型 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `Sample (No)` | `Cell.toString()` | 文本/整数 | 样品编号，同时充当"样品名" |
| 2 | `RT` | `getNumberValue()` | 数值 | 保留时间（分钟） |
| 3 | `RT&m/z` | `getNumberValue()` → `truncate` | 数值 | **上游已算好**：`RT×1000 + m/z` |
| 4 | `m/z` | `getNumberValue()` → `truncate` | 数值 | 质荷比 |
| 5 | `Intensity` | `getNumberValue()` | 数值 | 离子强度 |
| 6 | （空） | — | — | 分隔占位，**必须为空** |

三个必须知道的细节：

1. **解析是"每 5 个非空单元格一组"**。`parseIon` 连续调 5 次 `iterator.next()`，
   不校验列号。第 6 列一旦有值，后面全部错位。
2. **样品名取自第一行数据的第 1 列**，不是表头文字。表头行被跳过，
   所以 `sampleNames` 实际是每块首个数据行的 `Sample(No)`。
3. **`RT&m/z` 不会被重算**，程序直接读第 3 列。`RT×1000 + m/z` 是上游约定。

### 3.3 派生键（全部是字符串拼出来的"伪数值"）

```java
noMz    = truncate(new BigDecimal(ion.no + ion.mz.toString()))      // 例题 191.0191 → "237191.0191"
rtNoMz  = new BigDecimal(ion.rt.toString() + ion.no + ion.mz.toString())  // "2" + "237" + "191.0191"
```

| 派生键 | 构造 | 用途 | 硬约束 |
| --- | --- | --- | --- |
| `noMz` | `no` 与 `mz` 字符串拼接 | 样品内唯一化、打分维度一 | `no` 不能带小数点 |
| `rtNoMz` | `rt` + `no` + `mz` 字符串拼接 | 同位素查找、差异表溯源 | **`rt` 必须是整数**，否则 `"2.0"+"237"` 直接 `NumberFormatException` |
| `rtMz` | 直接读第 3 列 | 主匹配键 | 上游已 8 位小数 |

> 这是原版最"脆"的设计：它是靠"RT 是整数 + No 是整数"才成立的。
> 数据里 RT 一旦出现 2.5 这类值，原版直接崩，R 版也会给出明确报错。

### 3.4 示例数据规模

| 分组 | 样品数 | 输入行数（不含表头） | 读出的离子总数 |
| --- | --- | --- | --- |
| A组 | 10 | 35,426 | **354,260** |
| B组 | 10 | 32,740 | **327,400** |

### 3.5 参数（28 项）

原版存在 `~/DMetFinder.app.cfg.json`，首次运行用 `Config` 类里的默认值；R 版对应
`R/config.R::default_config`，界面 `ui/dmetfinder_ui.R` 暴露其中最常改的 14 项。

**匹配与阈值**

| 参数 | 默认 | 作用 |
| --- | --- | --- |
| `ErrorRange` | `0.002` | 组内 RT&m/z 匹配容差 |
| `ErrorRangeInGroups` | `0.003` | **跨组**匹配容差（比组内宽） |
| `p50IonPercent` | `0.5` | 50% 阈值，判定式 `(int)(0.5×n)` **截断** |
| `p80IonPercent` | `0.8` | 80% 阈值，判定式 `(int)ceil(0.8×n)` **向上取整** |
| `FloatCount` | `7` | 打分类数值的小数位 |
| `NullCellValue` | `0` | `valuesMayNA` 系列写空值用的替代值 |
| `mergeRows` | `false` | 保留字段，当前流程未使用 |

> 10 个样品时：50% → 5 个，80% → 8 个。两个阈值一个截断一个向上取整，**并不对称**。

**同位素质量差**

| 参数 | 默认 |
| --- | --- |
| `m1` / `m2` / `m3` | `1.00335` / `2.0067` / `3.01005` |

**两套打分表（互相独立，默认值相同）**

| 用途 | 参数组 |
| --- | --- |
| 全离子（`IonScore`，21 列） | `intensityRange/Value`、`relativeIntensitySplit`、`relativeIntensityRange1/Value1`、`relativeIntensityRange2/Value2`、`countRange/Value` |
| 50% 离子（`P50Score`，13 列） | `p50IntensityRange/Value`、`p50RelativeIntensitySplit`、`p50RelativeIntensityRange1/Value1`、`p50RelativeIntensityRange2/Value2`、`p50CountRange/Value` |

默认区间：

```
强度     (0,5000,10k,50k,100k,500k,1M]  →  1,2,5,6,8,9,10
计数     [1,3,5,10]                     →  10,3,2,1
相对强度 ≤5% 用表1 (0,1,2,3,4,5) → 0.5,1,2,3,5,10
         >5% 用表2 (0,2,3,4,5)   → 1,2,3,5,10
```

打分映射是**倒序扫描**：从高分往低分比，命中即取，所以区间端点落在哪一侧很关键。

### 3.6 入口

| 版本 | 入口 |
| --- | --- |
| 原版 | `DMetFinder.exe`（`jre/` 必须同目录，exe4j 启动 `corvida.desktop.MainFrame`） |
| R CLI | `Rscript -e "shiny::runApp('app.R', port=3838)"`，或 `启动DMetFinder.bat` |
| R 交互 | 浏览器打开后：MSGeter / DMetFinder / Peak Quality 三个 tab |

---

## 4. 输出

### 4.1 总表：9 个文件 / 19 个 sheet

| # | 文件名（`<组>` = A组/B组） | sheet | 行数（demo） | 列数 | 表头行 |
| --- | --- | --- | --- | --- | --- |
| 1 | `<组>-筛选50%和80%离子.xlsx` | `<组>离子分布初筛` | 354,260 | 17 | 1 |
| | | `<组>50%分布频率离子` | 20,910 | 6 | 1 |
| | | `<组>80%分布频率离子` | 13,375 | 6 | 1 |
| 2 | `<组>-离子打分.xlsx` | `<组>50%离子单独打分` | 20,910 | 13 | 1 |
| | | `<组>总离子平均得分` | 354,260 | 21 | 2 |
| | | `<组>离子打分汇总` | 20,910 | 6 | 1 |
| 3 | `<组>-同位素离子查找.xlsx` | `<组>同位素离子查找` | 354,260 | 26 | 2 |
| 4 | `<组>-80%离子与<另一组>总离子比对分析.xlsx` | `<组>80%离子和<另一组>比对` | 13,375 / 12,392 | 21 | 2 |
| 5 | `A组-B组差异离子筛选汇总.xlsx` | `A组和B组差异离子(A组比B组)` | 13,375 | 41 | 2 |
| | | `B组和A组差异离子(B组比A组)` | 12,392 | 41 | 2 |

> 注意第 5 个：**两个方向共用一个文件**，文件名只写 A→B。B 组浏览器排序见 4.6。

### 4.2 文件 1：筛选 50% / 80%

**sheet `<组>离子分布初筛`** —— 全离子明细，含每样品强度
`sample | RT | RT&m/z | m/z | - | <样品1..n 强度> | 计数 | 平均强度`

**sheet `<组>50%分布频率离子` / `<组>80%分布频率离子`** —— 只有 6 列
`Sample (No) | RT | RT&m/z | m/z | 平均离子强度 | 离子计数`

### 4.3 文件 2：离子打分

**sheet `<组>50%离子单独打分`（13 列）**
`sample | RT | RT&m/z | m/z | 平均离子强度 | 查找(离子唯一化处理) | 计数 | 重复离子平均强度 | 单个离子平均强度/重复离子平均强度 | 强度打分 | 计数打分 | 相对离子强度打分 | 总得分`

**sheet `<组>总离子平均得分`（21 列，2 行表头）**
第一行是分组标题 + 一句原版注释"样品编号必须大于2，因为m/z为100-1500…"。
第二行分四段：

| 段 | 列 |
| --- | --- |
| 基础 | `sample (No) | RT | RT&m/z | No&m/z | m/z | Intensity` |
| 单样品维度 | `查找(单个样品内所有时间段离子唯一化) | 计数(单个样品) | 重复离子平均强度 | 单个离子平均强度/重复离子平均强度 | 强度打分 | 计数打分 | 相对离子强度 | 总得分` |
| 跨样品维度 | `查找（每个时间段所有样品离子唯一化） | 计数 | 得分总和 | 平均得分 | 得分差` |

**sheet `<组>离子打分汇总`（6 列）**
`sample | RT | RT&m/z | m/z | 单独得分 | 平均得分`

### 4.4 文件 3：同位素查找（26 列，2 行表头）

六段，段间用空列 `-` 分隔：

| 段 | 列 |
| --- | --- |
| 基础 6 | `sample (No) | RT | RT&m/z | RT&No&m/z | m/z | Intensity` |
| 理论 3 | `RT&No&(M+1) | (M+2) | (M+3)` |
| 实测 3 | `RT&No&(M+1) | (M+2) | (M+3)`（找到的离子键） |
| 强度 3 | `M+1 | M+2 | M+3` |
| 比值 3 | `M/M+1 | M+1/M+2 | M+2/M+3` |
| 判定 3 | `M+1 | M+2 | M+3`（0/1，是否判为同位素峰） |

判定规则：`1 ≤ 强度比 ≤ 50`（m/z ≤ 1000）或 `0.5 ≤ 比值 ≤ 5`（m/z > 1000），
且 M+1→M+2、M+2→M+3 需逐级为 1。

### 4.5 文件 4：跨组比对（21 列，2 行表头）

`sample | RT | RT&m/z | m/z | 平均离子强度 | 离子计数 | <另组>RT&m/z | <另组>平均离子强度 | <另组>离子计数 | A组/B组 | - | <另组 10 个样品强度>`

- 主键：本组 80% 离子的 `rtMz`，在另一组**全部离子**里按 `ErrorRangeInGroups (0.003)` 找
- 匹配不到时，`<另组>RT&m/z / 平均离子强度 / 离子计数` 写 **0**（不是空白）
- `A组/B组` = `divideD(本组平均强度, 另组平均强度)`，HALF_UP 保留 7 位

### 4.6 文件 5：差异离子筛选汇总（41 列，2 行表头，两个 sheet）

两个 sheet 结构完全一致，只是左右互换：

| 段 | 列 |
| --- | --- |
| 基础 7 | `sample (No) | RT | RT&m/z | RT&No&m/z | m/z | 平均离子强度 | 离子计数` |
| 另一组 5 | `<另组>RT&m/Z | <另组>平均离子强度 | <另组>离子计数 | A组/B组 | <另组>m/z` |
| 打分 4 | `单独得分 | 平均得分 | P值 | M+1 | M+2 | M+3` |
| 本组强度 | `<本组 10 个样品强度>` |
| 另组强度 | `<另组 10 个样品强度>` |

排序：先按另一组"是否匹配到"（匹配到在前）→ 再按 `bCount` 降序 → 再按 `count` 降序。

### 4.7 空值与表头约定（写代码必须知道）

| 语义 | 原版方法 | 表现 |
| --- | --- | --- |
| 保留空 | `values()` | 单元格空白 |
| 空 → 0 | `valuesMayNA()` / `to01MayNA()` | 写 `NullCellValue`，默认整数 `0` |
| 空 → 0.0 | `valuesOr0()` | 写 `0.0`（差异表的样品强度列） |

- 两行表头的表：行 1 是分组标题，行 2 才是列名；一行表头的表：行 1 直接是列名。
- 样品编号列写的是**数值**（`237.0`），不是字符串 `"237"`。

### 4.8 原版自带的小瑕疵（R 版按原样复刻，不要"顺手修好"）

1. **两个比对文件的第 1 行标题完全相同**，都写死 `A组80%离子` + `B组离子强度`，
   所以 `B组-80%离子与A组总离子比对分析.xlsx` 的标题栏是错的。
2. **同位素表的第 1 行第 3 列写死 `A组总离子`**，B 组文件里也跟着错。
3. **P 值列是文本**，形如 `"==TTEST(...)"`——EasyExcel 把前导 `=` 重复了一次，
   导致它不是公式而是字符串。R 版写的是可直接计算的公式。
4. **表头里混着注释**："样品编号必须大于2，因为m/z为100-1500…" 直接占了一个单元格。
5. **差异汇总只生成一个文件**（A→B 命名），两个方向塞在两个 sheet 里。

这些都属于"输出契约"的一部分：下游脚本若按 B 组文件标题栏做判断会出错。

---

## 5. 数据流总图

```
groupA.xlsx ─┐
             ├─ 读取（每 6 列一样品，跳过表头）
groupB.xlsx ─┘
                 ↓
       ┌─────────┴─────────┐
       │  按样品 × 离子      │  354,260 / 327,400
       │  强度矩阵          │  count / avg
       └─────────┬─────────┘
                 ↓  rtMz 窗口 (0.002) + 原始下标最小者
       ┌─────────┴──────────┐
       │ count ≥ 5  → 50%   │  20,910 / 21,705
       │ count ≥ 8  → 80%   │  13,375 / 12,392
       │ 各自再按 rtMz 去重 │
       └─────────┬──────────┘
                 ↓
   ┌─────────────┼──────────────┬───────────────┐
   ↓             ↓              ↓               ↓
打分(两套)    同位素 M+1/2/3   跨组比对(0.003)   差异汇总
   │             │              │               │
   ↓             ↓              ↓               ↓
图2 (3 sheet)  图3 (1 sheet)   图4 (2 文件)    图5 (2 sheet)
                 └──────────────┴───────────────┘
                          ↓
              9 个 xlsx，约 150 MB
```

---

## 6. 要改动时看哪里

| 需求 | 改哪里 |
| --- | --- |
| 换容差 / 打分区间 / 同位素质量差 | `R/config.R`（默认）+ `ui/dmetfinder_ui.R`（界面） |
| 改输出列或表头 | `R/dmetfinder_functions.R` 第 9 层 `.dmf_sheet_*` |
| 改匹配或去重逻辑 | 第 2 层 `dmf_window_bounds` / `dmf_argmin_in_window` |
| 支持别的输入格式 | 第 3 层 `dmf_read_samples`（保持 6 列块语义） |
| 加新的输出表 | 9 层加 `dmf_sheet()`，11 层 `dmetfinder_run()` 里追加写盘 |
| 界面/进度/下载 | `server/dmetfinder_server.R` + `ui/dmetfinder_ui.R` |
| 回归验证 | `.workbuddy/tests/compare_golden.py`（对原版 9 个文件逐格比对） |

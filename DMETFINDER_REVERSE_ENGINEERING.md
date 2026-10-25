# DMetFinder.exe 逆向工程报告与 R Shiny 重写方案

> 目标文件：`data_for_paper/DMetFinder1.0.3/DMetFinder.exe`（22,198,272 字节，2021-06-26）
> 逆向日期：2026-10-19
> 状态：**逆向已完成，原版算法已可 headless 运行并产出黄金基准**

---

## 0. 结论速览

| 问题 | 答案 |
|---|---|
| 能不能逆向 | **能，且已完成。** 拿到了全部业务源码（34 个 Java 文件 / 3,239 行） |
| 程序是什么 | exe4j 打包的 Java SE 桌面程序（Swing），不是原生 Win32 |
| 业务代码有多少 | **只有 41 个 class**，其余 10,909 个 class 全是第三方库（EasyExcel/POI/ehcache/xmlbeans） |
| 能不能跑起来 | 能。已写 headless runner，**20 秒**跑完 demo 数据，产出 **9 个 xlsx / 150 MB** 原版输出 |
| 现有 R 实现是否等价 | **不等价。** 现有 `R/dmetfinder_functions.R` 是**简化近似版**：5 处 P0 级算法偏差，实测 80% 离子表行数是原版的 **9 倍** |
| 重写可行性 | 高。算法已完全透明，且有黄金基准可做逐单元格回归 |

---

## 1. 逆向方法与证据链

### 1.1 PE 层：先确认它不是原生程序

```
PE32+ (0x8664 x64)，6 个节，TimeDateStamp 0x6054E987 = 2021-03-19
.text   raw 0x31600   .rdata raw 0xca00    .data  raw 0x2400
.pdata  raw 0x2200    .rsrc  raw 0xa00     .reloc raw 0x800
```

所有节区 raw 加起来只有 **276,992 字节**，而文件有 22 MB —— 说明 **99% 的内容是 PE 之后的附加数据（overlay）**。

### 1.2 识别打包器：exe4j

overlay 起始 `0x43C00` 是一棵**明文**配置树，可直接读出：

```
0x43C8A  "corvida.desktop.MainFrame"        ← 主类
0x43E25  "exe4jlib.jar;i4jdel.exe;corvida.desktop.jar"   ← jar 清单
0x43CD5  ".\jre"  "JAVA_HOME"  "EJDK_HOME"   ← JRE 搜索顺序
         "error.log"  "output.log"  "DMetFinder"
```

结论：exe4j launcher，把 jar 打进 exe，运行时从同目录 `jre/` 找 JRE。

### 1.3 破解 overlay 混淆：单字节 XOR 0x88

overlay 数据段熵 7.90–8.00（接近随机）。但配置区后面的"不可打印"内容里出现规律性重复：

```
eb e7 e5 a7 ed f0 ed bc e2 a7   ← 期望是 "com.exe4j."
```

逐字节推导：

| 密文 | 明文 | XOR |
|---|---|---|
| `eb` | `c` (0x63) | 0x88 |
| `a7` | `/` (0x2f) | 0x88 |
| `a8` | 空格 (0x20) | 0x88 |

**密钥 = 0x88**（单字节 XOR，作用于整个数据段）。解密后立刻出现 15,682 个 `PK\x03\x04`。

### 1.4 定位并提取两个 jar

用 EOCD 反推（`jar_start = 第一个 local header 绝对位置 − central 目录里记录的 header_offset`）：

| 文件 | 绝对区间 | 大小 | 条目 | 内容 |
|---|---|---|---|---|
| jar0 | `0x44B88 – 0x542BA` | 63,282 | 54 | `com.exe4j.runtime.*` 运行时库 |
| jar1 | `0x44B88 – 0x152B643` | 21,916,347 | 15,628 | **corvida.desktop.jar 主程序** |

两个 jar 的 `zipfile.testzip()` 全部通过，CRC 完好。

### 1.5 反编译

- 工具：**CFR 0.152**（`java -jar cfr.jar jar1.jar --jarfilter "corvida\..*"`）
- 结果：**34 个 .java / 3,239 行**，覆盖 `corvida.core.*` 与 `corvida.desktop.*` 全部逻辑
- 中文常量：class 文件常量池存的是 UTF-8 字节，CFR 按默认编码解码会乱码；用 `.workbuddy/reverse/extract_cn.py` 直接解析常量池并按 UTF-8→GBK 兜底解码，**恢复出全部中文表头、sheet 名、文件名模板**

产物已归档：

```
.workbuddy/reverse/
├── jar0.jar                 exe4j 运行时（63 KB）
├── jar1.jar                 主程序（21.9 MB，含全部依赖）
├── decompiled/corvida/**    34 个反编译 .java
├── strings_zh.txt           全部中文常量（表头/sheet/文件名/UI 文案）
├── RunDMetFinder.java       headless runner（可直接调用原版算法）
└── extract_cn.py            常量池中文提取器
```

---

## 2. 程序结构

```
DMetFinder.exe (exe4j launcher)
        │  加载
        ├── jre/                    OpenJDK 1.8.0-25 (microsoft)
        └── 内存中挂载
            ├── exe4jlib.jar        启动器运行时
            └── corvida.desktop.jar 21.9 MB / 15,628 条目
                    ├── corvida/**  ← 业务代码，41 个 class（0.37%）
                    ├── com/alibaba/excel + org/apache/poi  ← EasyExcel 读写
                    ├── org/ehcache, org/terracotta         ← 缓存
                    ├── org/openxmlformats, schemaorg       ← OOXML schema
                    └── assets/, images/                    ← 界面素材
```

启动链：`corvida.desktop.MainFrame` → 读 `~/DMetFinder.app.ini`（路径记忆）与 `~/DMetFinder.app.cfg.json`（算法参数）→ 用户点"开始计算" → `corvida.core.calc.IonCalculator.Process(A, B, out, config)`。

---

## 3. 类职责地图

### 3.1 计算核心

| 类 | 行数 | 职责 |
|---|---|---|
| `core.calc.IonCalculator` | 728 | **全部流程编排**：读入→建矩阵→50/80% 筛选→打分→同位素→跨组比对→mergeDiff→写 xlsx |
| `core.collection.impl.IonsManager2` | 184 | 离子集合；四种排序键的懒加载排序数组；二分查找入口；**唯一化 distinctIons** |
| `core.collection.Helper` | 206 | 泛型二分查找（区间查找 `binarySearch` / 等值查找）、排序索引映射 |
| `core.utils.CalcTools` | 18 | `Score(v, range, scores)` —— **唯一的分段打分函数** |
| `core.utils.BigDecimalHelper` | 206 | `truncate`（8 位截断）、`divideD`（7 位 HALF_UP）、`inEqual`、各类落表辅助 |
| `core.utils.TTest` | 69 | 独立样本 t 统计量（**注意：返回 t 值，不是 p 值**） |
| `core.utils.Stds` + 4 个 `*PickerSetter` | 各 25 | 四种键提取器：`Mz` / `NoMz` / `RtMz` / `RtNoMz` |
| `core.utils.Mutil` | 45 | 用 BigDecimal 包一层来做 double 四则运算 |

### 3.2 模型（同时承担 Excel 表头定义）

| 类 | 输出列数 | 说明 |
|---|---|---|
| `model.Ion` | — | `no/rt/rtMz/noMz/mz/rtNoMz/intensity/averageIntensity/count/matrixRow` |
| `model.MatrixRow` | — | `Map<no, Ion>` + 去重计数 + 强度累加均值 |
| `model.Isotope` | 25 | 同位素查找结果，表头 2 行 |
| `model.P50Score` | 13 | 50% 离子单独打分 |
| `model.IonScore` | 20 | 全离子平均得分（noMz 维度 + rtMz 维度） |
| `model.MergedScore` | — | P50Score + IonScore 的合并视图 |
| `model.P80CompareInfo` / `IonDiff` | — | 跨组比对 / 差异汇总行 |

### 3.3 IO 与界面

| 类 | 职责 |
|---|---|
| `io.AnalysisIonListener` | **输入解析**：EasyExcel 流式读，按 5 个单元格切一个 Ion |
| `io.IoHelper` | 8 线程写 xlsx；`waitAllWriteThreads()` |
| `desktop.MainFrame` | A/B/输出目录 + 日志框 + 配置按钮，800×600 |
| `desktop.ConfigDialog` | 26 个参数输入框 + 导入/导出/默认值，仅校验"区间数与得分值数相等" |
| `desktop.AppConfig` | `~/DMetFinder.app.ini` 记录最近路径与最近配置列表 |
| `core.Config` | 全部算法参数（`~/DMetFinder.app.cfg.json`） |

---

## 4. 算法规格（重写蓝图）

### 4.1 输入契约

一个 xlsx，无表头约定，**每个样本占 6 列**：

| 列偏移 | 字段 | 取法 |
|---|---|---|
| +0 | `Sample (No)` | **字符串**（不是数字！） |
| +1 | `RT` | `getNumberValue()` → BigDecimal，原样保留 |
| +2 | `RT&m/z` | BigDecimal → `truncate` |
| +3 | `m/z` | BigDecimal → `truncate` |
| +4 | `Intensity` | BigDecimal |
| +5 | 空列 | 跳过 |

`truncate(x) = (x + 1e-10).setScale(8, RoundingMode.DOWN)` —— **加 1e-10 后向下截断到 8 位小数**，用于吃掉 Excel 浮点尾差。

样本数量 = 首行有值单元格数 / 5。首个样本的 `no` 序列即样本 ID 列表。

### 4.2 四种排序键（最容易踩坑的地方）

原版为每个 Ion 构造 4 个键，全部是 `BigDecimal`，但 **`noMz` 和 `rtNoMz` 是字符串拼接出来的伪数值**：

```java
noMz   = truncate( new BigDecimal( no + mz.toString() ) )
rtNoMz = new BigDecimal( rt.toString() + no + mz.toString() )
```

实例如 `no="237", rt=2, mz=191.01910000`：

```
noMz   = "237" + "191.01910000"  = 237191.0191
rtNoMz = "2" + "237" + "191.01910000" = 2237191.0191
```

`IonScore` 的表头注释写得很直白：

> 样品编号必须大于2，因为 m/z 为 100-1500，要避免 sample&m/z 不会与 m/z 重复

也就是说：这是作者为了"用一个数值字段同时编码样本+质量"而做的 hack，**样本编号 < 3 会产生碰撞**。重写时必须原样复现（包括这个限制）。

### 4.3 阶段 1：强度矩阵

```
allIons = 按样本顺序拼接的全部 Ion（N样本 × N行）
for each ion in allIons:
    near = allIons 中 |rtMz − ion.rtMz| < ErrorRange(0.002) 的全部离子
    row  = MatrixRow()
    for n in near: row.add(n)          # 按 no 去重，同 no 只加一次
    ion.matrixRow       = row.row       # Map<no, Ion>
    ion.count           = row.count     # 不同样本编号的个数
    ion.averageIntensity= row.intensitySum / row.count
```

**关键口径**（现有 R 实现与此不同）：

- `count` 数的是**匹配到的不同样本编号个数**，不是"强度 > 0 的样本数"。某样本该离子强度为 0，仍然计入。
- `averageIntensity` 是**全部匹配离子强度的算术平均，0 也参与平均**。

### 4.4 阶段 2：50% / 80% 筛选

```
minCount80 = (int) Math.ceil(p80IonPercent(0.8) * 样本数)
minCount50 = (int) (p50IonPercent(0.5) * 样本数)          ← 注意：截断，不是 ceil
p80Ions = { ion | ion.count >= minCount80 }
p50Ions = { ion | ion.count >= minCount50 }
```

然后各自做 unique 化（`distinctIons`）：

```
distinctIons(ions):
    ions = sortByCount(ions)                 # count 降序
    loop 最多 2 轮:
        for ion in ions:
            rep = 二分查找第一个 |rtMz − ion.rtMz| < 0.002 的离子
            若 rep 的索引已收录则跳过，否则收录 ion
        若数量不再变化则停
```

即"同一保留时间内、同一质量簇只留 count 最高的那一条"。

### 4.5 阶段 3：两套打分

**打分函数（唯一）**：

```
Score(v, range[], scores[]) :
    for i from len-1 down to 0:
        if v >= range[i]: return scores[i]
    return 0
```

等价于区间 `[range[i], range[i+1]) → scores[i]`，末区间 `[range[last], ∞) → scores[last]`，`v < range[0]` 得 0。

**默认参数表**（`Config`）：

| 用途 | range | value |
|---|---|---|
| 强度（全部/50% 各一套，值相同） | `0, 5000, 10000, 50000, 100000, 500000, 1000000` | `1,2,5,6,8,9,10` |
| 计数 | `1, 3, 5, 10` | `10, 3, 2, 1` |
| 相对强度（低计数） | `0, 2, 3, 4, 5` | `1,2,3,5,10` |
| 相对强度（高计数） | `0, 1, 2, 3, 4, 5` | `0.5,1,2,3,5,10` |
| 切换阈值 `relativeIntensitySplit` | 5 | — |

**A. 50% 离子单独打分（`P50Score`，13 列）**

```
std      = findIon(ion.mz, Stds.Mz, 0.002)      # 取区间内第一个
group    = 所有 std 相同的 ion
stdCount = |group|
stdAvg   = mean(group.intensity 的 averageIntensity)
relative = ion.averageIntensity / stdAvg        ← 比值，不是百分比
scoreI   = Score(averageIntensity, p50IntensityRange, p50IntensityValue)
scoreC   = Score(stdCount,         p50CountRange,     p50CountValue)
scoreR   = if stdCount >= 5 then Score(relative, p50RelRange1, p50RelValue1)
                          else Score(relative, p50RelRange2, p50RelValue2)
total    = scoreI * scoreC * scoreR
```

**B. 全离子平均得分（`IonScore`，20 列，两个维度）**

noMz 维度（单个样本内唯一化）：

```
stdNoMz = findIon(ion.noMz, Stds.NoMz, 0.002)   # 取区间内第一个
group   = 所有 stdNoMz 相同的 ion
noMzIonCount / noMzAverageIntensity / noMzRelativeIntensity 同上口径
noMzTotalScore = 三项得分相乘
```

rtMz 维度（跨样本累加）：

```
stdRtMz        = findIon(ion.rtMz, Stds.RtMz, 0.002)
rtMzCount      = 该 rtMz 簇内 ion 数
rtMzTotalScore = 簇内所有 ion 的 noMzTotalScore 之和
rtMzAverageScore = rtMzTotalScore / rtMzCount
末列「得分差」    = noMzTotalScore − rtMzAverageScore
```

**C. 合并视图（`MergedScore`）** = 每个 50% 离子挂上它自己的 `P50Score` 与 `IonScore`。

### 4.6 阶段 4：同位素

```
m1Calc = rtNoMz + 1.00335      m2Calc = rtNoMz + 2.0067     m3Calc = rtNoMz + 3.01005
m1Ion  = findIon(m1Calc, Stds.RtNoMz, ErrorRange)           # ±0.002
… 记录命中的 rtNoMz 与 intensity
m_m1   = intensity / m1Intensity      m1_m2 = m1Int / m2Int      m2_m3 = m2Int / m3Int

判定（三态 Boolean，null 表示"信息不足"）：
E = mz
X(M+1) = (100 ≤ E ≤ 1000 且 1 ≤ m_m1 ≤ 50) 或 (E ≥ 1000 且 0.5 ≤ m_m1 ≤ 5)
Y(M+2) = X 为 true 且 m1_m2 > 1 且 [同样两段区间，用 m1_m2]
Z(M+3) = Y 为 true 且 m2_m3 > 1 且 [同样两段区间，用 m2_m3]
```

漏写/写错都会让"是否为同位素峰"这一列失真。

### 4.7 阶段 5：跨组比对

```
A.p80CompareWith(B):
    在 B 的全离子（按 count 降序）里二分查找 |B.rtMz − A.rtMz| < ErrorRangeInGroups(0.003)
    命中 → 取匹配列表第一个（b 最高 count 那个）
           bRtMz / bIntensityAverage / bCount / a_b = A.avg / B.avg
           bIntensityRow = { 样本no → 强度 }
    未命中 → 三项均 null，落表填 NullCellValue(0)
```

`mergeDiff(A, B)` 生成差异汇总，**排序规则**（两次稳定排序，第二次为主）：

1. 先按 `a.count` 降序
2. 再按 `bCount` 降序，`b == null` 的排最后

### 4.8 阶段 6：输出

9 个 xlsx、中文文件名、多 sheet、多行表头、缺失填 0、浮点 7 位小数 HALF_UP：

| 文件名 | sheet |
|---|---|
| `A组-筛选50%和80%离子.xlsx` | `A组离子分布初筛` / `A组50%分布频率离子` / `A组80%分布频率离子` |
| `A组-离子打分.xlsx` | `A组50%离子单独打分` / `A组总离子平均得分` / `A组离子打分汇总` |
| `A组-同位素离子查找.xlsx` | `A组同位素离子查找` |
| `A组-80%离子与B组总离子比对分析.xlsx` | `A组80%离子和B组比对` |
| `A组-B组差异离子筛选汇总.xlsx` | `A组和B组差异离子(A组比B组)` / `B组和A组差异离子(B组比A组)` |

B 组同构（双向各一份）。

差异汇总表的 P 值列写的是 **Excel 公式**，由 Excel 计算：

```
=TTEST(U{r}:AD{r}, AF{r}:AO{r}, 2, 2)
        ↑A组强度列         ↑B组强度列
```

列位置是硬编码的（A 组强度固定落在第 21–30 列，B 组固定第 32–41 列），所以**列顺序不能改**。

---

## 5. 现有 R 实现 vs 原版：偏差清单

### 5.1 实测对比（`demo_data/`，10 样本 × 35,426 行）

同一份输入，原版（headless runner）与现有 R 实现各跑一次：

| 指标 | 原版 Java | 现有 R | 结论 |
|---|---|---|---|
| 识别样本数 | 10 | 10 | 一致 |
| 每样例行数 | 35,426 | 35,426 | 一致 |
| 全离子矩阵行数 | 354,260 | 354,260 | 一致 |
| **80% 离子数** | **13,375** | **120,221** | **差 9.0 倍** |
| **50% 离子数** | **20,910** | **166,162** | **差 7.9 倍** |

根因可精确定位：

```
merged 中 count >= 8 的离子 = 80,183(+9) + 22,147(+8) + 17,891(+8) = 120,221   ← 与 R 输出完全吻合
原版再做 distinctIons() 去重 → 13,375                                        ← 120,221 / 13,375 ≈ 9.0
```

即 R 版**只做了阈值筛选、完全没做 unique 化**，10 个样本各自贡献的同一离子被原样重复输出。
这不是精度问题，是**输出规模差一个数量级**，下游任何统计都会被放大。

### 5.2 逐项偏差清单

对照 `R/dmetfinder_functions.R`（423 行）与反编译源码，按严重度分级。
**P0 = 会导致结果数值不同；P1 = 会导致部分列/部分行不同；P2 = 仅格式差异。**

| # | 位置 | 原版 Java | 现有 R | 级别 |
|---|---|---|---|---|
| 1 | 键构造 | 4 个键 `rtMz/mz/noMz/rtNoMz`，后两个是字符串拼接伪数值 | 只有 `RT_mz`/`mz`，**完全缺失 `noMz` / `rtNoMz`** | **P0** |
| 2 | 矩阵口径 | `count` = 匹配到的不同样本编号数（**含强度 0**）；`avg` = 含 0 的算术平均 | `sum(!is.na & >0)` 计数、只平均 `>0` | **P0** |
| 3 | 打分维度 | 两套打分 + noMz/rtMz 双维度，共 20 列 | 只有一套 5 列（`int_score/count_score/rel_score/total`） | **P0** |
| 4 | 相对强度 | `average / stdAverage`（比值，可 <1 或 >1） | `avg / max(avg) * 100`（百分比，0–100） | **P0** |
| 5 | 分组代表值 | `findIon(key, Std, 0.002)` 取区间内**第一个**离子作代表，再按代表值分组 | `split(x, merged$mz)` **按精确 m/z 值**分组，无容差聚类 | **P1** |
| 6 | 相对强度区间切换 | `stdIonCount >= 5` 时用 `RelRange1/Value1`，否则 `RelRange2/Value2` | 固定用 `relativeIntensityRange1/Value1` | **P1** |
| 7 | 唯一化 | `distinctIons` 最多两轮、按 rtMz ±0.002 去重 | 无 | **P0**（实测 9 倍行数差） |
| 8 | 同位素判定 | mz 区间 × 强度比区间 → 三态 Boolean | 仅 `actual_m1 > 0` 存在性判断 | **P1** |
| 9 | 跨组比对误差 | `ErrorRangeInGroups = 0.003`，取匹配列表第一个 | 传入 `error_range`（实际传 0.002），只取最近一个 | **P1** |
| 10 | 50% 阈值 | `(int)(0.5 * n)` 向下取整 | `ceiling(0.5 * n)` 向上取整 | P2 |
| 11 | 差异表排序 | `count` desc → `bCount` desc（空值最后） | 未排序 | P2 |
| 12 | P 值 | 写 Excel `=TTEST(...)` 公式 | 不产出 | P2 |
| 13 | 缺失值 | `NullCellValue = 0` | `NA` | P2 |
| 14 | 输出结构 | 9 个中文名 xlsx、多 sheet、双行表头 | 9 个英文名 xlsx、单 sheet、单行表头 | P2 |
| 15 | 输出列名 | 全中文（已从常量池完整恢复，见 `strings_zh.txt`） | 英文 | P2 |
| 16 | 死配置 | `Config.mergeRows` / `Config.filters` **定义但从未使用** | `default_config$mergeRows` 同样未使用 | 一致 |

> 注：第 16 项说明 R 版当年确实是对着原版抄的，连"没用的字段"都抄了 —— 但也说明抄的是**早期/简化版本**，不是 1.0.3 这一版的完整逻辑。

---

## 6. R Shiny 重写方案

### 6.1 目标形态

保持现有 Shiny 外壳（`ui/main_ui.R` + `server/main_server.R` 的 navbarPage 双 tab），把 `R/dmetfinder_functions.R` 那 7 个函数替换为**忠实移植层**，输出格式与原版 xlsx 一致。

建议目录：

```
R/dmetfinder/
├── config.R      Config 镜像：p50* 与无前缀两套参数 + 校验（区间数 == 得分值数）
├── keys.R        pq_truncate() / key_rtMz / key_mz / key_noMz / key_rtNoMz
├── read.R        流式读 xlsx（每样本 6 列切 5 字段），返回 long data.table
├── matrix.R      build_intensity_matrix()：按 rtMz ±0.002 分簇，no 去重
├── filter.R      filter_ions(minCount) + distinct_ions() 两轮唯一化
├── score.R       score_value() + p50_scores() + ion_scores()
├── isotope.R     find_isotopes() + isotope_flags()
├── compare.R     compare_with() + merge_diff()（含双键稳定排序）
├── export.R      9 个 xlsx：中文名/多 sheet/双表头/TTEST 公式/7 位小数
└── run.R         run_dmetfinder(A, B, out, config)  ← 对应 IonCalculator.Process
```

### 6.2 数据结构映射

| Java | R 建议 |
|---|---|
| `Ion` | `data.table` 一行 + `list` 列存 `matrixRow` |
| `MatrixRow` | `data.table(no, intensity)` 聚合 + `count`/`avg` |
| `IonsManager2` 的 4 个排序数组 | 4 个 `setkey()` 视图（或 `order()` 索引向量） |
| `Helper.binarySearch(区间)` | `findInterval()` + 边界裁剪（`fixOffset = 1e-9` 必须保留） |
| `BigDecimal.divideD` | `round(x, 7)` 不够 —— Java 是 **HALF_UP**，R 的 `round()` 是 banker's rounding，必须用 `round_half_up()` |

⚠️ **精度陷阱**：`BigDecimalHelper.divideD` 用 `RoundingMode.HALF_UP` 保留 7 位。R 的 `round(0.00000005, 7)` 与 Java 结果不同。移植时必须自己实现 HALF_UP（`floor(x*1e7 + 0.5)/1e7`，负数需谨慎）。

⚠️ **`count` 语义陷阱**：`MatrixRow.add` 用 `Map<no, Ion>` 去重，同一 `no` 只计一次。若同一 no 在一个 rtMz 簇里出现多条（理论上不会，因为 no 是样本编号，一个样本一个 rtMz 簇里可能有多条相近离子），Java 只取第一条。重写必须用 `!duplicated(no)` 而不是 `length()`。

### 6.3 性能预期

原版 demo 数据（10 样本 × 35,426 行 = 354,260 ion）：

- Java 实测：**读入+计算+写 9 个 xlsx 共约 20 秒**（读写多线程，写盘占大头）
- R 若用 `data.table` 的等值连接 + `findInterval`，计算部分可在 10 秒内；瓶颈在 `openxlsx` 写 150 MB（约 2–4 分钟）

建议：
- 计算层用 `data.table` + `setkey`，避免 `apply` 逐行
- 导出层用 `openxlsx::writeData` 批量写 + `writeDataTable` 关闭，或改用 `writexl`（更快但无法设置样式）
- 353 万单元格的 20 列大表，考虑加"仅导出差异离子"选项

### 6.4 回归验证策略（关键）

已生成黄金基准，可直接逐单元格比对：

```
C:/Users/Shenshulin/.workbuddy/tmp/dmf_reverse/golden/
├── A组-筛选50%和80%离子.xlsx         A组离子 354,260 / 50% 20,910 / 80% 13,375
├── A组-离子打分.xlsx                 50%打分 20,910 / 全离子 354,260 / 汇总 20,910
├── A组-同位素离子查找.xlsx            354,260
├── A组-80%离子与B组总离子比对分析.xlsx  13,375
└── A组-B组差异离子筛选汇总.xlsx        A比B 13,375 / B比A 12,393
```

验证分三级：

1. **行数对齐**：每 sheet 行数完全相同（最容易先做，能暴露 90% 的口径差异）
2. **键集合对齐**：`(no, rtMz)` 集合完全一致
3. **数值对齐**：`averageIntensity` / `count` / 各项得分 / `a_b` 逐个 `all.equal(tolerance=1e-9)`

### 6.5 建议实施顺序

| 阶段 | 内容 | 验收 |
|---|---|---|
| P1 | `keys.R` + `read.R` + `matrix.R` | `离子分布初筛` sheet 行数 = 354,260，`count` 分布一致 |
| P2 | `filter.R` + `distinct.R` | 50% = 20,910，80% = 13,375 |
| P3 | `score.R`（P50 + 全离子双维度） | 打分两表 20 列逐列一致 |
| P4 | `isotope.R` | 同位素表 25 列一致 |
| P5 | `compare.R` + `merge_diff` | 比对表与差异汇总表一致（含排序） |
| P6 | `export.R` 格式对齐 | 文件名/sheet 名/表头/小数位/TTEST 公式 |

---

## 7. 复现方式

### 7.1 从 exe 重新提取 jar

```bash
python .workbuddy/reverse/extract_strings.py corvida/     # 提取中文常量
# 完整提取脚本见本报告第 1.3–1.4 节的逻辑，或直接用已归档的 jar1.jar
```

### 7.2 反编译

```bash
java -jar cfr.jar jar1.jar --jarfilter "corvida\..*" --outputdir src --comments false
```

### 7.3 跑原版算法（headless）

```bash
# 1) 解压 jar 到 classes/（Java 的 ZipFile 对这个 jar 的某些条目兼容性差，用目录更稳）
# 2) 编译
javac -encoding UTF-8 -cp classes -d . RunDMetFinder.java
# 3) 运行（约 20 秒）
java -Xmx3g -cp "classes;runner" RunDMetFinder <groupA.xlsx> <groupB.xlsx> <outDir>
```

注意：
- 输出目录必须以分隔符结尾（原版直接字符串拼接）
- `Config.instance = new Config()` 用默认参数；要改参数直接改字段再 run
- 原版多线程写盘，结束需 `IoHelper.waitAllWriteThreads()`

---

## 8. 风险与注意事项

1. **原版有已知缺陷**：`IonCalculator.mergeDiff` 里 `m2Isotope`/`m3Isotope` 用 `m1Isotopes.containsKey()` 判断，是复制粘贴 bug。忠实移植会带上它；建议移植但**单独标注**，让用户决定是否修。
2. **`noMz` 字符串拼接在小样本编号下会碰撞**（表头注释已自曝）。重写时不要"顺手优化"成数值编码，否则结果不可比。
3. **`TTest` 类返回的是 t 统计量不是 p 值**，且实际不参与计算（只写 Excel 公式）。R 版若直接算 p 值，会与原版数字不同 —— 应保留公式。
4. **`mergeRows` / `filters` 是从未生效的配置**，UI 若展示会误导用户，建议隐藏或标注"预留"。
5. **本次逆向未修改任何现有代码**：`R/`、`server/`、`ui/` 均未改动；所有产物在 `.workbuddy/`（已 gitignore）与系统临时目录。

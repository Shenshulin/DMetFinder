# DMetFinder 命令行（agent 调用层）使用说明

> 适用于 DMetFinder 1.0.4。图形界面（Shiny）保持不变；本命令行与界面调用
> 的是同一批计算函数，结果等价（逐单元格一致，见 `tests/agent/test_csv_fidelity.R`）。
> 峰质量（第三页）仍在开发，**未**接入本命令行。

---

## 1. 先跑自检

```bat
cli\run-dmf.bat doctor
```

逐项检查 R 版本、依赖包、中文编码、sha256 与输出可写性，缺失项会给出安装命令。
`[FAIL]` 一项都不能有。

若不想装依赖，先确认这 5 个包：`openxlsx`、`readxl`、`digest`、`jsonlite`、`data.table`。

---

## 2. 三个常用命令

```bat
:: 看输入文件结构，不跑分析
cli\run-dmf.bat inspect --input demo_data\groupA.xlsx --out out\inspect

:: 跑 A/B 差异筛选，产出 18 个 CSV
cli\run-dmf.bat diff --a demo_data\groupA.xlsx --b demo_data\groupB.xlsx --out out\run1

:: 加 --json 拿机器可读结果
cli\run-dmf.bat diff --a ... --b ... --out out\run1 --json
```

Windows 下建议始终用 `cli\run-dmf.bat`，它已处理三个坑：`LOCALAPPDATA`
（R 找不到用户库）、`LANG`（中文乱码）、Rscript 路径含空格。

其他平台：`Rscript cli/dmf.R <命令> [选项]`。

三个读谱图的命令（`msg-extract` / `msg-match` / `rt-apex`）见 §10。

---

## 3. 输出目录结构

```
out/run1/
├── run.json          # 信封：版本、commit、参数哈希、每个文件的 sha256
├── schema.csv        # 列字典：每一列的名字、内部字段名、原始多层表头
├── tables/           # 18 个 CSV，一个 sheet 一个文件
└── xlsx/             # 仅当加了 --xlsx
```

### 18 个 CSV 的编号与来源

| 文件 | 原 xlsx | 原 sheet |
|---|---|---|
| `01_A组离子分布初筛.csv` | A组-筛选50%和A组80%离子 | A组离子分布初筛 |
| `02_A组50%分布频率离子.csv` | 同上 | A组50%分布频率离子 |
| `03_A组80%分布频率离子.csv` | 同上 | A组80%分布频率离子 |
| `04_A组50%离子单独打分.csv` | A组-离子打分 | A组50%离子单独打分 |
| `05_A组总离子平均得分.csv` | 同上 | A组总离子平均得分 |
| `06_A组离子打分汇总.csv` | 同上 | A组离子打分汇总 |
| `07_A组同位素离子查找.csv` | A组-同位素离子查找 | A组同位素离子查找 |
| `08_A组80%离子和B组比对.csv` | A组-A组80%离子与B组总离子比对分析 | A组80%离子和B组比对 |
| `09_A组和B组差异离子(A组比B组).csv` | A组-B组差异离子筛选汇总 | A组和B组差异离子(A组比B组) |
| `10_B组和A组差异离子(B组比A组).csv` | 同上 | B组和A组差异离子(B组比A组) |
| `11`–`17` | B 组对应三个 xlsx | 同 A 组命名规则 |
| `18_B组80%离子和A组比对.csv` | B组-A组80%离子与B组总离子比对分析 | B组80%离子和A组比对 |

编号按原程序的写出顺序固定，不随输入变化。论文补充材料可直接引用文件名。

---

## 4. 读 CSV 前必须知道的三件事

### 4.1 表头只有一行

原 xlsx 的表头是**两层**（例如"总离子平均得分"第一层是分组标题、第二层才是列名）。
CSV 取**最后一行**作列名，因为它与数据列一一对齐；第一层的分组语义写在
`schema.csv` 的 `header_r1` / `header_r2` 里。

想知道某列是什么，查 `schema.csv`：

```
csv_file, seq, sheet_name, workbook, col_index, csv_col_index,
column_name, internal_key, header_r1, header_r2, header_r3, dropped
```

`internal_key` 是源码里的字段名（如 `no_mz_total`），`header_r1` 是上层分组标题。

### 4.2 全空列被丢弃

原表里有若干只起视觉分隔作用的空列（列名 `-`，值全空）。CSV 里它们是纯噪声，
默认丢弃。被丢弃的列在 `schema.csv` 中 `dropped=TRUE`，`csv_col_index` 为空。

要按原样保留全部列：加 `--keep-empty-cols`。

### 4.3 编码是 UTF-8 无 BOM

无 BOM 是为了让 pandas / fread 直接读。用 Excel 打开可能显示乱码——那请用
"数据 → 从文本/CSV → 编码选 UTF-8"导入，或者生成时加 `--bom`。

缺失值写作空串，不写 `NA`。注意"未找到"在原算法里就被记作 `0`（`NullCellValue`），
那是语义、不是缺失，命令行不会改写它。

---

## 5. 退出码

| 码 | 含义 | 建议动作 |
|---|---|---|
| 0 | 成功 | — |
| 1 | 参数错误 | 看提示，`--help` |
| 2 | 输入错误（文件缺失、格式不符） | 先跑 `inspect` |
| 3 | 运行错误 | 看 `run.json` 的 `error` |
| 4 | 成功但有警告 | 看 `warnings`，通常无害 |

`--json` 时 stdout 是一个完整信封；失败时 `ok=false` 并带 `error{code,message,hint}`。

---

## 6. 可复现

`run.json` 含：版本、git commit、参数哈希、每个输入的 sha256、每个输出的 sha256、
耗时、警告。方法学里可以写：

> All DMetFinder analyses were performed with version 1.0.4 (commit …); the exact
> parameter set and SHA-256 checksums of all inputs and output tables are recorded
> in the `run.json` accompanying each analysis.

改参数：写一个 JSON，键名与 `R/config.R` 的 `default_config` 一致，用 `--params` 传入。

```json
{ "ErrorRange": 0.002, "p50IonPercent": 0.5, "countRange": [1, 3, 5, 10] }
```

### `MatrixPick`（v1.0.3 起，默认 `"max"`）

同一离子在 `±ErrorRange` 窗口（同一 RT 桶）里、对**同一样品**命中多个质心时取哪一个：

- `"max"`（默认）：取强度最大者。一条特征被切成多支 m/z 时，逐样品的选支不再抖动，
  组内 CV 与定量准确率都明显更好（TOF 基准 QAR 45.2% → 78.9%，QE HF 88.1% → 93.0%）；
- `"first"`：取原始下标最小者，即原版 Java 的「同一样品先到先得」。
  需要复现原版结果、或与其他实现逐字节对照时用。

```json
{ "MatrixPick": "first" }
```

`count` / `averageIntensity` 的口径不变（命中样品数、强和/命中数），只有"取哪一个"变了；
检出集合不受影响（`count` 未变）。

### `ClusterRtTol`（v1.0.4 起，默认 `0.3`）

组内匹配窗口的**时间维度**容差（分钟）：

- `0`：只用原版键「同一整数分钟桶 + ±ErrorRange」。1 min 桶会把跨桶峰、以及同一特征
  被切成多支的离子拆开，组内 CV 与定量准确率受损（TOF 基准 QAR 78.9%）；
- `>0`（默认 0.3）：改为「±ErrorRange 且 |apex RT 差| ≤ ClusterRtTol」。
  需要 Ms1Geter 输出的 `RT_apex` 列（xlsx 每样品第 6 列，块宽 6 → 7，读取端按表头
  自动识别，旧格式文件自动退回 0 的行为）。TOF 基准 QAR 78.9% → 87.9%，
  QE HF 93.0% → 见 QE 报告；检出集合可能轻微变化（跨桶离子重新归并后 count 上升）。

```json
{ "ClusterRtTol": 0 }
```

---

## 7. 已知问题

**R 4.6.0 / Windows 上的收尾崩溃。** `diff` 在数据量较大时（demo 全量约 50 s、
235 MB 输出），R 进程在**所有产物写完、run.json 落盘之后**的退出阶段会发生访问违例。
命令行已把重活放进子进程，父进程依据 `run.json` 判定退出码，所以：

- 产物始终完整，退出码始终正确
- stderr 会打印一行 `[note] R 进程收尾异常退出…`，这是已知现象，不必处理

如果换用其他 R 版本后该现象消失，这一行会自然消失。

**内存。** 全量 demo 峰值约 1–1.5 GB。样本更多时请留意可用内存。

---

## 8. 目录

```
cli/dmf.R              唯一入口
cli/run-dmf.bat        Windows 包装
cli/lib/               args / envelope / csv_out / core_load / inspect_xlsx / doctor
                       progress / ms_core / msg_extract / msg_match / rt_apex
tests/agent/           CSV 与 xlsx 一致性测试、MSGeter 等价性测试
setup.R                依赖安装（只用 base R，可在裸环境跑）
deps.csv               依赖清单，setup.R 与打包脚本共用这一份
renv.lock              26 个包的确切版本（5 直接 + 21 传递）
tools/make_dist.R      生成 dist/DMetFinder-CLI-<ver>/ 与 .zip
tools/make_renv_lock.R 重新生成 renv.lock（不改动项目、不激活 renv）
docs/agent/QUICKSTART.md  合作者使用说明
```

MSGeter 三条命令不复制上游算法，而是 `source()` 三个 `shiny_app/server/*_server.R`
到独立 environment 后调用其中的顶层函数（详见 §10）。因此分发包必须带上这三
个文件——少了它们，`msg-*` 会在运行时报"缺少 MSGeter 源文件"。

## 9. 分发

`Rscript tools/make_dist.R --zip` 产出 `dist/DMetFinder-CLI-1.0.4.zip`（约 24 MB）。

白名单打包，只含：`cli/`、`R/config.R`、`R/dmetfinder_functions.R`、`demo_data/`、
`docs/agent/`、`setup.R`、`deps.csv`、`renv.lock`、`README_FIRST.txt`、`MANIFEST.txt`。
`www/`、`figures/`、`tests/`、`shiny_app/`、`server/`、`ui/`、`out/`、`dist/` 一律不带。

归档内保留顶层目录 `DMetFinder-CLI-1.0.4/`，解压即得一个可运行目录。
`MANIFEST.txt` 记录每个文件的字节数与 sha256；校验方法见文件内说明。

**已验证**：把 zip 解压到无关目录后，`setup.R --check-only` 全绿，
`diff` 产出的 18 个 CSV 与项目内运行结果**逐字节相同**，`run.json` 的
`n_rows_a / n_rows_b / n_diff_ab / n_diff_ba` 完全一致。

---

## 10. MSGeter 三条命令（读谱图）

对应界面第二页的三个子页签。前两个串成一条链，第三个独立：

```
             ┌── msg-extract ──┬── 01_MS2_Group_Info.csv ──┐
.raw/.mzML ──┤                 └── ms2_msp/<sample>.msp ───┴── msg-match ── ms2_matched.msp
             └── 峰表 + ms_dir ──── rt-apex ──── 补全 RT 的峰表
```

### 10.1 依赖

| 输入格式 | 需要 | 装法 |
|---|---|---|
| `.mzML` / `.mzXML` | `mzR` | `BiocManager::install("mzR")` |
| `.raw`（Thermo） | `rawrr` + .NET Runtime + `stringr` | `BiocManager::install("rawrr")` |

`doctor` 会把缺的包标成 `warn`（不影响 `diff`），并给出对应安装命令。
两条读取路径都走上游同一个 `read_ms_file()`，**同一份数据两种格式结果一致**。

### 10.2 msg-extract

```bat
cli\run-dmf.bat msg-extract --ms-dir raw --samples samples.csv --out out\msg1
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--ms-dir` | 必填 | 扫 `.raw/.mzML/.mzXML`，不递归 |
| `--samples` | 无 | CSV/xlsx，含 `Sample` 与 `Group`；不给则全归入 `All` |
| `--rt-min` / `--rt-max` | 1 / 18 | **实际采集时间**范围（分钟）。写进 RT 列的 = 该值 + 1，故默认产出 RT 2–19 |
| `--max-mz` | 1500 | 去卷积 m/z 上限 |
| `--min-intensity` | 10000 | 去卷积后强度下限 |
| `--ppm` | 10 | 去卷积窗口 |
| `--ms2-gap` | 0.9 | MS2 前体 m/z 分组间隔 |
| `--slow-deconv` | 关 | 改用上游 R 循环去卷积（结果相同，约慢 100 倍，供审计） |
| `--no-input-hash` | 关 | 跳过输入文件的 sha256（几 GB 数据可省时间，但失去复核能力） |
| `--xlsx` | 关 | 额外写出界面同款 `Clean_MS1_Data_Group*.xlsx` |

产物：

```
out/msg1/
├── tables/01_MS2_Group_Info.csv      # 所有 MS2 扫描：scan, StartTime, scanType, ms2_value, group, Sample
├── tables/02_sample_summary.csv      # 每个样品一行：格式、离子模式、扫描数、峰数、耗时
├── tables/03_MS1_Group_<组名>.csv     # 长表：一行一个峰（Sample, RT, RT_mz, mz, intensity, RT_apex）
├── ms2_msp/<sample>.msp              # 逐样品 MSP，NAME 形如 <sample>_scan<扫描号>
├── progress.json / progress.log      # 运行状态（供 job 查询）
└── run.json
```

### 10.3 msg-match

```bat
cli\run-dmf.bat msg-match --features peaks.csv ^
  --ms2-info out\msg1\tables\01_MS2_Group_Info.csv ^
  --msp-dir out\msg1\ms2_msp --out out\match1
```

峰表需要三列：样品、m/z、RT。列名按别名表解析（`sample`/`样品`/`Sample`、
`m/z`/`mz`/`前体mz`、`RT`/`rt`/`保留时间`）；**同一列有多个候选时报错而不猜**，
用 `--sample-col` / `--mz-col` / `--rt-col` 指定（可给列名或列号）。

| 参数 | 默认 | 说明 |
|---|---|---|
| `--mz-tol` | 0.01 | 前体 m/z 窗口（Da，含端点） |
| `--rt-tol` | 不限 | RT 窗口（分钟）。界面版完全不看 RT，这里默认保持兼容；**建议设一个值** |

产物：

```
out/match1/
├── tables/01_matched_features.csv    # 原峰表 + scan 列（只含匹配上的行）
├── tables/02_match_diagnostics.csv   # 每一行都有一条：row, matched, scan, n_candidates,
│                                     # match_mz_diff, match_rt_diff, reason
├── tables/03_match_summary.csv       # n_features / n_matched / match_rate / 各类未匹配原因
└── ms2_matched.msp
```

`reason` 取值：`matched` / `no_ms2_for_sample` / `no_precursor` / `no_mz_window` /
`rt_tol_excluded` / `bad_mz` / `bad_rt`。**匹配率低时先看这张表**，它区分了
"这个样品根本没进 msg-extract"、"窗口内没有前体"和"有候选但 RT 太远"。

### 10.4 rt-apex

```bat
cli\run-dmf.bat rt-apex --features peaks.csv --ms-dir raw --out out\apex1 --tol 10 --unit ppm
```

峰表需要四列：峰 ID、样品、m/z、RT（分钟）。RT 的含义是**分钟桶的上界**：
查询窗口是 `(RT-1, RT]`，所以 `msg-extract` 产出的 `RT` 列可以直接用作输入。
列识别不出来时**报错而不会静默按前四列处理**（界面版会），用
`--id-col` / `--sample-col` / `--mz-col` / `--rt-col` 指定。

产物：`tables/01_rt_apex_result.csv`（原表 + RT 列）、
`tables/02_rt_apex_diag.csv`（每行的窗口、状态、命中扫描、强度、m/z 误差 ppm）、
`tables/03_rt_apex_summary.csv`（状态分布）、`rt_apex.log`。

### 10.5 长任务：progress.json 与 job

三条命令都要读谱图，几十分钟很常见。运行过程中每约 1 秒把状态原子写入
`<out>/progress.json`，另一个进程可以随时查：

```bat
:: 查一次
cli\run-dmf.bat job --out out\msg1

:: 阻塞等它结束（默认 1800 s 超时）
cli\run-dmf.bat job --out out\msg1 --wait --timeout 3600
```

`state` 取值 `running` / `done` / `failed`；`job` 的退出码由它推导：
`done` → 0，`failed` 或等待超时 → 3，目录里没有状态文件 → 2。

### 10.6 与界面版的四处差异（都是刻意的）

1. **产物路径参数化**。界面把 `MS2_MGF/` 与 `MS2_Group_Info.csv` 写在进程当前
   目录；CLI 全部写进 `--out`，不污染调用方目录。
2. **去卷积向量化**。上游 `clean_spectrum_keep_max()` 是逐峰 while 循环，1e6 个
   峰约 54 s；CLI 用等价闭式写法（阈值随锚点单调递增，指针只前进），0.4 s。
   `tests/agent/test_msg_equiv.R` 在 5 组随机数据 + 真实夹具上与上游实现比对，
   逐元素相同。`--slow-deconv` 可切回上游实现做审计。
3. **MS1 表是长表**。界面按"每样品 6 列一块"（v1.0.4 起含 RT_apex，块宽 7）并排写进一个 sheet；CSV 直接给
   一行一个峰，能被 pandas / fread / MS-DIAL 直接读。需要原块式时加 `--xlsx`。
4. **MSP 头部不带多余空格**。界面写的是 `IONMODE: Positive` / `Num Peaks: 42`，
   而它的读取函数只裁前缀，于是 `ionmode` 实际是 `" Positive"`。CLI 统一写成
   `IONMODE:Positive` / `Num Peaks:42`，两边的读取器都能正确解析。

### 10.7 内存

上游曾在一个 20 样品批次上把 R 撑到 16 GB（把所有谱图攒到最后统一写 MSP）。
CLI 按样品处理：读完立即写 MSP、随后 `rm()` + `gc()`，峰值只与单个文件相关。
`02_sample_summary.csv` 的 `Seconds` 列可用于估算同批数据的重跑时间。

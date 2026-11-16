# DMetFinder 命令行版使用说明

这个包把 DMetFinder 的 A/B 差异离子筛选做成命令行工具，不需要启动 Shiny 界面。
输出与界面版**逐单元格一致**（在 demo 数据上比对了 40,887,423 个单元格）。

**本包只含主流程。** Peak Quality（峰质量）模块仍在开发，未包含进来；
MSGeter 的三个子页（Ms1Geter / Ms2Geter / RtGeter）也尚未接入命令行。

---

## 1. 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 操作系统 | Windows 10/11 | `run-dmf.bat` 是 Windows 包装。R 脚本本身跨平台，macOS/Linux 直接用 `Rscript cli/dmf.R` |
| R | **≥ 4.3** | 4.6.0 上实测通过 |
| R 包 | 5 个 | `setup.R` 自动装：openxlsx、readxl、jsonlite、data.table、digest |
| 磁盘 | 每次运行约 230 MB | demo 数据。真实数据按离子数线性增长 |
| 内存 | 约 2–4 GB | demo 数据。十万级离子 × 十样品量级 |

不需要 Rtools，不需要 Python，不需要联网（装完包之后）。

---

## 2. 安装

### 第一步：装 R

从 <https://cloud.r-project.org/> 下载安装。装完后在 cmd 里确认：

```bat
Rscript --version
```

如果提示找不到命令，说明 R 的 `bin` 目录不在 PATH 里。两种办法：
- 重装 R 时勾选"添加至 PATH"，或
- 直接用完整路径：`"C:\Program Files\R\R-4.6.0\bin\Rscript.exe"`

### 第二步：装依赖

在本文件夹下打开 cmd：

```bat
Rscript setup.R
```

它会逐包检查、按需安装，最后自动调用 `doctor` 自检。看到这一行就算成功：

```
RESULT: all required packages are present.
```

**国内网络**通常需要换镜像：

```bat
Rscript setup.R --repos https://mirrors.tuna.tsinghua.edu.cn/CRAN/
```

只想看缺什么、不安装：

```bat
Rscript setup.R --check-only
```

### 第三步：跑 demo 验证

```bat
cli\run-dmf.bat diff --a demo_data\groupA.xlsx --b demo_data\groupB.xlsx --out out\run1
```

约 1 分钟。成功后 `out\run1\tables\` 下有 19 个 CSV。

---

## 3. 三个基础命令

所有命令都可以加 `--help` 看完整参数。

### `doctor` — 环境自检

```bat
cli\run-dmf.bat doctor
```

检查 R 版本、5 个包、核心文件、临时目录可写性、UTF-8 区域设置、sha256 可用性。
每项失败都附修复建议。**遇到任何问题，先跑这个。**

### `inspect` — 只读检查输入文件

```bat
cli\run-dmf.bat inspect --input demo_data\groupA.xlsx --out out\inspect
```

不跑分析，只回答"这个文件能不能用"：

| 检查项 | 严重级 | 含义 |
|---|---|---|
| 列数不是块宽（6，含 RT_apex 时 7）的整数倍 | 提示 | Excel 会截掉末尾空列，通常无害 |
| 末块不足 5 列 | **错误** | 该样品会被整块丢弃，离子静默缺失 |
| 样品编号重复 | **错误** | 会被 `unique()` 合并成一个样品 |
| 样品编号跳号 | 提示 | 实验设计里编号本就不连续时会报，属正常 |
| 某块离子数 < 组内中位数的 10% | 提示 | 疑似读取不全 |

一次典型的正常输出：`10 个样品、每样品 35,426 个离子、0 警告`。

### `diff` — 主流程

```bat
cli\run-dmf.bat diff --a 甲组.xlsx --b 乙组.xlsx --out out\run1
```

| 参数 | 说明 |
|---|---|
| `--a` / `--b` | 两组输入 xlsx，每样品 6 列一块（Ms1Geter 输出带 `RT_apex` 时 7 列）、首行样品编号 |
| `--out` | 输出目录。**必须不存在或为空**，防止覆盖上一次结果 |
| `--overwrite` | 允许写入非空输出目录。**会覆盖同名文件**，谨慎使用 |
| `--groups "甲组,乙组"` | 输出表名里的组名，默认 `A组,B组` |
| `--xlsx` | 额外产出 9 个 xlsx（与界面版完全一致），供人工核对 |
| `--json` | stdout 输出 JSON 信封（供程序调用） |
| `--quiet` | 不打印进度 |
| `--keep-empty-cols` | 保留全空的分隔列（默认丢弃） |
| `--bom` | CSV 带 UTF-8 BOM（Excel 双击打开不乱码，但 pandas 会读到 `\ufeff`） |

---

## 4. 产物

```
out\run1\
├── tables\           19 个 CSV，一个 sheet 一个文件
├── schema.csv        每一列的含义与来源
├── run.json          参数 + 每个输入输出的 sha256
└── xlsx\             仅 --xlsx 时存在，9 个原版工作簿
```

### 19 个 CSV 的顺序

| # | 文件 | 内容 |
|---|---|---|
| 01 | `A组离子分布初筛.csv` | 50%/80% 分布频率筛选后的离子 |
| 02 | `A组50%分布频率离子.csv` | 只保留 50% 分布频率的离子 |
| 03 | `A组80%分布频率离子.csv` | 只保留 80% 分布频率的离子 |
| 04 | `A组50%离子单独打分.csv` | 逐离子打分明细 |
| 05 | `A组总离子平均得分.csv` | 按 RT&m/z 组内取均值后的得分 |
| 06 | `A组离子打分汇总.csv` | 打分汇总视图 |
| 07 | `A组同位素离子查找.csv` | 同位素峰识别结果 |
| 08 | `A组80%离子和B组比对.csv` | A 的 80% 离子在 B 组中的存在情况 |
| 09 | `A组和B组差异离子(A组比B组).csv` | A 相对 B 的特异离子 |
| 10 | `B组和A组差异离子(B组比A组).csv` | B 相对 A 的特异离子 |
| 11 | `A组和B组差异离子(整合).csv` | 09 + 10 的并集，每行一个离子，两侧强度并排 + 判定 |
| 12–18 | `B组...` | 与 01–07 同构，B 组视角 |
| 19 | `B组80%离子和A组比对.csv` | B 的 80% 离子在 A 组中的存在情况 |

序号是**固定映射**，不随运行结果变化——论文补充材料里可以直接引用文件名。

### schema.csv

原 xlsx 的表头是多行的（第一行是分组标题，第二行才是列名），CSV 只能承载一行。
`schema.csv` 保留完整信息，一行一个输出列：

| 列 | 含义 |
|---|---|
| `csv_file` | 所属 CSV 文件名 |
| `sheet_name` | 原 sheet 名 |
| `col_index` | 在原 sheet 中的列号 |
| `column_name` | CSV 里实际用的列名 |
| `internal_key` | 对应的内部字段名（如 `no_int`） |
| `header_r1` / `header_r2` | 原表头前两行原文 |
| `dropped` | `TRUE` 表示该列全空、已丢弃 |

审稿人问"这一列是什么"时，答案在这里。

### run.json

```json
{
  "ok": true,
  "command": "diff",
  "version": "1.0.5",
  "git_commit": "abc1234",
  "git_dirty": false,
  "duration_s": 58.3,
  "params_hash": "…",
  "inputs":  [{"role": "group_a", "path": "…", "sha256": "40041f86…"}],
  "outputs": [{"role": "table", "sheet": "Group A ion distribution", "rows": 354260, "cols": 16, "sha256": "…"}],
  "warnings": [],
  "metrics": {"n_tables": 19, "n_rows_a": 354260, "n_rows_b": 327400,
              "n_diff_ab": 13375, "n_diff_ba": 12392, "n_diff_union": 21064}
}
```

`git_dirty` 为 `true` 表示跑分析时工作区带着未提交改动：此时 `git_commit` 只
说明出发点，clone 那个 commit 跑不出同样的结果。写成 `null` 表示判断不了
（没有 `.git` 或没装 git），不是"干净"。

---

## 5. 退出码

程序调用时**只看退出码**，不要解析输出文本。

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 参数错误（缺参数、未知选项、未知命令） |
| 2 | 输入错误（文件不存在、结构不合格、输出目录非空） |
| 3 | 运行时错误（依赖缺失、磁盘满） |
| 4 | 成功但有警告 |

---

## 6. 常见问题

### 报 "there is no package called 'jsonlite'" 但明明装了

R 找不到用户库。常见于从 Git Bash 启动，`LOCALAPPDATA` 变成了 `/c/Users/...` 这种 POSIX 路径。

`cli\run-dmf.bat` 已经处理了这个问题（它总是从 `USERPROFILE` 重建）。
如果你直接用 `Rscript cli/dmf.R`，需要自己保证 `LOCALAPPDATA` 是 Windows 形式：

```bat
set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"
Rscript cli\dmf.R diff ...
```

### 输出的中文变成乱码

`LANG` / `LC_ALL` 环境变量会让 R 进入非 UTF-8 原生编码。`run-dmf.bat` 每次运行都会清空它们。

### 看到 `[note] R 进程收尾异常退出`

**这是已知现象，不影响结果。** R 4.6.0 在 Windows 上处理完大会话后，退出阶段偶发访问违例
（bash 里报 139，cmd 里报 `0xC0000005`）。

工具的处理方式是：真正的计算在子进程里跑，**退出码由 `run.json` 推导**，而不是由进程状态决定。
所以只要看到 `run.json` 里 `"ok": true`，且 19 个 CSV 都在，结果就是完整的。
这行 `[note]` 只是在如实报告进程收尾不正常。

### `--out` 目录已存在就报错

故意的，防止覆盖上一次结果。换一个目录名，或先删掉旧的。

### diff 跑得比预期慢

19 个 CSV 里最大的两个（同位素查找、总离子平均得分）各有 39–42 MB。
磁盘慢或开了杀毒软件实时扫描会明显拖慢。可以先把输出目录加入杀毒白名单。

### 想要 Excel 能直接双击打开 CSV

加 `--bom`。但**不要**给程序读的版本加，pandas 会把首列读成 `\ufeffsample`。

---

## 7. 可复现性

论文 Methods 里可以写这样一句话：

> All differential-ion screening was performed with DMetFinder CLI v1.0.5
> (R 4.6.0; package versions recorded in `renv.lock`). Input files were
> verified by SHA-256 (`sha256sum` in `run.json`).

具体做法：

1. **核对文件完整性**——`MANIFEST.txt` 里有每个文件的 sha256：

   ```powershell
   Get-FileHash cli\dmf.R -Algorithm SHA256
   ```

2. **核对输入输出**——`run.json` 的 `inputs[].sha256` 和 `outputs[].sha256`
   就是本次运行实际读写的字节哈希。同一个输入文件重跑，这两个值必须一致。

3. **还原精确环境**（可选）——装了 `renv` 的话：

   ```r
   renv::restore()
   ```

   `renv.lock` 记录了 26 个包（5 个直接依赖 + 21 个传递依赖）的确切版本。
   **注意：本项目没有激活 renv**，所以 `renv::restore()` 会在当前目录创建 `renv/` 和 `.Rprofile`。
   只想核对版本的话，直接读 `renv.lock` 即可，不必 restore。

4. **确定性已验证**——同一输入连跑两次，19 个 CSV **逐字节相同**。

---

## 8. 目录结构

```
DMetFinder-CLI-1.0.5\
├── cli\
│   ├── dmf.R              入口（子命令分发）
│   ├── run-dmf.bat        Windows 包装（修环境变量、定位 Rscript）
│   └── lib\               7 个模块：util / args / envelope / csv_out / core_load / inspect_xlsx / doctor
├── R\
│   ├── config.R           算法参数（档位表在这里）
│   └── dmetfinder_functions.R   计算层，与界面版共用同一份
├── demo_data\             10 样品 × 2 组的示例数据
├── docs\agent\
│   ├── QUICKSTART.md      本文
│   └── CLI_CONTRACT.md    JSON 输出格式与退出码契约
├── setup.R                依赖安装
├── deps.csv               依赖清单
├── renv.lock              版本记录
├── MANIFEST.txt           文件哈希
└── README_FIRST.txt       英文快速上手
```

`R\dmetfinder_functions.R` 与 Shiny 界面版**是同一份文件**，没有分叉。
命令行版只做了一件事：把写 xlsx 的那一步换成写 CSV 的那一步，用依赖注入实现，
不改计算逻辑。

---

## 9. MSGeter 三条命令（可选，读谱图）

如果还要做 MS1/MS2 抽取、谱库匹配、RT 校正，用这三条。它们需要额外的包：

```bat
:: 读 .mzML / .mzXML
Rscript -e "BiocManager::install('mzR')"

:: 读 Thermo .raw（还需 .NET Runtime）
Rscript -e "BiocManager::install('rawrr'); install.packages('stringr')"
```

装完 `doctor` 里这几项会从 `warn` 变 `ok`。

### 注意：mzML 请用 centroid 版

给这三条命令喂 mzML 时，**必须是 centroid（已打峰）的 mzML，不要用 profile（轮廓）版**。

程序里有一条兜底：读到一张谱后，若相邻点间距中位数 < 0.005 Da，就认为它是 profile，
当场用 20 ppm 窗口收敛一遍。这条兜底在真实数据上**不成立**：

- 真实 TripleTOF profile 谱的点间距只有约 0.003 Da，而 20 ppm 在 m/z 500 处的跨度是 0.010 Da，
  于是每 3–4 个点归为一组、取最大值——结果**等价于"取每个局部极大"**。
- MS2 谱的局部极大数约为点数的 1/3，这正好是纯随机噪声中局部极大的期望比例。
  也就是说取到的绝大多数是噪声极值，不是真峰。

实测（SampleA_1，27,246 张谱，RT 2–19 min，其余参数全默认）：

| | profile mzML | centroid mzML |
|---|---|---|
| 耗时 | **1,172 s（19.5 min）** | **39 s** |
| MS1 峰数 | 14,636 | 4,806 |
| MSP 体积 | 760 MB | 73.7 MB |
| 内存峰值 | 2,057 MB | 653 MB |
| 同一条 MS2（scan 11341）| **1,279 个"峰"**，开头多个点强度都是 17 | **21 个峰** |

那 1,279 个点里大部分是强度 17 的基线噪声。也就是说 profile 版不仅慢 30 倍，
产出的 MSP 还是噪声谱。

正确做法是先打峰再喂进来：

```bat
msconvert %f.wiff --mzML --outfile %f.mzML --outdir centroid --filter "peakPicking true 1-"
```

从 `.wiff` 直接转能让 msconvert 调 SCIEX 自家的 peak picking，与 Analyst 界面一致；
从 profile mzML 二次转换只能走 cwt，峰数差 8 倍以上。详细转换与核验见数据集目录的
`README_mzML_conversion.md`。

顺带一提，DMetFinder 读 `.raw` 时用的就是 `rawrr` 的 `mode="centroid"`（vendor 打峰阵列），
所以 centroid mzML 才与 `.raw` 路径同源。

用法：

```bat
:: 1. 抽 MS1 峰表 + MS2 扫描表 + 每个样品的 msp
cli\run-dmf.bat msg-extract --ms-dir raw --samples samples.csv --out out\msg1

:: 2. 把峰表匹配到 MS2 扫描号，导出可检索的 msp
cli\run-dmf.bat msg-match --features peaks.csv ^
  --ms2-info out\msg1\tables\01_MS2_Group_Info.csv ^
  --msp-dir out\msg1\ms2_msp --out out\match1

:: 3. 回原始 MS1 找真实 apex，重算 RT
cli\run-dmf.bat rt-apex --features out\msg1\tables\03_MS1_Group_A.csv ^
  --ms-dir raw --out out\apex1
```

这几条要读谱图，跑几十分钟很常见。运行中途想查进度：

```bat
cli\run-dmf.bat job --out out\msg1
cli\run-dmf.bat job --out out\msg1 --wait --timeout 3600
```

完整参数与产物说明见 `CLI_CONTRACT.md` 第 10 节。

---

## 10. 引用

如果这个工具对你的工作有帮助，请引用 DMetFinder 原文（见项目根目录 `README.md`）。
命令行版是同一算法的新入口，不构成独立方法。

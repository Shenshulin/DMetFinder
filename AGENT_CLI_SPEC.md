# DMetFinder Agent 调用层设计方案

> 状态：设计稿 v2，待确认后实施
> 目标版本：DMetFinder 1.0.3 + agent 层
> 原则：**纯加法。不修改任何现有文件，不改动 Shiny 行为。**

---

## 0. 一句话

在现有 Shiny 应用之上，新增 `cli/` 与 `mcp/` 两个目录，把已存在、与界面零耦合的计算函数暴露成命令行子命令，输出为**拆分后的 CSV**，再用一层薄壳包成 MCP 工具。Shiny 与 CLI 调用同一批函数，不做第二套算法。

---

## 1. 约束与目标

| 约束 | 来源 | 影响 |
|---|---|---|
| 要发 SCI 论文 | 用户 | 可复现：版本、commit、参数哈希、输入哈希全部落盘 |
| 要共享给合作者 | 用户 | 可移植：环境自检、依赖清单、优先支持 mzML |
| 要给别的 agent 调用 | 用户 | 机器可读输出，不能只有 xlsx |
| **峰质量（第三页）开发中** | 用户 | **完全不接入 agent 层**，见 §5.4 |
| **输出 xlsx → csv，多 sheet 拆开** | 用户 | 见 §6，本方案最重的一节 |
| Shiny 保留，共用 core | 用户 | 不做包化重构，不移动现有文件 |
| 不做 R 包 | 用户 | 用 `Rscript cli/dmf.R` 单入口替代 `library()` |

---

## 2. 设计原则

1. **单入口**：所有能力只经由 `cli/dmf.R` 暴露。MCP、批处理、CI、合作者手跑，走的都是它。
2. **不复制算法**：CLI 只写"胶水"，算法一律调现有函数。
3. **先计划后执行**：有猜测成分的步骤（sample ↔ raw 映射）先 dry-run 出报告。
4. **产物可寻址**：每个作业一个目录，`run.json`（信封）+ `tables/*.csv`（机器读）+ `schema.csv`（列字典）+ `log.txt`。

---

## 3. 新增文件清单

```
DMetFinder/
├── cli/
│   ├── dmf.R                     # 唯一入口，subcommand 分发
│   ├── lib/
│   │   ├── core_load.R           # 按依赖顺序 source 计算层，不加载 shiny
│   │   ├── envelope.R            # JSON 信封、错误码、退出码
│   │   ├── csv_out.R             # ★ sheet -> 多个 CSV 的写出与列字典
│   │   ├── params.R              # 参数默认值合并与校验
│   │   ├── job.R                 # 作业目录、锁、progress.json
│   │   └── util.R                # 路径、sha256、UTF-8
│   └── run-dmf.bat               # Windows 包装：设 LOCALAPPDATA、清 LANG
├── mcp/
│   ├── server.py                 # stdio MCP 薄壳
│   └── tools.json
└── docs/agent/
    ├── CLI_CONTRACT.md
    └── MCP_SETUP.md
```

现有文件**一个都不改**。

---

## 4. CLI 契约

### 4.1 调用方式

```bash
cli\run-dmf.bat diff --a demo_data\groupA.xlsx --b demo_data\groupB.xlsx --out out\run1
Rscript cli/dmf.R <subcommand> [options] --json
```

- **stdout**：JSON 信封（`--json`）或人类可读摘要
- **stderr**：日志与进度
- 退出码是机器判断的唯一依据

### 4.2 子命令

| 子命令 | 作用 | 读原始谱图 | 异步 |
|---|---|---|---|
| `doctor` | 环境自检：R 版本、依赖包、Python venv、可写性 | 否 | 否 |
| `inspect` | 只读结构：xlsx 块数/样本名/离子数；raw/mzML 清单 | 视输入 | 否 |
| `diff` | DMetFinder 主流程 → 18 个 CSV | 否 | 否（可 `--background`） |
| `msg-extract` | MS1/MS2 抽取（原 FeatureGeter） | 是 | 是 |
| `msg-match` | MSP 匹配（原 Ms2Geter） | 否 | 否 |
| `rt-apex` | RT apex 批量补全（原 RtGeter） | 是 | 是 |
| `job` | 查作业状态 / 等待 / 取产物 | 否 | — |
| `version` | 版本 + git commit | 否 | 否 |

> **峰质量相关子命令（`pq-plan` / `pq-run`）本期不做**，见 §5.4。

### 4.3 参数约定

```
--in, --out, --a, --b   输入/输出路径
--params <json>         覆盖默认值，键名与 R/config.R 一致
--groups "A,B"          diff 的组名
--json                  输出 JSON 信封
--keep-empty-cols       保留全空列（默认丢弃，见 §6.4）
--bom                   CSV 带 UTF-8 BOM（默认不带，见 §6.5）
--xlsx                  额外产出合并版 xlsx（默认不产出，见 §6.6）
--overwrite             允许覆盖已有输出目录（默认拒绝）
```

### 4.4 返回信封

```json
{
  "ok": true,
  "command": "diff",
  "version": "1.0.3",
  "git_commit": "a1b2c3d",
  "started_at": "2026-10-29T10:20:00+08:00",
  "duration_s": 412.3,
  "params_hash": "sha256:9f2c...",
  "params": { "ErrorRange": 0.002, "p50IonPercent": 0.5 },
  "inputs":  [{ "role": "group_a", "path": "...", "sha256": "...", "bytes": 12777761 }],
  "outputs": [{ "role": "table", "sheet": "A组离子分布初筛",
                "path": "tables/A组离子分布初筛.csv",
                "rows": 481783, "cols": 6, "sha256": "..." }],
  "warnings": [{ "code": "sample_unmatched", "message": "...", "count": 3 }],
  "metrics": { "n_ions_a": 481783, "n_diff": 834 },
  "job_dir": "out/run1"
}
```

### 4.5 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 用法错误 |
| 2 | 输入错误（文件缺失、格式不符、映射歧义） |
| 3 | 运行错误（算法抛错） |
| 4 | 成功但有警告 |

### 4.6 `inspect` 的检查分层

"多约一天"不是指多写一天代码，而是指**从"能读出来"到"结论可信"之间要做的事**。分三层，可按需选：

| 层 | 检查项 | 成本 | 是否需要读谱图 |
|---|---|---|---|
| **A（结构层）** | xlsx 块宽是否为 6 的整数倍、样本编号重复/跳号/非数值、每块离子数、空块、列数不足 | **约 0.5 小时**，含在 P0 | 否，只用 `dmf_read_samples()` 已读出的东西 |
| **B（元数据层）** | raw/mzML 清单、文件大小、极性、RT 范围、MS1/MS2 谱图数、**文件内部样本名 vs 文件名是否一致** | **约 1 天** | 是，wiff 走 rawrr 头表、mzML 走索引，两条路径分别摸清 |
| **C（交叉验证层）** | TIC 相关性矩阵，检测组别互换/样本错位 | **另 1–2 天** | 是，需完整读谱图算 TIC，最重 |

"一天"具体花在：

1. **判定阈值的设计**（约 3 小时）——块宽 6 的倍数是最简单的；但"编号跳号"要不要报？实验设计里编号本就不连续时，误报比不报更糟。每类异常都要定"确定异常 / 需人工确认"两档，否则报告没人敢用。
2. **两条元数据读取路径**（约 4 小时）——`.wiff` 走 `rawrr`，`.mzML` 走 `mzR`，能拿到的字段不同（RT 范围、极性、MS1/MS2 计数各有各的取法），要分别验证并按统一 schema 归一。
3. **反向测试**（约 2 小时）——需要造几个"故意坏掉"的输入（块宽不是 6、编号重复、文件内部名与文件名不符），确认检查本身不误报。这一步最容易被跳过，但跳过之后检查就不可信。

**建议**：先做 A（含在 P0，几乎零成本），B 视是否需要给合作者做数据交接再定。C 是针对你上次 mzML 转换遇到的 `SampleA_3` 内部名叫 `SampleA_4` 那类问题——如果你还会收到别人给的原始数据，C 值得做；如果只处理自己产的数据，可跳过。

---

## 5. 计算层加载

### 5.1 不碰 shiny

`cli/lib/core_load.R` 按 `app.R` 的顺序 source，但只 source 计算文件，跳过 `ui/`、`server/`、`theme.R`（共约 24 个文件）。

### 5.2 借 MSGeter 的三个函数

`read_ms_file`、`matchScan`、`rtg_run_batch` 直接从 `shiny_app/server/*_server.R` source。已验证可行：三个文件里的 shiny 调用全部位于 `*_server(id)` 函数体内（起始行 509 / 157 / 609），source 时不执行就不会报错。

> 本方案唯一"借"文件之处。日后若要整齐，把三个函数搬到 `R/msgeter/` 即可，属可选整理。

### 5.3 映射显式化（`diff` 前置检查）

`diff` 不需要映射；需要映射的是 `rt-apex` 与 `msg-extract`。这些命令先输出映射报告：

| sample_id | raw_file | match | score | note |
|---|---|---|---|---|
| SA1 | SampleA_1.wiff | exact | 1.00 | |
| SA2 | SampleA_2.wiff | normalized | 0.96 | 大小写/空格差异 |
| SB3 | — | ambiguous | 0.51 | 同时匹配 SB3.wiff 与 SB3_rep.wiff |

`match` 非 `exact` 的行必须由 `--mapping` 覆盖才允许运行。**绝不静默猜测。**

### 5.4 为什么不含峰质量

第三页仍在开发，接口（参数面、结果表结构、DNN 桥接）未冻结。此时接进 agent 层有两个坏处：

1. 每次改参数或结果表，CLI 的 `--params` 契约就得跟着改，合作者手上的版本立刻失效
2. 开发期的中间产物不稳定，写进 `run.json` 的 schema 版本会反复变，反而破坏可复现性

**结论**：等第三页冻结（参数面与 `MethodMetrics` 表结构定稿）后再补 `pq-plan` / `pq-run`。届时只需新增一个 `pq_run_job.R` 加两个子命令，不动已有结构。本方案的所有分层为此预留了位置。

---

## 6. CSV 输出规范（本方案核心）

### 6.1 拆分规则

现状：`dmetfinder_run()` 写 **9 个 xlsx**，内含**共 18 个 sheet**。规则是**一个 sheet → 一个 csv**。

拆分后落在 `out/run1/tables/`，扁平一层，命名 `<两位序号>_<sheet 名>.csv`。

序号沿用 `dmetfinder_run()` 的**实际写出顺序**，与人在 GUI 里看到的结果顺序一致（不是字母序）：

| # | 原 xlsx（写出顺序） | sheet 名 → CSV 文件名 |
|---|---|---|
| 01 | `A组-筛选50%和A组80%离子.xlsx` | `01_A组离子分布初筛.csv` |
| 02 | 同上 | `02_A组50%分布频率离子.csv` |
| 03 | 同上 | `03_A组80%分布频率离子.csv` |
| 04 | `A组-离子打分.xlsx` | `04_A组50%离子单独打分.csv` |
| 05 | 同上 | `05_A组总离子平均得分.csv` |
| 06 | 同上 | `06_A组离子打分汇总.csv` |
| 07 | `A组-同位素离子查找.xlsx` | `07_A组同位素离子查找.csv` |
| 08 | `A组-A组80%离子与B组总离子比对分析.xlsx` | `08_A组80%离子和B组比对.csv` |
| 09 | `A组-B组差异离子筛选汇总.xlsx` | `09_A组和B组差异离子(A组比B组).csv` |
| 10 | 同上 | `10_B组和A组差异离子(B组比A组).csv` |
| 11 | `B组-筛选50%和B组80%离子.xlsx` | `11_B组离子分布初筛.csv` |
| 12 | 同上 | `12_B组50%分布频率离子.csv` |
| 13 | 同上 | `13_B组80%分布频率离子.csv` |
| 14 | `B组-离子打分.xlsx` | `14_B组50%离子单独打分.csv` |
| 15 | 同上 | `15_B组总离子平均得分.csv` |
| 16 | 同上 | `16_B组离子打分汇总.csv` |
| 17 | `B组-同位素离子查找.xlsx` | `17_B组同位素离子查找.csv` |
| 18 | `B组-A组80%离子与B组总离子比对分析.xlsx` | `18_B组80%离子和A组比对.csv` |

**已验证**：18 个 sheet 名全局唯一（每个都以 `A组`/`B组` 开头），因此加序号只为排序方便，不是为解决冲突。`dmf_sheet_name()` 的 31 字符截断是 Excel 限制，CSV 不需要——但为保持与 GUI 一致，仍沿用该函数处理非法字符。

序号是**固定映射表**，写死在 `csv_out.R` 里，不按运行结果动态生成。原因：`run.json` 与论文补充材料要引用文件名，动态编号一旦因输入变化而漂移，引用就断了。

### 6.2 多行表头怎么落

这是拆 sheet 唯一的真问题。现有 sheet 的 `header` 是**多行列表**：

```r
dmf_sheet(paste0(g, "总离子平均得分"),
          list(c("所有样品离子汇总", NA, NA, "样品编号必须大于2…"),   # 第 1 行：4 格，装饰+说明
               c("sample (No)", "RT", "RT&m/z", "mz", "总得分")),   # 第 2 行：21 格，与数据列对齐
          cols)                                                      # 21 列
```

规则：

1. **列名取最后一个表头行**——只有它与数据列一一对齐（21 = 21）。首行是分组标签与备注，长度常常不等（4 ≠ 21），无法作为列名。
2. **列名清洗**：`NA` → `V<序号>`；重名 → `make.unique()`（后缀 `.1`、`.2`）；前后空格去掉；换行符替换为空格。
3. **被丢弃的上层表头不丢信息**：全部写入 `schema.csv`（见 §6.3）。这是"信息完整"与"可直接 `read_csv`"之间的唯一折中。

### 6.3 列字典 `schema.csv`

每次运行一个文件，一行 = 一个输出列：

| 列 | 含义 |
|---|---|
| `csv_file` | 所属 CSV 文件名 |
| `sheet_name` | 原 sheet 名 |
| `workbook` | 原 xlsx 名（追溯用） |
| `col_index` | 在 CSV 中的列序（从 1 起） |
| `column_name` | CSV 里的列名 |
| `internal_key` | 原 `cols` 列表的键（如 `no_mz_total`） |
| `header_r1`, `header_r2`, … | 该列在各表头行上的原始文本（不足则空） |
| `dropped` | 是否因全空被丢弃（`TRUE`/空） |

有了它，`A组总离子平均得分.csv` 里叫 `sample (No)` 的列，能反查回内部字段 `no_int`，也能看到它归属"所有样品离子汇总"这一组。审稿人问"这一列是什么"，答案在这里。

### 6.4 空列处理

现有表里有两类空列：`dash1` / `dash2`（分隔用，列名 `-`，值全 NA），以及部分备注列。

**默认丢弃**，条件是「全部值为 NA」且「列名为 `-` 或空」。理由：CSV 没有视觉分组需求，一个名为 `-` 的全空列只会让 `read_csv` 多出一列 NaN，对 agent 是纯噪声。

丢弃不丢痕迹——`schema.csv` 里该行 `dropped=TRUE`，仍在。需要完整复刻 xlsx 时加 `--keep-empty-cols`。

### 6.5 编码与数值

- **UTF-8 无 BOM**（默认）。BOM 会让 pandas 把首列读成 `\ufeffsample`，这是 agent 侧最常见的坑。需要 Excel 直接双击打开时加 `--bom`。
- 用 `data.table::fwrite()`：短往返精度，`m/z`、`RT` 不会掉位数；`na = ""`；`quote = "auto"`（只在必要时加引号）。
- **禁止科学计数法**：`m/z` 与强度列统一按短往返格式输出，不转 `1.23e+05`。
- 缺失值统一为空串，不写 `NA`、不写 `0`。注意：原程序里 `dmf_or0()` 已把"未找到"写成 `0`，那是**算法语义**（原 Java 版 `NullCellValue = 0`），不是缺失，CLI 不改写。

### 6.6 是否还产 xlsx

默认**不产**。加 `--xlsx` 时额外调用现有 `dmf_write_sheets()` 产出原样 9 个 xlsx，供人核对。两者并存不冲突，因为 CSV 走新的 `csv_out.R`，xlsx 走原函数，互不影响。

---

## 7. MCP 层

`mcp/server.py`，stdio，不做任何分析逻辑：

```
tool call → 参数校验 → 拼 argv → subprocess(Rscript cli/dmf.R ... --json)
         → 解析信封 → 返回 {content, isError}
```

| MCP 工具 | 映射 |
|---|---|
| `dmf_doctor` | `doctor` |
| `dmf_inspect` | `inspect` |
| `dmf_run_diff` | `diff` |
| `dmf_msg_extract` | `msg-extract` |
| `dmf_msg_match` | `msg-match` |
| `dmf_rt_apex` | `rt-apex` |
| `dmf_job` | `job` |

注册写入 `~/.workbuddy/mcp.json`，需在连接器页面点"信任"。给合作者的配置样例写入 `docs/agent/MCP_SETUP.md`。

---

## 8. 面向合作者的可移植性

| 障碍 | 处理 |
|---|---|
| R 版本不一致 | `doctor` 检查 R ≥ 4.3，输出缺失清单 |
| `rawrr` 需 .NET Runtime | 仅 `.raw` 需要；缺失时提示改用 mzML |
| `mzR` 需编译链 | Windows 有二进制；Linux/macOS 写清 BiocManager 步骤 |
| 参数漂移 | `--params` 键名强制沿用 `config.R` |
| 环境复现 | `renv.lock`（可选）或 `Dockerfile`（仅 mzML 路线） |

分发包 `DMetFinder-agent-v1.0.3.zip`：含 `cli/ R/ demo_data/ docs/agent/ setup.R`，不含 `www/ figures/ data_for_paper/`。

---

## 9. 论文可复现性

`run.json` 含版本、commit、参数哈希、每个输入的 sha256、每个输出的 sha256。

> All DMetFinder analyses were performed with version 1.0.3 (commit a1b2c3d); the exact parameter set and SHA-256 checksums of all inputs and output tables are recorded in the `run.json` accompanying each analysis.

---

## 10. 测试与验收

| 测试 | 断言 |
|---|---|
| `test_cli_contract.R` | 每个子命令在 `demo_data/` 跑通，输出符合信封 schema |
| `test_csv_split.R` | **sheet 数 = CSV 数**；18 个文件全部生成；列名无重复、无 `NA` |
| `test_csv_fidelity.R` | 每个 CSV 的行数/列数与原 sheet 数据块一致（扣除 `--keep-empty-cols` 影响） |
| `test_cli_errors.R` | 缺参数→1；坏文件→2；警告→4 |
| `test_mcp_smoke.py` | 7 个工具各调一次，`ok=true` |

**硬验收**：`diff` 在 `demo_data/` 上跑出的 18 个 CSV，逐表与 Shiny 产出的对应 sheet 数据块逐单元格一致（列名按 §6.2 规则比对，空列按 §6.4 规则解释）。这是"共用 core"成立的唯一证据。

---

## 11. 分期

| 期 | 内容 | 改动面 | 状态 |
|---|---|---|---|
| **P0** | `cli/` 骨架 + `doctor` + `inspect` + `diff` + `csv_out.R` + `run-dmf.bat` | 全新文件 | **已完成**（18/18 CSV 逐格一致，40.9M 单元格） |
| **P1** | `msg-extract` / `msg-match` / `rt-apex` + `job` | 新 CLI 命令 | 未开始 |
| **P2** | `mcp/` + 注册 | 全新文件 | 未开始 |
| **P3** | 分发包、`renv.lock`、合作者文档 | 打包脚本 | **已完成**（zip 24 MB，解压后产物与项目内逐字节相同） |
| 待定 | 峰质量接入（等第三页冻结） | 新增 `pq_run_job.R` | 未开始 |

P0 零风险：主流程本就是纯函数，只加新文件。

---

## 12. 已知取舍

| 取舍 | 代价 | 缓解 |
|---|---|---|
| 多行表头压成一行 | 首行的分组语义在 CSV 里不可见 | `schema.csv` 完整保留 |
| 默认丢弃全空列 | CSV 列数与 xlsx 不同 | `schema.csv` 标注 `dropped`；`--keep-empty-cols` 可恢复 |
| 默认无 BOM | Excel 双击可能乱码 | `--bom`，并在文档里写明"Excel 用导入" |
| 不做 R 包 | 合作者不能 `library()` | `dmf.R` 单入口 + `setup.R` |
| 不接峰质量 | agent 用不到第三页 | 待冻结后增量补，结构已预留 |
| 不搬 MSGeter 函数 | 从 server 文件借函数，语义别扭 | `core_load.R` 注明；可选整理 |

---

## 13. 已定与待定

已定：

- CSV 文件名加两位序号，固定映射（§6.1）
- `--xlsx` 保留，默认不产
- 峰质量本期不接入

待定：

1. **`inspect` 做到哪层**：A（结构层，含在 P0，推荐先做）/ A+B（元数据层，+1 天）/ A+B+C（加 TIC 交叉验证，再 +1–2 天）。见 §4.6。

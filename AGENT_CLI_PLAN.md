# DMetFinder Agent 层：P0 实施计划

> 本文是 `AGENT_CLI_SPEC.md` 的执行版，供逐条核对。
> 范围：P0（`doctor` / `inspect` A 层 / `diff` / `version`）。P1（MSGeter）不在本文。
> 铁律：**不修改任何现有文件**。全部为新增。

---

## 1. 交付物

```
DMetFinder/
├── cli/
│   ├── dmf.R                       ~240 行   唯一入口、subcommand 分发
│   ├── lib/
│   │   ├── core_load.R             ~70 行    source 计算层 + 注入写盘接缝
│   │   ├── args.R                  ~70 行    手写参数解析（不引入 optparse）
│   │   ├── envelope.R             ~130 行    JSON 信封、退出码、错误对象
│   │   ├── csv_out.R              ~200 行    ★ sheet -> CSV、表头扁平化、schema.csv
│   │   ├── inspect_xlsx.R         ~160 行    A 层结构检查
│   │   ├── doctor.R               ~110 行    环境自检
│   │   └── util.R                  ~70 行    路径、sha256、UTF-8、原子写
│   └── run-dmf.bat                 ~30 行    Windows 环境固化
└── docs/agent/
    └── CLI_CONTRACT.md            ~120 行    给合作者看的用法
```

P0 合计约 1200 行，全部是新文件。`mcp/` 与 `job.R` 留到 P2/P1。

---

## 2. 三个关键实现决策

### 2.1 写盘接缝（最重要，请重点核对）

`dmetfinder_run()` 内部调用 `dmf_write_sheets()` 写 xlsx，**全文件只有一处调用**（第 1439 行的局部函数 `w()`）。这意味着我们不需要复制编排，只需要替换写盘实现。

做法：CLI 把 core 源码载入一个独立 environment，然后在这个 environment 里**重新定义** `dmf_write_sheets`：

```r
core <- new.env(parent = globalenv())
sys.source("R/config.R",               envir = core)
sys.source("R/dmetfinder_functions.R", envir = core)

# 注入：同一签名，写 CSV 而不是 xlsx
core$dmf_write_sheets <- function(sheets, path) {
  dmf_csv_write_sheets(sheets, path, ctx)   # ctx 携带 out_dir / seq 表 / 选项
  invisible(path)
}
```

R 的词法作用域保证 `dmetfinder_run()` 里那句调用解析到注入版本——它不是猴子补丁，是标准的依赖注入。

**为什么不用更直白的办法**：另一个选择是把 `dmetfinder_run()` 的 45 行编排复制到 CLI，跳过写盘。但那 45 行里有分组顺序、进度分段（0 / 0.42 / 0.84）、跨组比对方向（ab 与 ba 互为镜像）这些极易漂移的细节，复制一份迟早不同步。接缝只有一个点，复制是 45 个点。

**代价**：读代码时略绕，必须在 `core_load.R` 顶部写清注释；`res$files` 返回值会是 csv 路径，CLI 不依赖它（自己收集）。

### 2.2 不引入 optparse

`optparse` 未安装。自写 `args.R`（约 70 行）处理 `--key value`、`--key=value`、`--flag`，零依赖，且错误信息可定制（能提示"你是不是想写 --out"）。

### 2.3 不写后再删

不采用"先让 `dmetfinder_run` 写 xlsx 到 temp 再读回来转 CSV"的做法。原因：18 个 sheet 里最大的"离子分布初筛"有 48 万行，openxlsx 写一遍要数分钟，读回来又会引入浮点格式化的二次风险。接缝方案直接跳过写 xlsx。

`--xlsx` 时例外：同时调用原 `dmf_write_sheets` 与本实现，两份产物并存。

---

## 3. 逐文件设计

### 3.1 `cli/dmf.R`

```
Rscript cli/dmf.R <command> [options]
```

| 命令 | P0 |
|---|---|
| `doctor` | ✓ |
| `inspect` | ✓ |
| `diff` | ✓ |
| `version` | ✓ |

主流程固定为：`解析参数 → 建立 ctx → 执行 → 组装信封 → 写 run.json → 按退出码 exit()`。
所有命令共用同一个 `main()`，异常统一被 `tryCatch` 包住，转成 `ok:false` 信封 + 退出码 3。

### 3.2 `cli/lib/core_load.R`

只 source 两个文件：

```r
R/config.R
R/dmetfinder_functions.R
```

已核实：`dmetfinder_functions.R` 的外部依赖只有 `openxlsx::`、`readxl::`、`stats::`，无 dplyr / data.table / tidyr 裸调用。因此 `diff` 命令对环境的依赖极轻——这对合作者部署是加分项。

同时在此定义 `ctx`（输出目录、序号表、选项），并提供 `dmf_csv_write_sheets()` 的注入。

### 3.3 `cli/lib/args.R`

```
parse_args(argv, spec)
```
`spec` 声明每个参数的名称、是否带值、默认值。返回 named list + `unknown` 列表。
未知参数 → 退出码 1，并给出最接近的合法参数名（编辑距离）。

### 3.4 `cli/lib/envelope.R`

```r
env_new(command, ctx)                 # 初始化信封
env_add_input(env, role, path)        # 记录路径 + sha256 + bytes
env_add_output(env, role, path, sheet, rows, cols)
env_add_warning(env, code, message, n)
env_finish(env, status)               # 补 duration、写 run.json
env_error(code, message, hint)        # 构造失败信封
```

`sha256` 用 `digest::digest(file = path, algo = "sha256")`——已确认 `digest` 与 `openssl` 均已安装，无需外部依赖，无需调 `certutil`。

### 3.5 `cli/lib/csv_out.R`（核心）

```r
dmf_csv_write_sheets(sheets, workbook_path, ctx)
dmf_flat_header(header, ncol)          # 多行表头 -> 单行列名
dmf_drop_empty(cols, names, keep)      # 全空列处理
dmf_write_one_csv(cols, names, file)   # fwrite 封装
dmf_append_schema(...)                 # 累积 schema.csv 行
```

`dmf_flat_header()` 规则（已在 spec §6.2 定，此处是伪代码）：

```
h <- header[[length(header)]]          # 只取最后一行
补/截断到 ncol
NA 或 "" -> paste0("V", i)
trimws；换行 -> 空格
make.unique()
```

`dmf_write_one_csv()` 用 `data.table::fwrite(..., na = "", quote = "auto")`，
若 `ctx$bom` 则前置 `\ufeff`。
**注意**：`data.table` 虽已安装，但 `core_load` 不加载它——`csv_out.R` 里用 `data.table::fwrite` 全限定调用，避免污染 core 环境。

### 3.6 `cli/lib/inspect_xlsx.R`

只做 A 层（结构），不读谱图。见 §5 判定规则。

---

## 4. CSV 落地细节

### 4.1 序号表的来源

不手工维护 18 条字符串。序号由**遍历顺序**推出：

```r
res <- dmetfinder_run(...)            # 返回 $sheets
ord <- list(res$sheets$A,             # 7 个：筛选3 + 打分3 + 同位素1
            res$sheets$compare_ab,    # 1
            res$sheets$diff_ab,       # 1
            res$sheets$diff_ba,       # 1
            res$sheets$B,             # 7
            res$sheets$compare_ba)    # 1
```

这与 `dmetfinder_run()` 的写盘顺序**完全一致**，因此序号天然对齐，不需要第二份映射表。序号 = 展平后的下标，两位补零。

这条是相对 spec 的改进：spec 里写"固定映射表写死"，现在发现顺序可以直接从返回值推出来，**更不容易错**——但仍要加一个断言：展平后必须是 18 个，且名称与预期清单逐个相等，不等就报错（防止将来 `dmf_process_group` 增删 sheet 而序号静默漂移）。

### 4.2 文件名

`<NN>_<清洗后的 sheet 名>.csv`
清洗只针对文件系统非法字符 `\ / : * ? " < > |`，不做 31 字符截断。
落在 `<out>/tables/`。

### 4.3 `schema.csv`

每次运行一个，列：

`csv_file, seq, sheet_name, workbook, col_index, column_name, internal_key, header_r1, header_r2, header_r3, dropped`

`internal_key` 取自 `names(cols)`（如 `no_mz_total`）。这是 CSV 与源码之间唯一的语义桥梁。

### 4.4 空列判定

丢弃条件：该列**全部为 NA** 且（列名为 `-` 或空）。
`--keep-empty-cols` 关闭此行为；无论是否丢弃，`schema.csv` 都记录该列并以 `dropped` 标注。

---

## 5. `inspect` A 层判定规则（请重点核对阈值）

输入：`--in <xlsx>`。输出：JSON + `inspect.csv`。

| # | 检查项 | 判据 | 严重度 | 说明 |
|---|---|---|---|---|
| 1 | 文件可读 | `readxl::read_excel` 不抛错 | fatal | |
| 2 | 列数为块宽整数倍 | `ncol %% 6 == 0` | error | 不整除说明列数被改动或块错位 |
| 3 | 末块是否被静默丢弃 | `ncol %% 6 != 0` 时，尾部 `< 6` 列会被 `dmf_read_samples` 丢掉 | error | 与 #2 同源，单独报是因为后果不同：**数据静默缺失** |
| 4 | 块数 | `ncol %/% 6` | info | |
| 5 | 每块首行编号非数值 | `is.na(as.numeric(x))` | error | 该块会被整块丢弃 |
| 6 | 编号重复 | 组内重复 | error | 两样本会被当成一个 |
| 7 | 编号跳号 | 排序后差值 > 1 | **warning** | 实验设计可能本就不连续，只提示 |
| 8 | 空块 | 该块除首行外全为 NA，或离子数 = 0 | warning | |
| 9 | 每块离子数 | `nrow` 非空行 | info | 同时给出组内中位数 |
| 10 | 离子数离群 | 某块 < 组内中位数的 10% | warning | 疑似读取不全或样品失败 |
| 11 | 首列为空 | 第一块首行无编号 | error | 对应 `starts` 全被过滤 |

严重度含义：`fatal` 立即退出码 2；`error` 计入 errors，退出码 2 但报告完整；`warning` 退出码 4。

**这一层不做的**：不碰 raw/mzML、不算 TIC、不判组别互换。那些是 B/C 层。

---

## 6. 执行顺序（每步可独立核对）

| 步 | 内容 | 验证方式 |
|---|---|---|
| 1 | `args.R` + `envelope.R` + `util.R` | `dmf.R version --json` 输出合法 JSON |
| 2 | `doctor` | 在干净 R 会话里跑，能报出缺失包 |
| 3 | `core_load.R` + 接缝 | `Rscript -e 'source("cli/lib/core_load.R"); ls(core)'` 能看到 `dmetfinder_run` |
| 4 | `csv_out.R` | 用 `demo_data/groupA.xlsx` 单组跑，产出 3+3+1=7 个 CSV |
| 5 | `diff` | 完整跑 demo，产出 18 CSV + schema.csv + run.json |
| 6 | `inspect_xlsx.R` | 用 demo 正常文件 + 手工造 3 个坏文件验证不误报 |
| 7 | `run-dmf.bat` | 双击/命令行均可，中文路径不乱码 |

第 5 步是本计划的验收点：**18 个 CSV 与 `--xlsx` 产出的对应 sheet 逐单元格一致**。

比对脚本会写成 `tests/agent/test_csv_fidelity.R`：读 xlsx 的每个 sheet（`readxl`，`col_names = FALSE`，跳过表头行），读对应 CSV（`colClasses` 全字符），逐格比较 `format(x, digits = 15)`。空列按 §4.4 规则解释。

---

## 7. 风险与待定

| 风险 | 影响 | 处理 |
|---|---|---|
| 接缝被误解为猴子补丁 | 合作者不敢改 | `core_load.R` 顶部写 8 行注释说明这是依赖注入 |
| 18 个 sheet 顺序随版本变化 | 序号漂移，论文引用失效 | §4.1 的硬断言：名称逐项比对，不等即报错 |
| 中文字段名在 fwrite 下的编码 | 乱码 | 统一 utf8；`--bom` 兜底 |
| 48 万行 CSV 写入耗时 | 慢 | `fwrite` 是当前最快，实测后再看是否需要分块 |

`sha256` 一项已关闭：`digest` 与 `openssl` 均已安装，直接用 `digest::digest(file=, algo="sha256")`。

---

## 8. 与 spec 的差异（已改）

| 项 | spec | 本次计划 | 原因 |
|---|---|---|---|
| 序号表 | 写死 18 条映射 | 从返回值遍历推出 + 断言 | 少一份会漂移的手工表 |
| `--xlsx` | 保留 | 保留 | 用户确认 |
| 峰质量 | 不接入 | 不接入 | 用户确认 |
| `inspect` | 待定 A/B | 只做 A | 用户确认 |

---

## 9. 请你核对的三处

1. **§2.1 接缝**——这是整个 P0 的技术核心，如果你觉得"注入写盘函数"太绕，我改成复制 45 行编排，代码更直白但会产生漂移。
2. **§5 判定规则表**——尤其第 7 条（编号跳号）定成 warning 而不是 error，以及第 10 条（离子数 < 中位数 10%）的阈值是否合理。这两条直接决定报告会不会误报。
3. **§4.1 序号来源**——用遍历顺序而非手工映射表，你认可的话我就按这个写。

---

## 10. 实施记录（P0 已完成）

### 10.1 与计划的差异

| 项 | 计划 | 实际 | 原因 |
|---|---|---|---|
| 写盘接缝 | 把 CSV 写出函数注入为 `dmf_write_sheets` | 注入**空实现**，run 结束后从 `$sheets` 统一写 CSV | 返回值已含全部 18 个 sheet；且让"写 CSV"只发生在一处，便于断言和统计 |
| 进程模型 | 单进程 | **父子进程**：`diff`/`inspect` 在子进程执行，父进程转发并判定退出码 | 见 10.2 |
| inspect 的 `n_col %% 6` 检查 | error | **删除** | demo 数据是 59 列（10×6−1，末尾空分隔列被 Excel 截掉），每次都会误报 |
| inspect 的跳号检查 | warning | warning + **密度守卫**（仅在 1..N 式序列中报） | demo 的样品号是 173/237/… 任意 ID，无条件报等于每次刷一条噪声 |
| 空列丢弃 | 每个文件一条 warning | 不产生 warning，只记 metric + `schema.dropped` | 否则每次运行退出码都是 4，警告信号失效 |
| `sha256` | 待定 | `digest::digest(file=, algo="sha256")` | `digest`/`openssl` 均已装 |

### 10.2 必须记录的坑

1. **R 4.6.0 / Windows 收尾崩溃。** `diff` 全量跑完后（产物与 run.json 均已落盘），
   进程在退出阶段 access violation：bash 里是 139，cmd.exe 里是 0xC0000005。
   同一流程平铺成脚本跑则不崩，说明与调用栈深度和大对象生命周期有关。
   解法：父子进程 + **退出码由 run.json 推导**，进程状态只用于发现异常。
   代价：stderr 多一行 `[note]`。

2. **`system2(..., env=)` 在 Windows 上直接失败**（status 5，子进程根本没起来）。
   改成本进程 `Sys.setenv()` 让子进程继承。

3. **Git Bash 继承的 `LOCALAPPDATA` 是 POSIX 路径**（`/c/Users/…`），R 因此找不到
   用户库，报 `there is no package called 'jsonlite'`。`run-dmf.bat` 里必须无条件
   重建为 `%USERPROFILE%\AppData\Local`。

4. **`csv_prepare` 的顺序陷阱。** 若先 `make.unique` 再判空列名，第 2、3 个 `-`
   会变成 `-_1`/`-_2` 而躲过丢弃，4 个分隔列只丢掉 1 个；末尾表头缺项还会被补成
   `V42`。必须先去重再丢列，并把 `^V[0-9]+$` 也算作"无名"。

5. **`schema.csv` 的 `workbook` 列必须与 `dmetfinder_run()` 的 sprintf 逐字一致**。
   初版把 `%s-筛选50%%和%s离子.xlsx` 写成了双 `g`，全表追溯断裂。

### 10.3 验收结果

```
tests/agent/test_csv_fidelity.R out/verify
待比对：18 个 sheet，来自 9 个 workbook
… 18 个全部 [ OK ] …
比对单元格总数：40,887,423
结论：全部一致，CSV 与原 xlsx 写出函数等价。
```

退出码实测：正常 0 / 缺参数 1 / 文件缺失 2 / 未知选项 1 / 目录非空 2 /
inspect 坏文件 2。两次独立运行产出的 18 个 CSV **逐字节相同**（确定性已验证）。

### 10.4 未做（按计划）

`mcp/`、`msg-extract` / `msg-match` / `rt-apex`、`pq-*`（峰质量未冻结）、
`renv.lock`、分发包。

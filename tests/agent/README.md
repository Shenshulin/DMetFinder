# tests/agent -- agent 调用层的验收测试

两个脚本，都对着**界面版的原始实现**比，不比自己。

| 脚本 | 验什么 | 需要什么 |
|---|---|---|
| `test_csv_fidelity.R` | `diff` 的 18 个 CSV 与原 xlsx 逐单元格相同 | `out/verify/`（带 `--xlsx` 跑一次 diff） |
| `test_msg_equiv.R` | `msg-extract` / `msg-match` / `rt-apex` 与 MSGeter 实现逐元素相同 | `tests/agent/fixtures/` + `out/msg1/` |

## 先准备

```bat
:: 1. diff 的对照产物（约 4 分钟）
cli\run-dmf.bat diff --a demo_data\groupA.xlsx --b demo_data\groupB.xlsx --out out\verify --xlsx

:: 2. MSGeter 的对照产物（读夹具，约 15 秒）
cli\run-dmf.bat msg-extract --ms-dir tests\agent\fixtures\ms --out out\msg1 --rt-min 1 --rt-max 4
```

## 再跑

```bat
Rscript tests\agent\test_csv_fidelity.R out\verify
Rscript tests\agent\test_msg_equiv.R .
```

两者都是"有一项不一致就非零退出"。`test_msg_equiv.R` 沿用了 CLI 的父/子进程
写法：子进程干活，父进程按输出里的汇总行判定退出码——因为 R 4.6.0 在 Windows
上处理完大对象后收尾可能 access violation（见 `docs/agent/CLI_CONTRACT.md` §7），
否则 CI 会看到一个假的 139。

## 夹具

`fixtures/` 下的文件不进 git（体积大），但可随时重建：

| 文件 | 怎么来 |
|---|---|
| `ms/slice.mzML` | 从任一 `.mzML` 截一段：`msconvert SampleA_1.mzML --mzML --outfile slice.mzML --filter "index 1350-1700"` |
| `peaks.csv` | 从 `out/msg1/tables/01_MS2_Group_Info.csv` 抽 40 行，m/z 加 ±0.002 抖动；其中 10 行故意挪出窗口 |
| `apex_peaks.csv` | 从 `out/msg1/tables/03_MS1_Group_All.csv` 取强度最高的 15 个峰 + 随机 10 个 |
| `bad_cols.csv` / `no_sample.csv` | 手工构造的坏表，只用于验证"列认不出要报错" |

`slice.mzML` 的内容（当前这份）：351 张谱、RT 2.714–3.403 min、48 张 MS1 + 303 张 MS2、
正离子、profile 数据（median Δm/z = 0.0025，会被 `read_ms_file()` 判为 profile 并
在读取时顺手 centroid）。

## 缺夹具时

`test_msg_equiv.R` 的第 2 项会打印 `[SKIP]` 并计入汇总，**不会假装通过**。
第 3、4 项依赖 `out/msg1/`，同理。

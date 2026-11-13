# RV32IM 乱序 CPU（OJ 提交版）

基于课程 CPU 2026 框架实现的双路分派/提交、按序退休的乱序（OoO）RV32IM 处理器。
外存范围 `0x00000000`–`0x0fffffff`，通过 AXI4-Lite 访问；向 `0x80000000` 写入完整
32 位结果退出。

参考来源与本地修改见 [rtl/ATTRIBUTION.md](rtl/ATTRIBUTION.md)，设计与实测细节见
[docs/design-report.md](docs/design-report.md)。

## 本地实测

| 指标 | 结果 |
| --- | ---: |
| 官方正确性（延迟 10） | 19/19 |
| 官方 IPC 几何平均（延迟 10） | 1.1837 |
| 总面积（Yosys + ASAP7，含 SRAM） | 11,507.526 µm² |
| 估计最高频率 | 332.79 MHz |
| 定向 RV32IM / 地址范围回归 | 108/108 |
| AXI 独立通道背压回归 | 12/12 |

默认综合目标为 2 ns（500 MHz），估计最小周期约 3.0049 ns；以上为本地结果，
不代表 OJ 得分。

## 仓库结构

```text
.
├── Makefile                    # 统一入口：build / test / perf / synth / code
├── config.mk                   # 工具路径与本地参数（保持机器无关）
├── verilog/
│   ├── filelist.f              # [OJ 必需] RTL 文件列表
│   ├── ooo_cpu.v               # [OJ 必需] 生成的 Verilog，顶层 student_top
│   └── ooo_cpu.metadata.json   # 源文件与生成文件哈希
├── rtl/                        # [源码] 可编辑 SystemVerilog 与导出/回归脚本
│   ├── ooo/*.sv
│   ├── export_ooo.py
│   └── ATTRIBUTION.md
├── scripts/                    # [框架] 构建与仿真脚本（请勿修改）
├── testcases/                  # [框架] 官方测试用例（git submodule）
├── docs/
│   ├── design-report.md        # [报告] 设计与实测
│   ├── axi4-lite.md            # [框架] 总线规范
│   ├── sram.md                 # [框架] SRAM 规范
│   └── course-requirements-zh.md
├── Dockerfile                  # 可选工具链容器
└── .gitmodules                 # testcases 子模块
```

生成目录 `build/` 和 OJ 入口 `code` 已被 `.gitignore` 忽略，不进入仓库。
历史完整日志、参数实验与旧实现保存在 `archive/main-pre-oj` 分支。

## 快速开始

需要 Python 3.10+、GNU Make、G++（C++17）以及以下任一工具链：

- 课程 AppImage：`cpu2026-tools-x86_64.AppImage` 放在仓库根目录；或
- 原生 `verilator` / `yosys` / `abc` / `sta`，在 `config.mk` 中指定路径；或
- Docker：`docker build -t cpu2026 . && docker run --rm -it -v "$PWD":/work cpu2026 bash`

```sh
git submodule update --init --recursive

make code          # 编译 RTL 并生成 OJ 入口 ./code（等价于直接 make）
make test          # 官方正确性 19 项
make perf          # 官方性能与 IPC 几何平均
make synth         # Yosys + ASAP7 + OpenSTA 面积/频率
```

常用覆盖参数：`JOBS=8`、`Case=correctness_pi`、`LATENCY=20`、
`MAX_CYCLES=100000000`、`WAVE=trace.vcd`、`LOG=run.log`。

## 提交到 OJ

1. 确认 `verilog/filelist.f` 中的 RTL 路径完整，顶层模块名为 `student_top`，
   端口与 `docs/axi4-lite.md` 一致。
2. 在仓库根目录执行 `make code`，重新生成 `./code` 并做本地冒烟。
3. 提交本仓库（OJ 会使用其工具链执行构建并收集 `./code`）。
   若 OJ 要求直接上传可执行文件，则上传 `./code`。

提交前建议至少通过 `make test` 与 `make perf`。

## 参数与源码

可编辑源码位于 `rtl/ooo/`，修改后重新导出提交文件：

```sh
python3 rtl/export_ooo.py      # 需要固定版本的 sv2v，见 rtl/bootstrap_sv2v.py
make build
```

主要参数在 [rtl/ooo/student_top.sv](rtl/ooo/student_top.sv)：

| 参数 | 默认值 | 说明 |
| --- | ---: | --- |
| `ISSUE_WIDTH` / `COMMIT_WIDTH` | 2 / 2 | 每拍分派 / 退休宽度 |
| `INTEGER_PORTS` | 2 | 整数执行端口数（另有独立访存端口） |
| `ROB_DEPTH` | 16 | ROB 深度，同时决定在途结果容量 |
| `RS_DEPTH` | 2 | 每组发射队列深度 |
| `CHECKPOINTS` | 4 | 分支检查点数 |
| `LOAD_SLOTS` / `STORE_BUF_DEPTH` | 8 / 16 | 在途 load / store 队列容量 |
| `ICACHE_BYTES` / `DCACHE_BYTES` | 1024 / 2048 | 缓存容量（字节） |
| `DCACHE_WAYS` | 2 | D-cache 相联度 |
| `DCACHE_LINE_BYTES` / `DCACHE_BANKS` | 128 / 4 | D-cache 行大小与 SRAM bank 数 |
| `Q_DEPTH` | 4 | 取指 FIFO 深度 |
| `BHT_ENTRIES` / `BTB_ENTRIES` | 128 / 32 | 分支预测表大小 |
| `LSU_PIPELINE` | 0 | 可选访存流水级 |
| `RAM_BYTES` | 268435456 | 课程内存范围，提交时保持不变 |

`make synth` 的面积与时序结果写入 `build/synth/`（`MODE=opt|diagnose`）。

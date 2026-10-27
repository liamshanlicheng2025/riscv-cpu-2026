# RV32IM 乱序 CPU

本项目使用双路分派/提交、两个整数执行端口和独立访存端口，支持 RV32IM、按序退休、分支恢复与课程 AXI4-Lite 接口。外存范围为 `0x00000000`–`0x0fffffff`，向 `0x80000000` 写入完整 32 位结果退出。

本轮以用户指定的 [Galuisss/ACM-CPU](https://github.com/Galuisss/ACM-CPU) Area-v2 为基础移植新核心，扩展地址范围、补充缓存相联度参数，并根据本地时序结果调整控制状态与缓存配置。原 CPU 保留供对比。来源和具体修改见 [参考说明](rtl/ATTRIBUTION.md)；课程原始要求保留在 [course-requirements-zh.md](docs/course-requirements-zh.md)。

## 版本与分支

原单发射顺序五级流水版本保留在 `baseline/inorder-single-issue`（`ff5ac8a`），
独立目录为 `D:\cpu\RISC-V-CPU-2026-inorder`。
本 README 和优化代码属于 `feat/ooo-optimized` 分支，当前目录为 `D:\cpu\RISC-V-CPU-2026`。
本轮不移动或提交到 `main`；版本关系见 [设计报告](docs/design-report.md)。

## 本地验证

2026-10-26，使用原课程 Verilator、Yosys + ASAP7 和 OpenSTA 流程，无综合后处理。

| 指标 | 当前默认实现 | README 阶段 3 门槛 |
| --- | ---: | ---: |
| 官方正确性，内存延迟 10 | 19/19 通过 | 全部通过 |
| 官方 IPC 几何平均，延迟 10 | 1.1837 | ≥1.0985 |
| 总面积，含 SRAM | 11,479.036 µm² | ≤36,000 µm² |
| 估计最高频率 | 305.76 MHz | ≥300 MHz |
| RV32M 边界和完整地址范围回归 | 108/108 通过 | 补充验证 |
| AXI 独立通道背压和响应归属回归 | 12/12 通过 | 补充验证 |

这些结果满足本地阶段 3 门槛，不代表提前获得 OJ 分数。默认综合目标仍为 2 ns；估计最小周期约 3.2705 ns，**不满足 500 MHz，也没有频率加分依据**。参数对比和复现实验见 [设计与实测报告](docs/design-report.md)。

## 架构

- 前端：1 KiB 直接映射 I-cache、4 项取指 FIFO、128 项方向表、32 项 BTB 和 4 个分支检查点。
- 后端：16 项 ROB、三组各 2 项队列；两个整数端口选择就绪指令乱序执行，访存按序发出。
- 重命名：使用 ROB 槽号作为结果标签，32 项体系结构寄存器加 16 项在途结果槽。没有独立 PRF/空闲物理寄存器列表，ROB 大小也决定有效结果容量。
- 访存：8 项在途 load、16 项 store 队列、4 个 D-cache miss 状态项；支持 store 转发和错误路径取消。
- D-cache：2 KiB、两路、128 B 行、4 个同步 SRAM bank；写穿透、写不分配、关键字优先返回。
- 退休：最多每拍两条，store 外部副作用受提交控制；退出写等待先前事务排空及 AXI B 响应。
- 时序：前端恢复和访存地址选择各有同步的局部状态副本，降低控制扇出，没有额外恢复周期。

## 构建与测试

在 Linux 或 WSL2 下，从项目根目录运行。沿用课程 `cpu2026-tools-x86_64.AppImage`，宿主需要 Python 3、GNU Make、G++ 和 binutils。生成的 Verilog 已包含在仓库中，正常构建不需要 sv2v。

```sh
make build JOBS=8
make test
make perf
make synth

# 额外延迟和定向验证
make test LATENCY=20
make perf LATENCY=20
python3 rtl/regress.py --sim build/sim
python3 rtl/test_axi.py

# 生成 OJ 入口 ./code
make code
```

`config.mk` 将本地默认周期上限设为 `100000000`，以容纳完整 pi 等程序。这只调整超时上限，不改变测试程序、结果比较或 IPC 计算。命令行可以覆盖此值；官方 `scripts/` 和测试用例未修改。

## 参数与源码

编辑 [rtl/ooo/student_top.sv](rtl/ooo/student_top.sv)，然后重新生成提交文件。

| 参数 | 默认值 | 说明 |
| --- | ---: | --- |
| `ISSUE_WIDTH` | 2 | 每拍分派宽度，1 或 2 |
| `COMMIT_WIDTH` | 2 | 每拍退休宽度，1 或 2 |
| `INTEGER_PORTS` | 2 | 整数发射端口数，1 或 2；另有独立访存端口 |
| `ROB_DEPTH` | 16 | 8–128 的二次幂；在途结果槽数随之改变 |
| `RS_DEPTH` | 2 | 每个队列深度，至少 2 的二次幂 |
| `CHECKPOINTS` | 4 | 分支检查点数，至少 2 的二次幂 |
| `LOAD_SLOTS` / `STORE_BUF_DEPTH` | 8 / 16 | 在途 load / store 队列容量 |
| `ICACHE_BYTES` / `DCACHE_BYTES` | 1024 / 2048 | 缓存容量，字节数，使用合法二次幂配置 |
| `DCACHE_WAYS` | 2 | 1 或 2；容量不变，组数随相联度改变 |
| `DCACHE_LINE_BYTES` / `DCACHE_BANKS` | 128 / 4 | D-cache 行大小和 SRAM bank 数 |
| `Q_DEPTH` | 4 | 取指 FIFO 深度，至少 2 的二次幂 |
| `BHT_ENTRIES` / `BTB_ENTRIES` | 128 / 32 | 分支预测表大小 |
| `LSU_PIPELINE` | 0 | 可选访存流水级；本地对比后默认关闭 |
| `RAM_BYTES` | 268435456 | 课程内存范围；提交时保持此值 |

`verilog/params.vh` 仅供旧 CPU 使用。

```sh
# 仅重新导出源码时需要安装固定版本的转换器
python3 rtl/bootstrap_sv2v.py
python3 rtl/export_ooo.py
make build

# 隔离构建参数变体，不覆盖默认提交文件
python3 rtl/sweep.py --jobs 8
```

`verilog/filelist.f` 仅包含 `ooo_cpu.v`，顶层仍为 `student_top`，端口与课程一致。`ooo_cpu.metadata.json` 记录源文件和生成文件哈希。修改 SystemVerilog 后必须重新导出，不能继续测试旧 Verilog。

旧实现可以单独运行：

```sh
make build FILELIST=verilog/filelist_legacy.f BUILD=build/legacy
make test SIM=build/legacy/sim
make perf SIM=build/legacy/sim
```

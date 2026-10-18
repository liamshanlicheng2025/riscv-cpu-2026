# RISC-V CPU 设计文档（乱序执行 + 参数化版）

> 本文档描述当前 `verilog/` 下 CPU 的架构、参数化方式和实测结果。

## 1. 总体结构

前端预取 + 取指队列，后端 Tomasulo 风格动态调度、ROB 按序提交：

```text
        +-------------------------------------------------------------+
        |  I-Cache (LINES x 16B, WAYS-way set associative)            |
        +-------------------------------------------------------------+
                 ^ pc_f / pc_id
        +-------------------------------------------------------------+
        |  4-deep Fetch Queue + FAT/BHT + RAS                         |
        +-------------------------------------------------------------+
                 ^ dispatch 1~2 条/拍
        +-------------------------------------------------------------+
        |  RAT / 空闲列表 / PRF(128 物理项, 可配置可用数)              |
        |  RS(16) + MOB(16) + ROB(32)                                 |
        |  port0 全功能    port1 简单 ALU    load 专用通道             |
        |  CDB A/B/load 三路唤醒                                      |
        +-------------------------------------------------------------+
                 ^ 按序 commit
        +-------------------------------------------------------------+
        |  D-Cache (LINES x 16B, WAYS-way set associative)            |
        |  Store Buffer (写穿, 可配置深度) -> AXI4-Lite               |
        +-------------------------------------------------------------+
```

| 模块 | 文件 | 职责 |
|---|---|---|
| 顶层/后端 | `verilog/student_top.v` | 取指队列、译码、重命名、RS/ROB/MOB/PRF、分支预测、AXI 仲裁 |
| I-Cache | `verilog/icache.v` | 参数化容量/相联度，同步 SRAM，顺序预取（仅 1 路时） |
| D-Cache | `verilog/dcache.v` | 参数化容量/相联度，写穿、store-miss 不分配、关键字优先 |
| Store Buffer | `verilog/storebuf.v` | 参数化深度的写穿 FIFO |
| 除法器 | `verilog/divider.v` | 16 拍 radix-4 迭代除法 |
| 参数头 | `verilog/params.vh` | 所有可扫描参数的默认值 |

## 2. 参数化

参数默认值集中在 `verilog/params.vh`，通过 `` `include "verilog/params.vh" `` 注入顶层。修改该文件后重新运行 `make build` / `make test` 即可扫描。

| 参数 | 默认值 | 支持范围 | 说明 |
|---|---:|---|---|
| `ISSUE_WIDTH` | 2 | 1 / 2 | 发射宽度；1 时关闭第二个 dispatch/issue/commit 槽 |
| `ROB_DEPTH` | 32 | 16 / 32 | ROB 有效深度（物理阵列 32 项） |
| `PRF_SIZE` | 64 | 64 / 96 / 128 | 可分配物理寄存器数（物理阵列 128 项，7 位 tag） |
| `RS_DEPTH` | 16 | 8 / 16 | 保留站有效深度 |
| `MOB_DEPTH` | 16 | 8 / 16 | 访存顺序缓冲有效深度 |
| `Q_DEPTH` | 4 | 2 / 4 | 取指队列有效深度 |
| `ICACHE_LINES` | 256 | 2 的幂 | I-Cache 总行数（16B/行） |
| `DCACHE_LINES` | 1024 | 2 的幂 | D-Cache 总行数（16B/行） |
| `ICACHE_WAYS` | 1 | 1 / 2 | I-Cache 相联度 |
| `DCACHE_WAYS` | 1 | 1 / 2 | D-Cache 相联度 |
| `STORE_BUF_DEPTH` | 8 | 2 的幂 | Store Buffer 项数 |

说明：

- ROB/RS/MOB/取指队列采用“最大物理阵列 + 有效深度限制”的方式，参数直接控制同时在飞指令数，便于快速做 IPC 敏感度扫描。
- Cache 的 `LINES` 与 `WAYS` 同时参数化；`SETS = LINES / WAYS`，因此 `LINES` 必须能被 `WAYS` 整除，且 `SETS` 建议为 2 的幂。
- 2 路 Cache 使用每 set 1 位 LRU。相联度大于 1 时暂时关闭顺序预取，避免填充/替换与在飞预取行互相干扰。
- `PRF_SIZE` 至少为 64；物理寄存器 tag 为 7 位，支持到 128 项。

## 3. 关键设计决策

- **乱序执行、按序提交**：RS 在操作数就绪后动态发射；ROB 在头部按序提交，分支/JALR 误预测时做 RAT 快照 + ROB/MOB/free-list 回滚。
- **双发射**：port0 负责分支、乘除、store、ALU；port1 负责简单 ALU；load 有独立发射通道。`ISSUE_WIDTH=1` 时仅保留 port0 和 load 通道。
- **寄存器重命名**：RAT + 快照；空闲列表按提交顺序回收旧物理寄存器。两槽分配时第二个槽的物理寄存器索引根据第一个槽是否真的写寄存器来选择，避免重复分配。
- **分支预测**：FAT 全相联目标表 + 2 bank BHT + 8 项 RAS；ID/pop 点复核，EX 解析，误预测冲刷。
- **访存顺序**：load 只有在 MOB 头部才能发射；store 提交时写 D-Cache 并压入 Store Buffer 写穿 AXI，保证 load/store 顺序和一致性。
- **CDB**：port0/div、port1、load 三路写回，RS 和 dispatch 旁路均支持三级唤醒。
- **Cache**：参数化组相联、关键字优先填充、store buffer 清空门控、2 路 LRU。

## 4. 验证结果（本机实测）

默认参数：

```text
ISSUE_WIDTH=2, ROB_DEPTH=32, PRF_SIZE=64,
RS_DEPTH=16, MOB_DEPTH=16, Q_DEPTH=4,
ICACHE_LINES=256, DCACHE_LINES=1024,
ICACHE_WAYS=1, DCACHE_WAYS=1
```

正确性：

```text
19 passed, 0 failed
```

性能（`LATENCY=10`，`MAX_CYCLES=20000000`）：

| 测试 | IPC |
|---|---:|
| perf_median | 0.5168 |
| perf_multiply | 0.5791 |
| perf_qsort | 0.6089 |
| perf_rsort | 0.8610 |
| perf_towers | 0.6674 |
| perf_vvadd | 0.5971 |
| **GEOMEAN** | **0.6300** |

参数敏感度（每组均通过 19/19 正确性测试）：

| 配置 | Issue | ROB | RS | MOB | PRF | I/D Cache | Ways | IPC GEOMEAN |
|---|---:|---:|---:|---:|---:|---|---:|---:|
| 默认 | 2 | 32 | 16 | 16 | 64 | 256/1024 | 1/1 | 0.6300 |
| 双发射 + 2 路 | 2 | 32 | 16 | 16 | 64 | 256/1024 | 2/2 | 0.6115 |
| 单发射 | 1 | 32 | 16 | 16 | 64 | 256/1024 | 1/1 | 0.4216 |
| 小配置 | 1 | 16 | 8 | 8 | 64 | 128/512 | 2/2 | 0.4208 |

趋势：

- 发射宽度从 2 降到 1，IPC 从 0.63 降到约 0.42，是最敏感的参数。
- 2 路 Cache 在关闭预取后 IPC 略降（0.6300 → 0.6115），说明当前基准下预取收益大于相联度收益。
- ROB/RS/MOB 缩到一半并配合单发射，IPC 与单发射默认配置接近，说明单发射时后端资源已不是主要瓶颈。

## 5. 已知短板与后续方向

1. **频率/面积**：尚未在 Yosys + ASAP7 下重新综合；当前重点是功能正确性和参数化，后续需用 `make synth` 扫描面积/频率。
2. **Cache 相联度**：目前只支持 1/2 路；2 路时预取关闭。后续可加入 4 路和更精细的替换策略，并修复预取与替换的交互。
3. **分支预测**：BHT 仍是 2-bit 局部预测，复杂循环下有限；可升级 GShare/TAGE。
4. **除法**：16 拍迭代除法在除法密集程序（pi 等）仍是瓶颈。
5. **物理阵列缩放**：ROB/RS/MOB/PRF 当前采用最大物理阵列 + 有效深度限制；若要让面积随参数明显变化，可继续把物理阵列和 tag 位宽完全参数化。

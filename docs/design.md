# RISC-V CPU 设计文档（五级流水线版）

> 本文档描述当前仓库 `verilog/` 下 CPU 的架构设计，供小组开发与报告撰写参考。

## 1. 总体结构

经典五级流水：**IF → ID → EX → MEM → WB**（WB 与 MEM 合并，MEM 级直接写寄存器堆）。

| 模块 | 文件 | 职责 |
|---|---|---|
| 顶层/流水线主控 | `verilog/student_top.v` | 流水线寄存器、译码、ALU、前递、停顿/冲刷控制、分支预测、AXI 仲裁 |
| I-cache | `verilog/icache.v` | 直接映射 256 行 × 16B，miss 流水化填充 + 顺序预取下一行 |
| D-cache | `verilog/dcache.v` | 直接映射 1024 行 × 16B，写穿 + store-miss 不分配，关键字优先 |
| Store buffer | `verilog/storebuf.v` | store 写穿透缓冲，流水线不被 AXI 写阻塞 |
| 除法器 | `verilog/divider.v` | 16 拍 radix-4 迭代除法（含除零/溢出特殊情况处理） |

## 2. 关键设计决策

### 2.1 存储系统（性能的决定因素）

仿真内存固定 10 拍延迟，所以 **Cache 是 IPC 的生命线**：

- **I-cache**：tag（256×20b）与 data（256×128b）分两片 `sram_fakeram`，valid 位用独立 reg 阵列（SRAM 无复位，必须自初始化）。每拍发 SRAM 读，下一拍出指令，命中零气泡；miss 时利用 AXI 从机 16 深队列**连续发 4 个读请求**流水化填充，并**顺带预取下一行**（流式取指局部性极强，miss 率减半）。
- **D-cache**：1024 行 × 16B。写穿（write-through）保证一致性简单；store miss 不分配（减少无用填充）。**关键字优先（critical word first）**：load miss 时目标字一到就直接放行给流水线，整行填充转后台。
- **Store buffer**：store 命中时同时写 SRAM 和压入 buffer 写穿到 AXI，流水线不停。填充前必须等 buffer 中落在目标行的写排空（`sb_clear`），否则会读到旧数据——这是最容易踩的一致性坑。
- **SRAM 单端口冲突**：MEM 拍 store 写 data SRAM 与 EX 拍 load 读冲突时，EX 停一拍。

### 2.2 分支预测（三件套）

1. **BTB/BHT 合并表**：一片 256 项 × 37 位 SRAM（valid + 类型 + target + 2bit BHT），IF 拍发读、ID 拍出结果，与指令数据同拍到达。
2. **FAT（IF 级跳转目标表）**：32 项全相联，命中即 0 气泡跳转。
3. **RAS**：8 项返回地址栈，call（rd=x1）压栈、ret（jalr x0, x1）弹栈。

预测在 ID 做出，EX 验证；预测失败冲刷两级（代价 2 拍）。JAL 在 ID 直接解析。错误预测只会被冲刷，不影响正确性。

### 2.3 冒险与前递

- MEM 级（含 load 的 SRAM 读出）与 WB 级**两级前递**到 EX 操作数，**无 load-use 气泡**。
- 流水线冻结：d-cache load miss、store buffer 满、填充占口时整条冻结。
- 高扇出控制信号（pipe_freeze 等）用 `(* keep *)` 手工复制多份分摊负载（ABC 不做高扇出缓冲，这是时序修复的关键手段）。

### 2.4 M 扩展

- **乘法**：单拍组合乘法器。MULHSU/MULHU 用"有符号×有符号 + 符号修正"技巧实现（`mul_uu_hi = mul_ss[63:32] + 修正项`），只综合出一个乘法器。
- **除法**：16 拍 radix-4 迭代除法器（每拍 2 位），前端停顿等待；除零/INT_MIN 溢出按 RISC-V 规范走特殊值快路径（启动拍寄存特殊结果，不占用前递链）。

### 2.5 AXI 仲裁

AR/R 通道由 I-cache 和 D-cache 共享，顶层仲裁器按 req 授权，填充方持权直到收完最后一个响应（`last_r`）。AW/W/B 通道归 store buffer 独占。

## 3. 验证结果（2026-09-27 实测）

- **正确性**：19/19 全部 PASS（pi/qsort/tak 超出默认 100 万周期上限，加大上限后分别为 12.1M / 1.26M / 1.26M 周期，结果全对）
- **性能**（`make perf`）：

| 测试 | IPC |
|---|---|
| perf_multiply | 0.884 |
| perf_rsort | 0.876 |
| perf_qsort | 0.755 |
| perf_towers | 0.758 |
| perf_median | 0.613 |
| perf_vvadd | 0.580 |
| **几何平均** | **0.7348** |

- **综合**（`make synth`，Yosys + ASAP7，目标 2.0ns）：
  - 总面积 **12,617 µm²**（组合 2,692 / 时序 1,606 / SRAM 8,320）——过阶段 2/3 的面积线（18000/36000），超阶段 1 的 9000
  - 估算频率 **214 MHz**（最小周期 4.67ns）——**未达 300 MHz 底线**，这是当前最大短板
  - 时序修复历程：35 MHz（高扇出未缓冲）→ 211 MHz（keep 复制 dcache/icache 高扇出网络 + fanbuf 缓冲模块）→ 214 MHz（除法特殊值路径从前递链上摘除）

## 4. 评分对照

| 阶段 | 面积要求 | IPC 要求 | 频率要求 | 当前状态 |
|---|---|---|---|---|
| 正确性 85 分 | — | — | — | ✅ 19/19 |
| 阶段 1 (90) | ≤9000 | ≥0.600 | ≥300MHz | IPC✓ 面积✗ 频率✗ |
| 阶段 2 (95) | ≤18000 | ≥0.845 | ≥300MHz | 面积✓ IPC✗ 频率✗ |
| 阶段 3 (100) | ≤36000 | ≥1.0985 | ≥300MHz | 面积✓ IPC✗ 频率✗ |

## 4. 已知短板与升级方向

1. **顺序单发射**：IPC 上限约 1，冲阶段 3（1.0985）必须上**双发射或乱序（Tomasulo + ROB）**
2. **D-cache 写穿**：写流量全打到 AXI；改**写回（write-back）+ dirty 位**可减少 AXI 写流量
3. **分支预测精度**：2bit BHT 对复杂循环嵌套有限，可换**全局历史（GShare/TAGE）**
4. **除法 32 拍**：pi 这类除法密集程序受影响大，可换基数更高的 SRT 除法

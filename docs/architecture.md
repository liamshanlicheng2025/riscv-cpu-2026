# CPU 架构详解与分工阅读指南

> 本文档详细剖析**五级流水线基线版**（commit `ff5ac8a`，正确性 19/19 全过）——它是理解本项目的最佳起点。
> 注意：`main` 分支的最新代码已演进为**乱序（OoO）版本**（其设计说明见 `docs/design.md`）。流水线版的完整代码可用 `git checkout ff5ac8a -- verilog/` 取出，或在 GitHub 上浏览该提交。
> 内容分三部分：① 一条指令的完整一生 ② 总体架构设计 ③ 按分工拆开的模块设计详解。
> 配套文件：`docs/design.md`（当前 OoO 版总览）、`docs/axi4-lite.md`（总线协议）、`docs/sram.md`（片上 SRAM 接口）。

**实测成绩**：正确性 19/19；IPC 几何平均 0.7348；面积 12,617 µm²（组合 2,692 / 时序 1,606 / SRAM 8,320）；估算频率 214 MHz。

---

# 第一部分：一条指令的完整一生

## 1.1 流水线总览

```
        ┌──── IF ────┐   ┌──── ID ────┐   ┌──── EX ────┐   ┌──── MEM ────┐
        │ pc_f 发给   │   │ 指令到货：  │   │ 前递选操作数│   │ load 取数/  │
 pc ──► │ I-cache    │ ─►│ 译码+读寄存器│ ─►│ ALU/乘除法 │ ─►│ store 写cache│──► 写回寄存器堆
        │ SRAM 读    │   │ 分支预测决策│   │ 分支解析验证│   │ 压store buf │
        └────────────┘   └────────────┘   └────────────┘   └─────────────┘
        预测器SRAM同拍读    FAT/RAS/BHT      误预测→冲刷IF/ID    （WB 合并在本级）
```

注意两个"合并"：WB 没有独立一级（MEM 级直接写寄存器堆）；I-cache 的 SRAM 是**同步读**——IF 拍发地址、ID 拍数据才到货，所以"指令"这个货实际上是跨越 IF→ID 边界运到的。

## 1.2 一条普通 ALU 指令的一生（如 `add a0, a1, a2`）

**第 1 拍（IF）**：`pc_f`（程序计数器）发给 I-cache 的 data SRAM 和 tag SRAM，同时发给预测器 SRAM（BTB/BHT 表）和 FAT（全相联跳转表）。这一拍 SRAM 在读，不出结果。

**第 2 拍（ID）**：三件事同时发生——
- SRAM 读出了：tag 比较命中 → `instr` 线上出现这条 `add` 的机器码；`pc_id` 寄存器此时正好等于它的地址
- 译码器（纯组合逻辑）把机器码拆开：opcode=OP、funct3=000、rs1=a1、rs2=a2、rd=a0，生成 ALU 操作码 `ALU_ADD`
- 寄存器堆读出 `rf[a1]`、`rf[a2]`。这里有个精巧设计：读口不是 32:1 大 mux（扇出灾难），而是**一热译码 + AND/OR 列读**——每个寄存器编号先译成 32 位一热信号，每一根一热线只驱动 32 个 AND 门（见 `student_top.v` L484-505 的注释）

这一拍末尾，所有字段锁存进 ID/EX 流水线寄存器。有一个容易忽视的旁路：如果 MEM 级本拍正在写 a1，ID 读到的是旧值，所以 ID/EX 寄存器直接从 `mem_wb_value` 旁路（L517-521）。

**第 3 拍（EX）**：前递 mux 检查：MEM 级有没有人要写 a1/a2？有就用 `mem_fwd` 顶替（这就是"前递"——数据不等写回寄存器堆就直接送过来）。然后进 ALU：`alu_a + alu_b` 算出结果。这一拍末尾锁存进 EX/MEM 寄存器。

**第 4 拍（MEM/WB）**：`rf_we` 拉高，`rf[a0] <= mem_wb_value`，时钟沿一过，结果落进寄存器堆。指令退休。

全程 4 拍，且理想情况下流水线满载，**每拍都有一条新指令完成**（IPC 趋近 1）。

## 1.3 一条 Load 指令的一生（如 `lw a0, 8(s0)`）

前两拍与 ALU 指令相同。

**第 3 拍（EX）**：ALU 算出访存地址 `s0+8`（组合逻辑 `alu_res`）。**关键**：这个地址本拍就直接发给 D-cache 的 tag+data SRAM 发起读（`ex_addr` 端口）——SRAM 需要一拍出数据。

**第 4 拍（MEM）**：SRAM 数据到货，组合判断 tag 命中：
- **命中**：从 128 位行里按地址低位选出目标字，按 LB/LH/LW 做符号/零扩展（`load_extend`），本拍写回寄存器堆。Load 实际只花 1 拍访存
- **未命中**：整条流水线冻结，D-cache 启动填充（见 3.2.2 节）。填充利用了**关键字优先**：AXI 读请求从 miss 的那个字开始发（行内回绕），目标字的响应一到（`crit_valid`），load 直接取走它完成，剩下的行填充满后台继续——流水线少等 3 拍

**与前递的配合**：load 的数据要到 MEM 拍才有，如果下一条指令在 EX 拍就要用这个数据怎么办？答案是 MEM 级前递把 `mem_load_ext`（SRAM 刚读出的数据）直接顶给 EX 的 mux——所以**没有 load-use 气泡**，这是本设计的一个卖点。

## 1.4 一条 Store 指令的一生（如 `sw a0, 0(s0)`）

**第 3 拍（EX）**：ALU 算地址，发 D-cache tag 读（注意：store 在 EX **只读 tag 不读 data**——为了避开 SRAM 单端口冲突）。

**第 4 拍（MEM）**：tag 命中判断：
- **命中**：本拍同时做两件事——① 用字节写掩码写 D-cache 的 data SRAM（SB/SH 只写对应字节）② 把地址+数据+掩码压入 **store buffer**
- **未命中**：只压 store buffer（写不分配策略）

**第 5 拍起（后台）**：store buffer 按 FIFO 顺序把写请求发往 AXI（AW/W 通道背靠背，每拍可发一项），收到 B 响应后弹出。**流水线不等待**——store 压入 buffer 就算完成，这是写穿不拖慢 IPC 的关键。

**一致性陷阱**（整个项目最微妙的地方）：如果 D-cache 正在填充某一行，而 store buffer 里还有没发出去的、属于这一行的写，直接填充会把旧数据盖过新写。所以填充被 `sb_clear` 信号门控：buffer 里有落在目标行的写就必须等。同理，填充期间落在填充行内的 store（`fill_clash`）也必须等填充完再按命中处理。

## 1.5 一条分支指令的一生（如 `bne a0, zero, loop`）——预测与赌注

分支是流水线的天敌：EX 拍才知道跳不跳，若不预测，每个分支都要等 2 拍。本设计是**预测 + 验证 + 冲刷**：

**第 1 拍（IF）**：FAT（32 项全相联跳转表）用 `pc_f` 做全相联比较。如果这条分支之前"跳过"（被学习过），FAT 当拍命中 → **0 气泡**直接把 `pc_f` 改成目标地址，下一拍取的就是目标指令。

**第 2 拍（ID）**：更精确的复核。译码发现是分支，查 BTB/BHT 表（IF 拍发起的 SRAM 读本拍到货）：2-bit 饱和计数器高位为 1 → 预测跳。如果 ID 的判决和 IF 的判决不一致，ID 重定向（代价 1 拍）。预测记录（`pred_taken`/`pred_target`/`bht` 旧值）随指令进入 EX。

**第 3 拍（EX）**：真相揭晓。前递后的操作数比较出 `br_taken`，和预测记录比对：
- **预测对**：无事发生，BHT 计数器更新（强化历史）
- **预测错**：`ex_redirect` 拉高——`pc_f` 强制改到正确地址，IF/ID 和 ID/EX 两级流水线寄存器的 valid 清零（冲刷错误路径上的 2 条指令），BHT 反向更新，FAT 中对应条目学习/失效

**三种跳转的特殊待遇**：JAL 目标在 ID 就能精确算出（无需进预测表）；JALR 调用（rd=x1）由 BTB/FAT 预测；函数返回（`jalr x0, 0(x1)`）由 **8 项 RAS 返回地址栈**预测——call 在 EX 压栈、ret 弹栈，这就是 `perf_towers`（汉诺塔，递归密集）IPC 能到 0.76 的原因。

## 1.6 一条除法指令的一生（如 `div a0, a1, a2`）

**EX 拍**：先查两个规范特殊值——除零（商全 1）和 INT_MIN/-1 溢出（商 INT_MIN）。特殊值在**启动拍就寄存下来**（`div_spec_r`/`div_spec_res_r`），这个设计是为了让 `div_req`/`div_stall` 不依赖前递后的 32 位比较（晚到信号，曾是关键路径）。

一般情况：`div_start` 脉冲启动 `divider`（**radix-4 迭代除法器，每拍算 2 位，16 拍完成**），流水线前端停顿（`div_stall`），EX 级被保持。注意保持期间前递源会排空，所以 EX 的 `ex_rs1v/ex_rs2v` 每拍捕获最新前递值（L547-552，这是个修过的 bug）。

**16 拍后**：`div_done` 拉高，结果经 `ex_result` mux 进入 MEM，流水线恢复。

**乘法**则是另一极端：单拍组合乘法器。MULH/MULHSU/MULHU 用一个 **33×33 有符号乘法器 + 符号修正公式**实现（`uu = ss + 2³²·(a₃₁·b + b₃₁·a)`），只综合出一个乘法器硬件。

## 1.7 程序的死亡（退出约定）

最后一条指令总是 `sw a0, 0(t0)`（t0=0x80000000）。它走 1.4 的 store 流程：D-cache 不会命中（该地址不在 cache 范围），store buffer 把它发到 AXI，仿真器看到 `awaddr=0x80000000 且 wstrb=4'hf`，在 B 通道握手成功的瞬间捕获 `wdata` 作为返回值、结束仿真，与 expected 比对。

---

# 第二部分：总体架构设计

## 2.1 设计哲学

仿真内存固定 10 拍延迟 → **一切性能决策围绕"少访问 AXI、访问了就别等"展开**：
- Cache 命中必须 1 拍（SRAM 同步读正好嵌进流水级）
- miss 填充必须流水化（利用 AXI 16 深队列连发，4 字一行 ≈ 14 拍而非 44 拍）
- store 必须不阻塞（store buffer 吸收写流量）
- 分支必须预测（不预测每个分支白等 2 拍）

## 2.2 停顿信号全集（流水线控制的骨架）

| 信号 | 触发 | 效果 |
|---|---|---|
| `pipe_freeze` | d-cache load miss / store buffer 满 / 填充占口 | **整条流水线冻结** |
| `div_stall` | 除法迭代中 | 前端停顿，EX 保持 |
| `lx_stall` | store(MEM) 写 data SRAM 与 load(EX) 读冲突 | EX 停一拍（SRAM 单端口限制） |
| `ic_stall` | i-cache miss / 填充中 | 前端停顿，ID 注气泡 |

优先级和互锁集中在 `student_top.v` L129-172，是全文最需要逐行读懂的控制逻辑。

## 2.3 时序工程（从 35 MHz 到 214 MHz 的三板斧）

1. **高扇出信号手工复制**：ABC 综合器不插缓冲树，`fill_wr` 曾单网线带 1029 个负载（17.8ns）。解法：`(* keep *)` 按消费组复制多份（`dcache.v` L99-103），或 `fanbuf` 模块（`keep_hierarchy` 硬边界）
2. **独热状态机**：d-cache 的 FSM 用独热编码，广播信号直接由单触发器输出，避免状态译码深锥
3. **晚到信号出链**：除法特殊值判断不再挡 `div_req`；寄存器堆读口用 AND/OR 列读替代 32:1 mux

## 2.4 AXI 通道所有权

- **AR/R（读）**：I-cache 和 D-cache 共享，顶层仲裁器（`ar_owner` 状态机）先到先得，持权到 `last_r`（收完最后一个响应）才释放
- **AW/W/B（写）**：store buffer 独占，rready/bready 常置 1

---

# 第三部分：分模块设计详解（按分工）

## 同学 A 板块：流水线核心 + 执行子系统

### A.1 译码器（`student_top.v` L198-257）

纯组合逻辑。三种产物：
- **字段切分**：opcode/funct3/funct7/rs1/rs2/rd
- **立即数生成**：U/J/B/S/I 五种类型的拼接+符号扩展（一个 5 路 mux，对照 RISC-V 手册 2.3 节读）
- **控制信号**：`d_aluop`（10 种 ALU 操作）、`d_regwrite`、`d_srcb_imm`、`d_srca_pc`、`d_mext` 等

学习要点：每条 `d_xxx` 信号都是"这一类指令在下游需要什么待遇"的答案。

### A.2 前递与冒险（L555-565）

```
fwd_a = (MEM级要写 ex_rs1) ? mem_fwd : ex_rs1v
```

只有 MEM 一级前递源（因为 WB 合并进了 MEM），却实现了无 load-use 气泡——因为 load 的数据在 MEM 拍开头就有（SRAM 读出），正好赶上 EX 拍末尾的锁存。**读懂 `mem_fwd` 的三路来源**（`mem_load_ext`/`mem_alu`）就懂了前递的全部。

### A.3 ALU 与乘除法（L567-613）

- ALU：10 种操作一个 case，注意 `ALU_PASSB`（LUI 直通）和 `$signed` 的使用
- 乘法：符号修正公式值得推导一遍（草稿纸 5 分钟）
- 除法器接口：`start` 脉冲 / `busy` / `done` / `result`，radix-4 迭代在 `divider.v` 里独立实现

### A.4 停顿与冲刷控制（L129-196, L448-475）

四条停顿线（见 2.2 表）+ 两级冲刷（`id_redirect` 1 拍代价、`ex_redirect` 2 拍代价）。重点理解：**为什么 i-cache 停顿时 ID 要注气泡而 d-cache 停顿时整条冻结**（前者指令根本没到货，后者指令都在只是不能前进）。

### A.5 寄存器堆（L477-505）

32×32 reg 阵列 + MEM 级单写口 + 一热译码 AND/OR 双读口。x0 永不写入（`mem_rd != 0` 检查）。

### A.6 除法器（`divider.v`，58 行）

恢复余数法的 radix-4 变体：每拍串联两个 radix-2 迭代（L23-29），16 拍完成 32 位。有符号数先取绝对值算、最后按 `q_neg`/`r_neg` 修正符号。`done`/`result` 是组合输出，最后一个迭代拍直接可用。

**A 板块毕业考题**：① 为什么 load-use 不需要停顿？② `lx_stall` 为什么只停 EX 而不是整条流水线？③ 分支误预测后，IF/ID 里的指令为什么必须杀掉而 EX 里的不用？

## 同学 B 板块：存储系统 + 前端预测

### B.1 I-cache（`icache.v`，144 行）

- **结构**：256 行 × 16B 直接映射；tag+valid 一片 SRAM（256×21），data 一片（256×128，16 字节 lane）
- **上电初始化**：S_INIT 状态逐行清 valid（256 拍）——SRAM 无复位，这是硬性要求
- **读时序约定**（最重要的接口契约）：正常时读 `pc_f`（下一拍数据对应 `pc_id`）；**前端停顿时改读 `pc_id`**，保证停顿期间 rdata 始终对得上 ID 里的指令
- **填充 FSM**：REQ（连发 4/8/12 个读请求，流水化）→ RECV（收进 384 位移位缓冲）→ WRITE/2/3（写 1+预取 2 行，每写一段 line_buf 右移 128 位）→ REFRESH（重读 pc_id，释放后 ID 必命中）
- **顺序预取**：填 miss 行时顺带取接下来 1~2 行，流式取指 miss 率减半以上

### B.2 D-cache（`dcache.v`，212 行，全项目最难模块）

- **结构**：1024 行 × 16B（16KB），写穿 + store miss 不分配
- **双地址口**：`ex_addr`（EX 拍组合地址发起读）/ `mem_addr`（MEM 拍），`hold` 期间保持读 mem_addr
- **关键字优先**：AXI 请求从 miss 字开始（行内回绕），第一个响应直接喂给等待中的 load（`crit_word`/`crit_valid`/`crit_consume` 三信号握手）
- **一致性门控**（重点中的重点）：
  - `sb_clear`：store buffer 里有落在 miss 行的写 → 不许发起填充
  - `fill_clash`：填充期间落在填充行（含预取行）的 store → 冻结等填充完
  - 行索引比较（10 bit）而非全地址：跨 16KB 的别名只造成无害假停顿
- **端口仲裁**：data SRAM 的写口优先级 fill > store，读口 hold > EX
- 扇出工程：`fill_wr` 五份 keep 复制（L99-103），血泪教训都在注释里

### B.3 Store buffer（`storebuf.v`，102 行）

8 项 FIFO。三个指针：`head`（等 B 响应弹出）/`issue`（正在发 AXI）/`tail`（压入）。AXI 响应按序返回，所以 `bvalid` 一拍弹一项，无需匹配。`chk_line/2/3` 三个组合检查口供 d-cache 门控用。

### B.4 分支预测器三件套（`student_top.v` L259-446）

| 部件 | 结构 | 职责 |
|---|---|---|
| BTB/BHT 合并表 | 256 项 × 37 位 SRAM | ID 级预测：分支看 2-bit BHT，跳转看 target |
| FAT | 32 项全相联 reg 阵列 | IF 级预测：命中即 0 气泡跳转 |
| RAS | 8 项 reg 栈 | call 压栈 / ret 弹栈，预测函数返回 |

数据流：IF 拍 FAT 全相联比较 + SRAM 发读 → ID 拍 SRAM 数据到货做最终判决 → EX 拍验证、更新表项。三层保险：FAT 错了 ID 复核（1 拍代价），都错了 EX 兜底（2 拍代价），**正确性永远不依赖预测器**。

### B.5 AXI 仲裁与协议（`student_top.v` L733-751 + `docs/axi4-lite.md`）

`ar_owner` 三态状态机。配合协议文档逐条验证：valid 稳定性、响应按序、对齐要求、退出 MMIO。

**B 板块毕业考题**：① 为什么填充前必须等 `sb_clear`？不等会出什么事？② I-cache 停顿时为什么还要保持读 `pc_id`？③ RAS 什么时候压栈、什么时候弹栈，为什么 ret 预测错不会死？

---

# 附：推荐实验（读完代码后动手验证，直接产出报告素材）

| 实验 | 做法 | 观察 |
|---|---|---|
| 关掉 FAT | 注释 `if_pred_taken` 逻辑 | `make perf` IPC 掉多少 |
| 关掉预取 | `do_pref/do_pref2` 恒 0 | 哪个测试 IPC 掉最多 |
| Cache 容量扫描 | 改 `IBITS`（10→8→6） | 面积 vs IPC 曲线 → 参数敏感度分析 |
| 除法器对比 | radix-4 改回 radix-2 | `correctness_pi` 周期数变化 |
| 预测器统计 | 取消 `ifdef DEBUG` 包裹，跑 `make run ... LOG=` | `[PERF]` 行的 miss/flush 统计 |

> ⚠️ 做完实验记得 `git checkout .` 还原，或把有用的数据截图存档后再还原。
> ⚠️ 任何 `$display` 调试打印必须放在 `` `ifdef DEBUG`` 里，否则 `make test` 会因 stdout 污染全部假失败（本项目栽过两次的坑）。

# B 部分（存储子系统 + 前端预测）学习指南

> 面向分工中的 **B 同学**：负责 icache / dcache / storebuf / 分支预测（FAT、BHT、RAS）/ AXI 仲裁。
> 本文基于当前正确性全过（19/19）的乱序版代码，涉及文件：
>
> | 文件 | 行数 | 内容 |
> |---|---|---|
> | `verilog/icache.v` | 202 | 指令 cache |
> | `verilog/dcache.v` | 255 | 数据 cache |
> | `verilog/storebuf.v` | 104 | store buffer（写穿队列） |
> | `verilog/student_top.v` 170–370 行 | ~200 | FAT(BTB) / RAS / BHT / 取指预测 |
> | `verilog/student_top.v` 1359–1418 行 | ~60 | 三个存储模块的例化 + AXI 读仲裁 |
>
> 建议阅读顺序：**storebuf → icache → dcache → FAT/RAS → BHT → AXI 仲裁**（由易到难）。

---

## 第一部分：必须掌握的 Verilog 语法

下面每一条语法都给出本工程里的真实例子，看语法时对照着代码看。

### 1. 模块、参数与常量

```verilog
module icache #(
    parameter LINES = 256,          // 例化时可覆盖
    parameter WAYS  = 1
) ( ... );
    localparam SETS  = LINES / WAYS;              // 编译期常量，不可覆盖
    localparam IBITS = (SETS <= 1) ? 1 : $clog2(SETS);
```
（`verilog/icache.v:11-37`）

- `parameter`：模块的"模板参数"，例化时 `icache #(.LINES(256), .WAYS(1)) u_icache (...)` 覆盖。
- `localparam`：模块内部常量，由 parameter 推导。
- `$clog2(N)`： ceiling log2，算"索引需要几位"。256 行 → `$clog2(256)=8` 位索引。
- 本工程所有容量参数集中在 `verilog/params.vh`，改参数不用动 RTL。

**地址切分**（cache 的核心概念）：32 位地址 = `[31:4+IBITS] tag | [IBITS+3:4] index | [3:0] 行内偏移`，因为一行 16B = 2⁴，所以低 4 位是行内偏移。

### 2. wire 与 reg、assign 与 always

- `wire`：组合逻辑的连线，用 `assign` 驱动，**不能**在 always 里赋值。
- `reg`：能在 always 块里赋值的变量。**注意：reg 不一定是触发器**——在 `always @(*)` 里赋值的 reg 综合出来是组合逻辑（如 `icache.v:127` 的 `data_sel`）；只有在 `always @(posedge clk)` 里赋值的才是触发器。

```verilog
assign hit = |way_hit;                    // wire，组合
reg [127:0] data_sel;
always @(*) begin                          // 组合逻辑（没有时钟沿）
    data_sel = data_rdata[0];              // 用阻塞赋值 =
    ...
end
always @(posedge clk) begin                // 时序逻辑（触发器）
    state <= S_INIT;                       // 用非阻塞赋值 <=
end
```

**铁律**：时序逻辑（带时钟）用 `<=`，组合逻辑用 `=`。混用会产生仿真/综合不一致的诡异 bug。

### 3. 位选择、拼接、复制

```verilog
miss_addr[31:4]                          // 取高 28 位（line 地址）
pc_id[IBITS+3:4]                         // 取 index 段（参数化位宽）
line_buf[{r_cnt, 5'b0} +: 32] <= rdata;  // 可变片选：起点={r_cnt,5'b0}，向上取32位
instr = data_sel[{pc_id[3:2], 5'b0} +: 32];  // 从 128 位行里选出第 pc_id[3:2] 个字
{1'b1, fill_tag}                         // 拼接：valid 位拼在 tag 前面
{16{fill_wr}}                            // 复制：fill_wr 复制 16 份成 16 位掩码
```

`a [start +: width]` 是**可变起始、固定宽度**的片选，cache 里按字选行内数据全靠它（`icache.v:135`、`dcache.v:228`）。这是 B 部分最重要的语法点，务必看懂。

### 4. 三目运算与归约运算

```verilog
wire [IBITS-1:0] index = we_a ? fill_line_addr[IBITS+3:4]
                 : front_stall ? pc_id[IBITS+3:4] : pc_f[IBITS+3:4];  // 嵌套三目=优先级 mux
assign hit = |way_hit;                     // 归约 OR：way_hit 任一位为 1 则 hit=1
```

嵌套三目就是硬件里的优先级选择器，综合成一串 mux。`|vec` 是把一个向量的所有位或起来成 1 位。

### 5. FSM（状态机）——两种写法

icache 用**二进制编码**（`icache.v:41-48`）：

```verilog
localparam S_IDLE = 3'd0, S_REQ = 3'd1, S_RECV = 3'd2, ...;
reg [2:0] state;
```

dcache 用**独热编码**（`dcache.v:54-61`）：

```verilog
localparam S_IDLE = 7'b0000001, S_REQ = 7'b0010, ...;
reg [7:0] state;
assign fillwrite = state[6] | state[5] | state[4] | state[3];  // 直接取状态位，无需译码
```

独热的好处：`busy`、`fillwrite` 这类广播到全芯片的信号直接从单个触发器输出，省一层译码逻辑（这是当时修时序的手段，注释里写了原因）。状态转移都长这样：

```verilog
always @(posedge clk) begin
    if (reset) state <= S_INIT;
    else case (state)
        S_IDLE: if (miss) begin ... state <= S_REQ; end
        S_REQ:  if (grant && ar_ready) ...
        ...
    endcase
end
```

看懂两个 cache 的关键就是把这 8 个状态的转移图在纸上画出来（INIT→IDLE→REQ→RECV→WRITE→(WRITE2→WRITE3)→REFRESH→IDLE）。

### 6. generate 循环与数组

```verilog
wire [TAGW:0] tag_rdata [0:WAYS-1];      // "数组的 wire"：每路一份
genvar wi;
generate
    for (wi = 0; wi < WAYS; wi = wi + 1) begin : g_way
        sram_fakeram #(...) tag_ram (...);   // 每路例化一份 SRAM
        assign way_hit[wi] = init_done && (rd_tag == {1'b1, pc_tag});
    end
endgenerate
```
（`icache.v:97-123`）

- `generate for`：**编译期展开**的循环，WAYS=2 就例化两份硬件。不是运行时循环！
- `reg lru [0:SETS-1];`：寄存器数组（memory），综合成触发器堆或 SRAM。storebuf 的 `addr_q [0:DEPTH-1]` 同理。
- 与之配合的运行时写法是 `always @(*)` 里的 `for` 循环（`icache.v:129-133`），那是在**组合逻辑里做优先级选择**，每个循环迭代都是一个 mux 级。

### 7. function

```verilog
function [WAY_BITS-1:0] victim_of;
    input [IBITS-1:0] set;
    begin
        if (WAYS == 1) victim_of = {WAY_BITS{1'b0}};
        else           victim_of = lru[set];
    end
endfunction
```
（`icache.v:86-92`）

纯组合的代码块，返回值为函数名。`student_top.v:75-91` 的 `load_extend`（load 字节/半字扩展）是更实用的例子，A、B 两部分都会用到。

### 8. sram_fakeram：本工程的 SRAM 模型

```verilog
sram_fakeram #(.DEPTH(SETS), .WIDTH(128), .WRITE_GRANULARITY(8)) data_ram (
    .clk(clk), .en(1'b1), .we(way_we), .wmask(way_wmask),
    .addr(index), .wdata(way_wdata), .rdata(rd_data));
```
（`dcache.v:152-154`）

三个必须记住的特性：

1. **同步读，1 拍延迟**：本拍给 `addr`，**下一拍** `rdata` 才有效。这就是 icache 注释里"正常流动读 pc_f，停顿改读 pc_id"的原因——rdata 永远对应上一拍的地址。
2. **无复位**：上电内容是 X。所以两个 cache 都有 `S_INIT` 状态，开机花 SETS 拍逐行写 0 清 valid 位（`icache.v:160-166`）。
3. `WRITE_GRANULARITY(8)` + `wmask`：按字节写掩码，store 写 1/2/4 字节就靠它（`dcache.v:143`）。

valid 位存在哪？**并进 tag SRAM 的最高位**：`{1'b1, fill_tag}` 写入，读出 `rd_tag == {1'b1, pc_tag}` 同时完成 valid 检查和 tag 比较（`icache.v:111,121`），省一块 valid 存储。

### 9. 握手协议（valid/ready）——AXI 的灵魂

```verilog
assign ar_valid = (state == S_REQ) && grant;
S_REQ: if (grant && ar_ready) begin ... ar_cnt <= ar_cnt + 4'd1; end
```

规则就一条：**valid 和 ready 同拍为 1 才算传输发生**。valid 拉高后在握手完成前不能撤、数据不能变。storebuf 里 `awvalid`/`wvalid` 的处理（`storebuf.v:84-100`）是最标准的例子：握手成功就拉低，没成功就保持。

### 10. 环形队列指针的"多一位"技巧

```verilog
localparam PTRW = IDXW + 1;               // 指针比索引多 1 位
reg [PTRW-1:0] head, tail, issue;
wire [PTRW-1:0] cnt = tail - head;        // 直接相减得元素个数
assign full = (cnt == DEPTH);
addr_q[tail[IDXW-1:0]] <= push_addr;      // 存数组时截掉最高位
```
（`storebuf.v:29-39`）

指针多存一位"圈数"，空/满判断就变成了简单的减法和比较，不用处理回绕。这是硬件 FIFO 的标准写法。

### 11. 工程习惯（很重要，前人栽过坑）

- **调试打印一律包在 `` `ifdef DEBUG`` 里**（`dcache.v:184-191`）。裸的 `$display` 会污染评测协议的 stdout，让 `make test` 全部假 FAIL。
- `(* keep *) wire we_d = we;`（`icache.v:76-77`）：属性标注，禁止综合器把这几份复制合并，用于手工控制高扇出信号的负载。这是时序优化手段，看懂即可，B 部分暂时不用自己写。

---

## 第二部分：各模块设计思想

### 0. 大背景：内存在哪、有多慢

评测框架给的是一个 **AXI4-Lite 内存从机**：

- **10 拍固定延迟**，但每个通道有 16 深 FIFO——意味着**请求可以流水化**：连续发 4 个读请求，第 10 拍后数据会连续 4 拍回来，摊薄延迟。
- 所以两个 cache 的填充都是**一次发一整行（4 拍）甚至带预取（8/12 拍）的连续读**，而不是一个字一个字地要。这是整个存储子系统性能的地基。
- 退出约定：向 `0x80000000` 写 32 位（wstrb=4'hf）表示程序结束。

AXI 有 5 个通道，本工程只用了精简版：**AR**（读地址）、**R**（读数据）、**AW**（写地址）、**W**（写数据）、**B**（写响应）。读通道由 icache/dcache 共享（要仲裁），写通道被 storebuf 独占（不用仲裁）。

### 1. storebuf.v —— 写穿队列（最简单的，先读它）

**为什么需要它**：d-cache 是写穿的，每个 store 最终都要发到 AXI。但 AXI 写一次要等握手，如果让流水线直接等，store 会卡住整条流水线。storebuf 是中间的 FIFO：流水线一拍把 store 压进来就走人，storebuf 自己慢慢按序发到 AXI。

**结构**：8 项 FIFO（`addr_q`/`data_q`/`strb_q` 三个平行数组），三个指针：

- `head`：最老未收到 B 响应的项；
- `issue`：下一项待发射 AW/W 的项；
- `tail`：下一个空位。

**关键逻辑**：

- `issue_done`（`storebuf.v:55-57`）：当前项的 AW 和 W 都握手完成。
- 发射可以"背靠背"：一项刚发完，下一拍立即发下一项；甚至本拍 push 进来的项可以**直接旁路发射**（`start_i == tail` 时用 `push_*` 而不用读队列，`storebuf.v:64-66`），省一拍。
- 每收到一个 `bvalid` 弹一项（`head+1`）。因为响应按序回来，不用比对 ID。
- `chk_line`/`chk_clear`（`storebuf.v:42-52`）：组合地扫描队列里所有未弹出的项，报告"有没有落在某个 16B line 里的 store 还没写出去"。**这是给 d-cache 填充门控用的**，见下。

### 2. icache.v —— 指令 cache

**为什么需要它**：内存 10 拍延迟，如果每条指令取指都访存，IPC 上限就是 0.1。指令局部性极强，一个小 cache 就能把命中率拉到 95%+。

**参数**：256 行 × 16B（=4 条指令）= 4KB，直接映射（WAYS=1 可配 2 路）。

**读时序（本模块最绕的一点）**：SRAM 读有 1 拍延迟，所以：

- 正常流动时，地址给 `pc_f`（预取指针），下一拍 rdata 对应的是已经变成 `pc_id` 的那条指令；
- 前端停顿时，地址改给 `pc_id`，保证 rdata 始终对应停顿住的那条指令。

这个 `index` 选择器在 `icache.v:78-79`，配合文件头注释 5–10 行反复读几遍就懂了。

**miss 处理（FSM 主线）**：`IDLE → REQ → RECV → WRITE → (WRITE2 → WRITE3) → REFRESH → IDLE`

- `REQ`：连续发 4 个 AR（一行 4 个字），`ar_cnt` 计数；
- `RECV`：数据回来存入 `line_buf`（384 位，能装 3 行）；
- `WRITE`：把 `line_buf[127:0]` 写进 data SRAM。若有预取，把 line_buf 右移 128 位，下一轮写第二行——这就是"每写完一段右移，下一段总在 [127:0]"（`icache.v:187-196`）这个技巧，避免写口再做一个 3 选 1 的大 mux；
- `REFRESH`：重新读一次 `pc_id`（因为 WRITE 占用了 SRAM 口，之前存的 rdata 已经失效），下一拍必定命中。

**顺序预取**：miss 一行时顺带把后面 1–2 行也读了（`do_pref`/`do_pref2`，`icache.v:171-172`）。代价只是多发几个 AR，但流式取指的 miss 直接减半。注释里说得很清楚：代码局部性强，预取稳赚。

**LRU**（2 路时）：每 set 1 位，命中/填充时翻转（`icache.v:141-149`）。1 位 LRU 是 2 路的特例，刚好够。

### 3. dcache.v —— 数据 cache（B 部分最复杂的模块）

**核心策略**：**写穿（write-through）+ store-miss 不分配（no-write-allocate）**。

- 写穿：store 命中时同时写 cache 和 storebuf（发往内存）。好处是永远不用"写回脏行"，填充时可以直接覆盖，控制简单，也不用担心 cache 和内存不一致。
- 不分配：store miss 时只压 storebuf，不填充该行。否则一个 store miss 要等 10+ 拍填充，太亏。

**访问时序**（配合 SRAM 1 拍延迟）：

- **EX 拍**：访存指令的组合 ALU 地址 `ex_addr` 发起 SRAM 读；
- **MEM 拍**：rdata 有效，组合判断 hit。load 命中直接取数（`line_rdata` 里按偏移选字）；miss 走填充。
- store 在 MEM 拍命中则用字节写掩码 `store_wmask` 写 data SRAM。
- **端口冲突**：SRAM 是单端口的！MEM 拍 store 要写、EX 拍 load 要读，冲突时顶层停顿 EX 一拍（这就是文件头注释第 9 行说的）。

**关键字优先（critical word first）**：填充时 AR 顺序从 miss 的那个字开始（行内回绕，见 `dcache.v:87-90` 的 `ar_word`），第一个响应到了立刻通过 `crit_valid`/`crit_word` 递给流水线（`dcache.v:231-234`），不用等整行填完。10 拍延迟只暴露一次，后面 3 个字流水线已经在跑了。

**一致性门控（最容易出 bug 的地方，务必理解）**：

> 填充一行之前，必须等 storebuf 里所有落在该行的 store 都写完（`sb_clear`）。否则 AXI 读回来的是**旧数据**，storebuf 里还没发出去的**新数据**会被覆盖丢失。

这就是 storebuf 那三个 `chk_line/chk_clear` 端口的用途（`dcache.v:210` 的 `if (miss && sb_clear)`）。预取行同理要查 `sb_clear2/3`。

还有 `fill_clash`（`dcache.v:80-83`）：填充进行期间，MEM 拍如果有 store 命中正在填充的行，必须等填充完成，否则它会按 hit 写 cache 然后被填充覆盖。用 set 索引比较而不是全 tag——会误报（假停顿），但不会漏报，安全。

**读一下 `dcache.v:96-115` 的注释**：`fill_wr` 手工复制 5 份的段落是时序修复的历史遗迹，理解功能时可以忽略，但要知道它为什么存在（一个信号驱动上千负载，综合器不插缓冲树，曾造成 17ns 单级延迟）。

### 4. FAT（全相联 BTB）——`student_top.v:175-203, 282-331`

**作用**：在**取指阶段（IF）就回答"这条是不是跳转、跳到哪"**，不用等译码。分支方向由 BHT 管，FAT 管目标地址和类型。

**结构**：32 项**全相联**（CAM：每项存完整 pc，32 个比较器并行比，`student_top.v:186-191`）。为什么全相联而不是组相联？分支指令在程序里稀疏分布但热点集中（循环、函数调用），全相联 32 项的等效命中率远高于组相联，而且 32 项的规模用触发器做 CAM 面积可接受（不用 SRAM）。

**双读口**：双发射要同时查 `pc_f` 和 `pc_f+4` 两个槽（`fat_match1`/`fat_match2`）。全相联做双读口很便宜——只是多 32 个比较器。

**学习策略**（`student_top.v:305-328`），在分支**解析时**更新：

- JAL / JALR / **taken 分支**：学习（写入新项）；
- **not-taken 分支：失效**（清 valid）——这条很关键：预测 taken 但实际 not-taken 说明下次大概率也不跳，删掉它防止反复误预测；
- 替换：round-robin（`fat_rr` 轮转），但如果某项已经匹配同一个 pc 就覆盖原项（`fat_wslot` 的优先级选择，`student_top.v:294-298`）。

表项类型 `fat_type`：`BT_BR`（条件分支，方向还要问 BHT）、`BT_JMP`（无条件跳）、`BT_RET`（返回，目标问 RAS）。

### 5. BHT（分支历史表）——`student_top.v:242-280`

**作用**：只管**方向**（跳/不跳）。2 位饱和计数器：00/01 预测不跳，10/11 预测跳；解析后增减并饱和（`student_top.v:253-254`）。

**为什么 2 位而不是 1 位**：循环最后一次退出的分支会翻转一次，2 位计数器只"怀疑"不立刻改判，回到循环头部后又是对的。1 位计数器每个循环会错 2 次，2 位只错 1 次。

**banked 结构**：2 bank × 128 项，按 `pc[2]` 分 bank——因为双发射取的是相邻两字 `pc_f` 和 `pc_f+4`，它们的 `pc[2]` 必然不同，分 bank 后**一个 SRAM 口就能同时服务两条**（`student_top.v:261-280` 的读口选择逻辑）。这是"用结构换端口"的典型手法。

表项 37 位 = `{valid, type[1:0], target[31:0], counter[1:0]}`。type/target 也留在 BHT 里作为 FAT miss 时的兜底。

注意读口的 `pv0/pv1`（`student_top.v:265-272`）：SRAM 写优先时同拍读会拿到旧数据，这两位记录"本拍读到的数据是否有效"，同拍有写就作废。

### 6. RAS（返回地址栈）——`student_top.v:205-218`

**作用**：预测 `ret`（`jalr x0, ra, 0`）的目标。函数调用（call）时把 `pc+4` 压栈，返回时弹栈。8 项。

**为什么在提交期（commit）更新而不是预测期**：乱序核心里预测期的压栈/弹栈可能是错误路径上的操作，恢复起来要快照，很麻烦。放在**提交时**更新（`commit0 && rob_is_call` 才压栈），栈永远只反映**确定无误**的执行历史——可能短暂滞后，但永远不会错。配合 `ras_top` 的组合旁路（`student_top.v:217-218`）：本拍正提交的 call 立刻对取指可见，不等写回数组。

**三级预测的配合关系**（取指槽的判定逻辑在 `student_top.v:335-342`）：

1. FAT 命中且类型是 JMP/BR → 用 FAT 目标（BR 的方向由 BHT 决定，这里先按 taken 预取）；
2. 类型是 RET 且 RAS 非空 → 用 `ras_top`；
3. 都不中 → 顺序 `pc+4`（或 +8）。

### 7. AXI 读仲裁器——`student_top.v:1399-1416`

icache 和 dcache 共享一条 AR/R 通道。仲裁器是个 3 状态 FSM（`ar_owner`：0 空闲 / 1 dcache / 2 icache）：

- 空闲时 **dcache 优先**（数据 miss 在关键路径上，指令有取指队列缓冲）；
- 一旦授权就**锁定到传输完成**：owner 看到对方的 `last_r`（最后一个数据拍）才释放；
- 授权期间把对应方的 `ar_addr/ar_valid` 接到总线（`student_top.v:1415-1416`）。

`last_r` 由两个 cache 自己算（如 `icache.v:67`）：`RECV 状态 && rvalid && r_cnt == last_beat`。注意 `last_beat` 取决于预取了几行（3/7/11），所以仲裁器不能自己数拍，必须让 cache 报。

---

## 第三部分：怎么学 & 自检清单

### 推荐节奏（约一周）

1. **第 1–2 天**：过一遍本文第一部分的语法，每条都打开对应代码看实例。配合任意一本 Verilog 教程（推荐《Verilog 数字系统设计教程》夏宇闻，或在线的 HDLBits 刷前 30 题）。
2. **第 3 天**：storebuf + AXI 仲裁。画 FIFO 指针在 push/issue/bvalid 下的变化。
3. **第 4–5 天**：icache，然后 dcache。画两个 FSM 的状态转移图，标注每条弧的条件。
4. **第 6 天**：FAT / BHT / RAS，画"一条分支指令从取指到解析，三个表各在什么时刻被查/被更新"的时间线。
5. **第 7 天**：跑实验（见下）。

### 动手实验（比读代码记得牢）

```bash
cd /mnt/d/cpu/RISC-V-CPU-2026
make build && make test          # 先确认 19/19 基线
```

然后做这些小改动，每次改完都 `make build && make test` 验证：

1. **改容量**：把 `params.vh` 里 `CPU_ICACHE_LINES` 改成 64，跑 `make perf` 看 IPC 掉多少——体会 cache 容量与性能的关系。
2. **关预取**：把 icache 的 `do_pref`/`do_pref2` 恒置 0，看 `make perf` 的变化。
3. **加调试打印**：仿照 `dcache.v:184-191`，在 `ifdef DEBUG` 下给 icache miss 加打印，`make run Case=magic` 观察 miss 频率。（**切记包 ifdef，且测完删掉或保留 ifdef**。）
4. **改相联度**：`CPU_ICACHE_WAYS=2`（BHT/LRU 路径会被激活），确认正确性仍然 19/19——这会逼你真正看懂 generate 循环和 LRU。

### 自检问题（能答出来才算读懂）

- 为什么 SRAM 读地址在停顿时要从 `pc_f` 切到 `pc_id`？
- 为什么 d-cache 填充前要等 `sb_clear`？缺了这一步会出现什么数据错误？
- `fill_clash` 为什么用 set 索引比较而不是完整 tag？会不会出错？
- storebuf 的 `start_i == tail` 旁路是干什么的？省了什么？
- FAT 为什么对 not-taken 分支做失效而不是学习？
- BHT 为什么要分 bank？`pv0/pv1` 防的是什么？
- RAS 为什么放在提交期更新？
- 仲裁器为什么授权后要锁定到 `last_r`？如果中途切换会怎样？

### 给两人的协作提示

B 部分模块的**接口边界**就是和 A 部分（流水线核心）的契约：`hit/miss/busy`、`crit_valid/crit_word`、`sb_clear*`、`front_stall`。改 B 部分内部实现不影响 A，但动这些信号的含义必须两人对齐。建议把 `student_top.v:1359-1418` 的例化段打印出来贴在桌上——那是 B 部分的全部对外契约。

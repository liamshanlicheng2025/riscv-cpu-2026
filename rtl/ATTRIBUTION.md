# 参考来源与本地修改

`ooo/` 的主体 RTL 参考并移植自用户指定的
[Galuisss/ACM-CPU](https://github.com/Galuisss/ACM-CPU)，固定提交
`b76000b65bfa7ef9aca57ef27478ce33fa488791`（`perf-redesign`）。
这次改动采用参考仓库的 Area-v2 架构，不宣称该架构或这些模块为本地原创。

来源映射：

- `ooo/cpu_pkg.sv`、`decoder.sv`、`alu.sv`、`branch_unit.sv`、`muldiv.sv`、
  `memory_controller.sv`：上游 `rtl/` 同名文件。
- 其余 `ooo/*.sv`（除 `ooo_recovery_flag.sv`、`ooo_head_select.sv`）：上游 `designs/area_v2/rtl/` 同名文件。
- `ooo/upstream_export.py`：上游 `scripts/export_verilog.py`，保留转换逻辑以保持仿真和综合表达式一致。
- `tests/axi/`：上游 `designs/area_v2/tests/axi_cpu/cpu_top.sv` 和
  `axi_backpressure.cpp`；本地补齐了包装器参数。

本地完成的适配和改进：

1. RAM 范围从参考默认的 256 KiB 扩展为课程要求的 256 MiB；D-cache 标签宽度随之扩展。
2. 执行队列的 PC/预测目标从 16 位字地址扩展到 30 位字地址；BTB 标签及目标保留完整地址。
   地址检查仍使用 32 位地址，不能通过截断地址绕过越界检查。
3. 顶层公开发射/分派、提交、ROB、队列、缓存、分支预测等配置参数。
4. D-cache 新增真正的一路/两路配置；直接映射时容量保持不变，组数加倍，而非简单屏蔽半个缓存。
5. 在可综合 RTL 中复制前端分支恢复和访存地址选择状态，限制控制信号扇出；
   对比访存流水选项的面积、频率及 IPC，按实测结果选择默认配置。
6. 提供本地生成、参数对比、高地址和 RV32M 边界回归及本地实测报告。

`verilog/ooo_cpu.v` 是上述 SystemVerilog 生成的课程提交文件。
`ooo_cpu.metadata.json` 记录输入、生成器及输出 SHA-256。
官方 `scripts/`、内存模型和测试用例未修改。旧 CPU 源码已从 `main` 移除，
完整保存在 `archive/main-pre-oj` 分支。

上游 README 的成绩不能直接视为本地成绩。本地结果必须以同一份生成 RTL 的官方仿真和综合为准。

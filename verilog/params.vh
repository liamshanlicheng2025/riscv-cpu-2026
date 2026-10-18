// 微架构参数配置。修改本文件即可做参数扫描（默认值为当前基线）。
`ifndef CPU2026_PARAMS_VH
`define CPU2026_PARAMS_VH

`ifndef CPU_ISSUE_WIDTH
`define CPU_ISSUE_WIDTH 2
`endif
`ifndef CPU_ROB_DEPTH
`define CPU_ROB_DEPTH 32
`endif
`ifndef CPU_PRF_SIZE
`define CPU_PRF_SIZE 64
`endif
`ifndef CPU_RS_DEPTH
`define CPU_RS_DEPTH 16
`endif
`ifndef CPU_MOB_DEPTH
`define CPU_MOB_DEPTH 16
`endif
`ifndef CPU_Q_DEPTH
`define CPU_Q_DEPTH 4
`endif
`ifndef CPU_ICACHE_LINES
`define CPU_ICACHE_LINES 256
`endif
`ifndef CPU_DCACHE_LINES
`define CPU_DCACHE_LINES 1024
`endif
`ifndef CPU_ICACHE_WAYS
`define CPU_ICACHE_WAYS 1
`endif
`ifndef CPU_DCACHE_WAYS
`define CPU_DCACHE_WAYS 1
`endif
`ifndef CPU_STORE_BUF_DEPTH
`define CPU_STORE_BUF_DEPTH 8
`endif

`endif

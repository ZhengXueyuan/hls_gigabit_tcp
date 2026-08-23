# DDR3 集成方案 — ECO 板网络协议栈

> 状态: 设计阶段 (2026-08-22), 不写代码, 不修改文件
> 目标: TCP 收数据 -> 存 DDR3 -> 延迟 2 秒回显
>
> **2026-08-23 补记**: 2000B 第4段错位已破案修复 — 根因 = wrapper `rx_fifo` 溢出
> (2048深/1900门限), 修复为 4096/3900, 板上 py_net_test 7/7 PASS (含 TCP 2000B×3),
> 见 RX_FIFO_OVERFLOW_ANALYSIS.md。**DDR3 不被 2000B 修复阻塞, 属后续可选优化/新特性**;
> 本方案 (尤其大容量 DDR3 缓冲吸收"线速填入 vs DUT 慢排空"速率差的思路) 也可作为
> rx_fifo 治本办法之外的另一种扩展方向。

---

## 1. 参考工程分析 (k717_ddr3_axi_read_write)

### 1.1 架构概览

```
sys_clk(50MHz) -> clk_wiz_0 -> ddr3_clk(400MHz) -> mig_7series_0 -> ui_clk(~200MHz)
                                    |                     |
                              [MIG ref clock]      [AXI4 Slave 64-bit]
                                                         |
                                              axi_master_read / axi_master_write
                                                         |
                                              ddr3_axi_read_write (test harness)
```

### 1.2 MIG 配置 (mig_7series_0)

| 参数 | 值 |
|------|-----|
| FPGA | Kintex-7 XC7K325T-2FFG676 |
| 存储器类型 | DDR3 SDRAM |
| 数据宽度 | 32-bit (4 DQS pairs) |
| 地址宽度 | 15-bit row/column |
| Bank 地址 | 3-bit |
| AXI 接口 | AXI4 Slave, 64-bit data, 32-bit address |
| 参考时钟 | 400MHz (from clk_wiz_0) |
| ui_clk 频率 | ~200MHz (4:1 ratio) |
| 突发类型 | Incremental (INCR) |
| 总容量 | 256MB |

### 1.3 AXI Master Wrapper 接口 (复用 k717)

**axi_master_write** — 用户接口:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| WR_START | in | 1 | 启动写突发 (脉冲) |
| WR_ADRS | in | 32 | 起始字节地址 |
| WR_LEN | in | 32 | 突发长度 (拍数, 1拍=64bit=8B) |
| WR_READY | out | 1 | 空闲 (可接受新请求) |
| WR_FIFO_RE | out | 1 | 读 FIFO 使能 (等同于 wvalid&wready) |
| WR_FIFO_DATA | in | 64 | 写数据 (来自上游 FIFO) |
| WR_FIFO_EMPTY | in | 1 | FIFO 空 |
| WR_DONE | out | 1 | 突发完成 (脉冲) |

状态机: IDLE → WA_WAIT → WA_START → WD_WAIT → WD_PROC → WR_WAIT → WR_DONE → IDLE

**axi_master_read** — 用户接口:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| RD_START | in | 1 | 启动读突发 (脉冲) |
| RD_ADRS | in | 32 | 起始字节地址 |
| RD_LEN | in | 32 | 突发长度 (拍数) |
| RD_READY | out | 1 | 空闲 |
| RD_FIFO_WE | out | 1 | 写 FIFO 使能 (等同于 rvalid) |
| RD_FIFO_DATA | out | 64 | 读数据 |
| RD_DONE | out | 1 | 突发完成 (脉冲) |

状态机: IDLE → RA_WAIT → RA_START → RD_WAIT → RD_PROC → RD_DONE → IDLE

### 1.4 关键参数 (k717 代码)

- AXI burst size: 3'b011 (64-bit = 8 bytes per beat)
- AXI burst type: 2'b01 (INCR)
- AXI cache: 4'b0011 (read) / 4'b0010 (write)
- AXI ID: 4'b1111 (write) / 1'b0 (read)
- AXI WSTRB: 8'hFF (all bytes valid)
- AXI ARSIZE: 3'b011 (64-bit)

---

## 2. 从 k717 复制的文件清单

### 2.1 IP 核 (整个目录复制)

| 源路径 | 目标路径 | 说明 |
|--------|----------|------|
| `k717.../sources_1/ip/mig_7series_0/` | `udp_hls_eco/ip/mig_7series_0/` | MIG DDR3 控制器 (含 .xci, .dcp, .veo, sim netlist) |
| `k717.../sources_1/ip/clk_wiz_0/` | `udp_hls_eco/ip/clk_wiz_0/` | 时钟向导 (50MHz→400MHz, 含 .xci, .xdc, .veo) |

### 2.2 RTL 源文件 (直接复制)

| 源路径 | 目标路径 | 说明 |
|--------|----------|------|
| `k717.../sources_1/new/axi_master_read.v` | `udp_hls_eco/src/axi_master_read.v` | AXI 读突发用户封装 |
| `k717.../sources_1/new/axi_master_write.v` | `udp_hls_eco/src/axi_master_write.v` | AXI 写突发用户封装 |

### 2.3 约束文件 (需转换格式)

| 源文件 | 目标 | 说明 |
|--------|------|------|
| `k717/.../DDR3_PIN_XDC.ucf` | `udp_hls_eco/xdc/ddr3_pin.xdc` | UCF→XDC 格式转换, DDR3 全部引脚约束 |

### 2.4 新建文件 (本方案设计)

| 文件 | 说明 |
|------|------|
| `udp_hls_eco/src/ddr3_buffer_mgr.v` | **DDR3 缓冲管理器** (核心新模块, 见第 4 节) |
| `udp_hls_eco/src/async_fifo_gmii2ui.v` | 写路径异步 FIFO (gmii_clk→ui_clk, 64b→64b) |
| `udp_hls_eco/src/async_fifo_ui2gmii.v` | 读路径异步 FIFO (ui_clk→gmii_clk, 64b→64b) |
| `udp_hls_eco/src/ddr3_top.v` | DDR3 子系统顶层 (MIG + clk_wiz + axi wrappers + buffer_mgr + FIFOs) |
| `udp_hls_eco/xdc/ddr3_timing.xdc` | DDR3 时序约束 (ui_clk, ddr3_clk, false-path 跨域) |

---

## 3. 接口定义

### 3.1 顶层 IO (wrapper_1g.v 新增端口)

| 端口 | 方向 | 位宽 | I/O Standard | 说明 |
|------|------|------|-------------|------|
| `ddr3_dq` | inout | 32 | SSTL15_T_DCI | DDR3 数据总线 |
| `ddr3_dqs_p` | inout | 4 | DIFF_SSTL15_T_DCI | DDR3 数据选通 (正) |
| `ddr3_dqs_n` | inout | 4 | DIFF_SSTL15_T_DCI | DDR3 数据选通 (负) |
| `ddr3_addr` | out | 15 | SSTL15 | DDR3 地址总线 |
| `ddr3_ba` | out | 3 | SSTL15 | DDR3 Bank 地址 |
| `ddr3_ras_n` | out | 1 | SSTL15 | 行地址选通 |
| `ddr3_cas_n` | out | 1 | SSTL15 | 列地址选通 |
| `ddr3_we_n` | out | 1 | SSTL15 | 写使能 |
| `ddr3_reset_n` | out | 1 | LVCMOS15 | DDR3 复位 |
| `ddr3_ck_p` | out | 1 | DIFF_SSTL15 | 差分时钟 (正) |
| `ddr3_ck_n` | out | 1 | DIFF_SSTL15 | 差分时钟 (负) |
| `ddr3_cke` | out | 1 | SSTL15 | 时钟使能 |
| `ddr3_cs_n` | out | 1 | SSTL15 | 片选 |
| `ddr3_dm` | out | 4 | SSTL15 | 数据掩码 |
| `ddr3_odt` | out | 1 | SSTL15 | 片上终端 |

### 3.2 ddr3_top ↔ wrapper_1g 接口 (内部信号)

| 信号 | 方向 | 位宽 | 时钟域 | 说明 |
|------|------|------|--------|------|
| `sys_clk` | in | 1 | — | 50MHz 板载时钟 (与 fpga_gclk 同源) |
| `rstn` | in | 1 | — | 异步复位 (与 reset_n 同源) |
| `calib_done` | out | 1 | — | MIG 校准完成 (LED 指示) |
| `ui_clk` | out | 1 | — | MIG 用户时钟 ~200MHz (monitor only) |
| `locked` | out | 1 | — | clk_wiz 锁定 (LED 指示) |
| **写路径 (gmii→DDR3)** | | | | |
| `wr_req` | in | 1 | gmii_clk | 写请求 (脉冲, 来自 HLS/monitor) |
| `wr_data` | in | 64 | gmii_clk | 写数据 (TCP payload) |
| `wr_valid` | in | 1 | gmii_clk | 写数据有效 |
| `wr_ready` | out | 1 | gmii_clk | 写路径就绪 (背压) |
| `wr_len` | in | 16 | gmii_clk | 写长度 (字节数) |
| `wr_done` | out | 1 | gmii_clk | 写完成 (脉冲, gmii 域同步回) |
| **读路径 (DDR3→gmii)** | | | | |
| `rd_req` | in | 1 | gmii_clk | 读请求 (脉冲) |
| `rd_data` | out | 64 | gmii_clk | 读数据 |
| `rd_valid` | out | 1 | gmii_clk | 读数据有效 |
| `rd_ready` | in | 1 | gmii_clk | 下游就绪 |
| `rd_len` | in | 16 | gmii_clk | 读长度 (字节数) |
| `rd_done` | out | 1 | gmii_clk | 读完成 (脉冲) |

### 3.3 ddr3_buffer_mgr 内部接口 (ui_clk 域)

与 axi_master_write 的接口:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `wr_start` | out | 1 | 启动写突发 |
| `wr_adrs` | out | 32 | 写地址 (字节) |
| `wr_len` | out | 10 | 写突发长度 (拍数) |
| `wr_ready` | in | 1 | AXI 写空闲 |
| `wr_fifo_re` | in | 1 | 读 FIFO 使能 |
| `wr_fifo_data` | out | 64 | 写数据 (到 AXI wrapper) |
| `wr_fifo_empty` | out | 1 | 写 FIFO 空 |
| `wr_done` | in | 1 | 写突发完成 |

与 axi_master_read 的接口:
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `rd_start` | out | 1 | 启动读突发 |
| `rd_adrs` | out | 32 | 读地址 (字节) |
| `rd_len` | out | 10 | 读突发长度 (拍数) |
| `rd_ready` | in | 1 | AXI 读空闲 |
| `rd_fifo_we` | in | 1 | 写 FIFO 使能 |
| `rd_fifo_data` | in | 64 | 读数据 (来自 AXI wrapper) |
| `rd_done` | in | 1 | 读突发完成 |

与异步 FIFO 的接口 (ui_clk 侧):
| 信号 | 方向 | 位宽 | 说明 |
|------|------|------|------|
| `fifo_wr_dout` | in | 64+16 | {data[63:0], len[15:0]} 来自 gmii 域 |
| `fifo_wr_empty` | in | 1 | 写 FIFO 空 |
| `fifo_wr_re` | out | 1 | 读写 FIFO |
| `fifo_rd_din` | out | 64+1 | {data[63:0], last} 去 gmii 域 |
| `fifo_rd_full` | in | 1 | 读 FIFO 满 |
| `fifo_rd_we` | out | 1 | 写读 FIFO |

---

## 4. DDR3 Buffer 管理器设计 (ddr3_buffer_mgr.v)

### 4.1 设计目标

- 管理 DDR3 作为 TCP echo 延迟缓冲区
- 每个 TCP 连接的数据段: 先写入 DDR3, 等待 2 秒, 再读出回显
- 支持多个并发连接 (最多 8 个, 与 MAX_TCP_CONN 对齐)
- 环形缓冲区, 自动回收

### 4.2 地址分配策略

```
DDR3 地址空间: 0x00000000 — 0x0FFFFFFF (256MB)

分区布局:
┌────────────────────────────────────────────────┐
│ 0x00000000  Conn 0 缓冲区  (32MB, 16384 × 2KB) │
│ 0x02000000  Conn 1 缓冲区  (32MB, 16384 × 2KB) │
│ 0x04000000  Conn 2 缓冲区  (32MB, 16384 × 2KB) │
│ 0x06000000  Conn 3 缓冲区  (32MB, 16384 × 2KB) │
│ 0x08000000  Conn 4 缓冲区  (32MB, 16384 × 2KB) │
│ 0x0A000000  Conn 5 缓冲区  (32MB, 16384 × 2KB) │
│ 0x0C000000  Conn 6 缓冲区  (32MB, 16384 × 2KB) │
│ 0x0E000000  Conn 7 缓冲区  (32MB, 16384 × 2KB) │
└────────────────────────────────────────────────┘
```

参数:
- `SEGMENT_SIZE = 2048` (2KB per segment, 足够容纳 576B TCP payload)
- `SEGMENTS_PER_CONN = 16384` (每个连接 16384 个段)
- `CONN_BUFFER_SIZE = 32MB` (每连接 32MB, 远超 2 秒内能收到的最大数据量)
- `MAX_CONN = 8`

每个连接维护:
- `wr_ptr`: 当前写指针 (段索引)
- `rd_ptr`: 当前读指针 (段索引)
- `seg_count`: 已写入但未读取的段数

### 4.3 状态机设计

```
                    ┌──────────┐
                    │  IDLE    │
                    │ (等待)   │
                    └────┬─────┘
                         │
          ┌──────────────┼──────────────┐
          │ fifo_wr 非空    │              │ timer 到期
          │              │              │ AND seg_count>0
          ▼              │              ▼
    ┌──────────┐         │        ┌──────────┐
    │  WRITE   │         │        │  READ    │
    │ 写 DDR3  │         │        │ 读 DDR3  │
    └────┬─────┘         │        └────┬─────┘
         │               │             │
         │ 写完          │             │ 读完
         ▼               │             ▼
    ┌──────────┐         │        ┌──────────┐
    │ WR_DONE  │         │        │ RD_DONE  │
    │ 更新指针  │         │        │ 更新指针  │
    └────┬─────┘         │        └────┬─────┘
         │               │             │
         └───────────────┘             │
              │                        │
              └────────────────────────┘
                       │
                       ▼
                  ┌──────────┐
                  │  IDLE    │
                  └──────────┘
```

**状态详解**:

1. **IDLE** (3'd0):
   - 检查写 FIFO 非空: 有数据 → 进入 WRITE
   - 检查定时器到期 AND seg_count > 0: 有数据到期 → 进入 READ
   - 否则保持 IDLE
   - 优先级: WRITE > READ (先收再发, 避免回显阻塞接收)

2. **WRITE** (3'd1):
   - 读 FIFO 获取 {data, len, cid}
   - 计算写地址: `base_addr[cid] + wr_ptr[cid] * SEGMENT_SIZE`
   - 启动 AXI write burst (wr_start=1)
   - 等待 AXI 握手完成, 逐拍写入数据
   - 写完成后进入 WR_DONE

3. **WR_DONE** (3'd2):
   - 更新 wr_ptr[cid] (环形递增)
   - 更新 seg_count[cid]++
   - 记录时间戳: `timestamp[cid][wr_ptr] = current_timer`
   - 返回 IDLE

4. **READ** (3'd3):
   - 计算读地址: `base_addr[cid] + rd_ptr[cid] * SEGMENT_SIZE`
   - 启动 AXI read burst (rd_start=1)
   - 等待 AXI 读数据返回, 逐拍写入读 FIFO
   - 读完成后进入 RD_DONE

5. **RD_DONE** (3'd4):
   - 更新 rd_ptr[cid] (环形递增)
   - 更新 seg_count[cid]--
   - 返回 IDLE

### 4.4 定时器设计

```
2 秒延迟 @ ui_clk (~200MHz):
  2s × 200,000,000 = 400,000,000 周期
  → 29-bit 计数器 (最大 536,870,911)

实现: 每个 segment 存储一个 29-bit 时间戳
  写时: 记录当前全局定时器值
  读时: 检查 (current_time - timestamp) >= DELAY_CYCLES

简化方案 (推荐): 不用 per-segment 时间戳, 用 per-connection 的最老段检查
  - 每个连接维护一个 head_timestamp FIFO
  - 写入时: push {current_time} 到时间戳 FIFO
  - 读取检查: peek head_timestamp, 若 (current_time - head) >= DELAY, 则读出
  - 时间戳 FIFO 深度 = 整个 32MB 缓冲区的段数 (16384), 用 BRAM 实现
```

### 4.5 信号定义 (ddr3_buffer_mgr.v 顶层)

```verilog
module ddr3_buffer_mgr #(
    parameter MAX_CONN      = 8,
    parameter SEGMENT_SIZE  = 2048,       // bytes per segment
    parameter DELAY_CYCLES  = 400000000,  // 2s @ 200MHz
    parameter ADDR_WIDTH    = 32
) (
    input  wire         clk,            // ui_clk (~200MHz)
    input  wire         rst,            // ui_rst (同步复位, 高有效)

    // ---- 写路径 FIFO 接口 (来自 gmii 域) ----
    input  wire [79:0]  wr_fifo_dout,   // {data[63:0], len[15:0]}
    input  wire         wr_fifo_empty,
    output wire         wr_fifo_re,

    // ---- 读路径 FIFO 接口 (去 gmii 域) ----
    output wire [64:0]  rd_fifo_din,    // {last, data[63:0]}
    input  wire         rd_fifo_full,
    output wire         rd_fifo_we,

    // ---- AXI Write 接口 (到 axi_master_write) ----
    output reg          wr_start,
    output reg  [31:0]  wr_adrs,
    output reg  [9:0]   wr_len,
    input  wire         wr_ready,
    input  wire         wr_fifo_re,
    output wire [63:0]  wr_fifo_data,
    output wire         wr_fifo_empty,
    input  wire         wr_done,

    // ---- AXI Read 接口 (到 axi_master_read) ----
    output reg          rd_start,
    output reg  [31:0]  rd_adrs,
    output reg  [9:0]   rd_len,
    input  wire         rd_ready,
    input  wire         rd_fifo_we,
    input  wire [63:0]  rd_fifo_data,
    input  wire         rd_done
);
```

### 4.6 内部寄存器

```verilog
// Per-connection 指针
reg [13:0]  wr_ptr    [0:MAX_CONN-1];  // 段写指针 (14-bit, 16384 段)
reg [13:0]  rd_ptr    [0:MAX_CONN-1];  // 段读指针
reg [13:0]  seg_count [0:MAX_CONN-1];  // 待读段数
reg [31:0]  base_addr [0:MAX_CONN-1];  // 基地址 = cid * 32MB

// 全局定时器
reg [28:0]  global_timer;  // 29-bit, 2s @ 200MHz

// 状态机
reg [2:0]   state, state_next;
reg [2:0]   active_cid;     // 当前操作的连接 ID
reg [15:0]  byte_cnt;       // 当前段内字节计数
reg [13:0]  current_seg;    // 当前段索引

// 写数据缓冲 (从 FIFO 预取)
reg [63:0]  wr_data_buf;
reg [15:0]  wr_len_buf;

// 读数据缓冲 (到 FIFO)
reg [63:0]  rd_data_buf;
reg         rd_last;
```

---

## 5. 时钟域规划

### 5.1 时钟域总览

```
                    ┌─────────────┐
   fpga_gclk ──────>│ clk_wiz_0   │──────> ddr3_clk (400MHz)
    50MHz           │             │            │
                    └─────────────┘            ▼
                                        ┌──────────────┐
                                        │ mig_7series_0│
                                        │   (MIG)      │
                                        └──────┬───────┘
                                               │
                                          ui_clk (~200MHz)
                                               │
                    ┌──────────────────────────┼──────────────────┐
                    │                          ▼                  │
                    │  ┌──────────────────────────────────┐       │
                    │  │       ddr3_buffer_mgr             │       │
                    │  │    axi_master_read / write        │       │
                    │  └──────────┬───────────────────────┘       │
                    │             │                               │
                    │    ┌────────┴────────┐                      │
                    │    │  async_fifo     │                      │
                    │    │  ui <-> gmii    │                      │
                    │    └────────┬────────┘                      │
                    │             │                               │
                    │             ▼                               │
                    │  ┌──────────────────────┐                   │
   phy1_rxc ────────>│ util_gmii_to_rgmii    │                   │
    125MHz           │ gmii_clk (125MHz)      │                   │
                    │ ┌────────────────────┐ │                   │
                    │ │  HLS udp_echo      │ │                   │
                    │ │  (TCP/UDP/ICMP..)  │ │                   │
                    │ └────────────────────┘ │                   │
                    └────────────────────────┘                   │
```

### 5.2 异步 FIFO 设计

**写路径 (gmii_clk → ui_clk)**:
- 写端口: gmii_clk, 64-bit data + 16-bit len + 3-bit cid = 83-bit
- 读端口: ui_clk, 83-bit
- 深度: 512 (约 4KB 缓冲, 125MHz 下足够吸收背压)
- 实现: XPM_FIFO_ASYNC (Xilinx 参数化宏)

**读路径 (ui_clk → gmii_clk)**:
- 写端口: ui_clk, 64-bit data + 1-bit last = 65-bit
- 读端口: gmii_clk, 65-bit
- 深度: 512
- 实现: XPM_FIFO_ASYNC

### 5.3 时序约束策略

```
# MIG 参考时钟
create_clock -period 2.5 -name ddr3_clk [get_pins clk_wiz_0/inst/clk_out1]

# ui_clk (由 MIG 生成, 不需要显式约束)
# Vivado 从 MIG 自动推导

# 跨域约束
set_clock_groups -asynchronous \
    -group [get_clocks gmii_clk] \
    -group [get_clocks ui_clk] \
    -group [get_clocks fpga_gclk]

# DDR3 引脚约束 (从 k717 的 UCF 转换)
# 见 ddr3_pin.xdc
```

---

## 6. wrapper_1g.v 修改点

### 6.1 新增端口 (顶层 IO)

在 `module wrapper_1g` 的端口列表中新增 DDR3 相关的 15 个端口 (见 3.1 节)。

### 6.2 新增 wire/reg 声明

```verilog
// DDR3 子系统接口
wire        ddr3_calib_done;
wire        ddr3_locked;
wire        ui_clk;
// 写路径 (gmii 域)
reg         ddr_wr_req;
wire [63:0] ddr_wr_data;
wire        ddr_wr_valid;
wire        ddr_wr_ready;
wire [15:0] ddr_wr_len;
wire        ddr_wr_done;
// 读路径 (gmii 域)
reg         ddr_rd_req;
wire [63:0] ddr_rd_data;
wire        ddr_rd_valid;
wire        ddr_rd_ready;
wire [15:0] ddr_rd_len;
wire        ddr_rd_done;
```

### 6.3 新增例化: ddr3_top

```verilog
ddr3_top u_ddr3 (
    .sys_clk        (fpga_gclk),
    .rstn           (reset_n),
    .calib_done     (ddr3_calib_done),
    .ui_clk_out     (ui_clk),
    .locked         (ddr3_locked),
    // 写路径
    .wr_req         (ddr_wr_req),
    .wr_data        (ddr_wr_data),
    .wr_valid       (ddr_wr_valid),
    .wr_ready       (ddr_wr_ready),
    .wr_len         (ddr_wr_len),
    .wr_done        (ddr_wr_done),
    // 读路径
    .rd_req         (ddr_rd_req),
    .rd_data        (ddr_rd_data),
    .rd_valid       (ddr_rd_valid),
    .rd_ready       (ddr_rd_ready),
    .rd_len         (ddr_rd_len),
    .rd_done        (ddr_rd_done),
    // DDR3 物理接口
    .ddr3_dq        (ddr3_dq),
    .ddr3_dqs_n     (ddr3_dqs_n),
    .ddr3_dqs_p     (ddr3_dqs_p),
    .ddr3_addr      (ddr3_addr),
    .ddr3_ba        (ddr3_ba),
    .ddr3_ras_n     (ddr3_ras_n),
    .ddr3_cas_n     (ddr3_cas_n),
    .ddr3_we_n      (ddr3_we_n),
    .ddr3_reset_n   (ddr3_reset_n),
    .ddr3_ck_p      (ddr3_ck_p),
    .ddr3_ck_n      (ddr3_ck_n),
    .ddr3_cke       (ddr3_cke),
    .ddr3_cs_n      (ddr3_cs_n),
    .ddr3_dm        (ddr3_dm),
    .ddr3_odt       (ddr3_odt)
);
```

### 6.4 D0 LED 改为 calib_done

```verilog
// D0: DDR3 校准完成 (替代原来的 UART RX 活动指示)
assign led_d0 = ddr3_calib_done;
```

### 6.5 测试接口: 通过 net_stats 新增 DDR3 命令

在 `net_stats.v` 中新增 `?ddr` 命令, 显示 DDR3 状态:
- `calib_done`: MIG 校准完成
- `locked`: clk_wiz 锁定
- `wr_ptr/rd_ptr/seg_count`: 各连接的缓冲状态

### 6.6 构建脚本修改

`run_vivado_phy1g2.bat` / `.tcl`:
1. 添加 IP 仓库路径: `set_property ip_repo_paths ./ip [current_project]`
2. 添加新源文件: `ddr3_top.v`, `ddr3_buffer_mgr.v`, `axi_master_read.v`, `axi_master_write.v`, `async_fifo_gmii2ui.v`, `async_fifo_ui2gmii.v`
3. 添加约束文件: `xdc/ddr3_pin.xdc`, `xdc/ddr3_timing.xdc`

---

## 7. HLS IP 侧修改 (可选, 后续阶段)

### 7.1 当前方案: 纯 wrapper 层集成

第一阶段不修改 HLS C++ 代码。TCP echo 数据流不变:
- HLS TCP 收数据 → 写入 `tcp_send_bufs` (BRAM, 576B/连接)
- wrapper 层新增 monitor 逻辑: 检测 TCP 写入完成 → 触发 DDR3 写入
- DDR3 读回后 → 通过 wrapper 注入到 HLS TX 路径

### 7.2 后续方案: HLS 直连 AXI Master

如果需要在 HLS 内部直接控制 DDR3 (更灵活):
- 在 `udp_echo.cpp` 添加 AXI Master 接口:
  ```cpp
  #pragma HLS INTERFACE m_axi port=ddr_buffer offset=slave bundle=gmem
  ```
- 在 layer_tcp.cpp 中直接调用 `memcpy` 风格的 DDR3 读写
- 需要 HLS 重新综合, 增加 AXI 接口资源

**推荐第一阶段用纯 wrapper 方案**, 验证 DDR3 硬件通路后再考虑 HLS 内部集成。

---

## 8. 工作量估算

| 任务 | 估计工时 | 说明 |
|------|:---:|------|
| 1. 复制 k717 IP 核和 RTL | 0.5h | 机械复制, 验证路径 |
| 2. UCF→XDC 约束转换 | 1h | 37 行 UCF 逐行转 XDC 语法 |
| 3. 编写 ddr3_buffer_mgr.v | 4h | 核心模块, 含状态机 + 定时器 + 指针管理 |
| 4. 编写 async_fifo 封装 | 1h | XPM_FIFO_ASYNC 例化, 两个方向 |
| 5. 编写 ddr3_top.v | 2h | 子系统集成, 连接所有模块 |
| 6. 修改 wrapper_1g.v | 1.5h | 新增端口 + 例化 + LED 重映射 |
| 7. 修改 net_stats.v | 1h | 新增 ?ddr 调试命令 |
| 8. 修改构建脚本 | 1h | Tcl 脚本更新 |
| 9. Vivado 综合 + 实现 | 2h | 首次综合调试, 约束修正 |
| 10. 板级验证 | 4h | JTAG 烧录, UART 探针验证, ping 连通性复查 |
| 11. 端到端 TCP echo 延迟验证 | 2h | 发 TCP 数据, 验证 2s 延迟回显 |
| **合计** | **~20h** | 约 2.5 个工作日 |

---

## 9. 风险点

### 9.1 高风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|:---:|------|------|
| **MIG IP 与当前 Vivado 版本不兼容** | 中 | 高: 无法综合 | k717 是 Vivado 2019.2 工程, 当前用 2025.2。升级 MIG IP (Vivado 会自动升级, 但需验证)。备选: 在 Vivado 2025.2 中重新生成 MIG |
| **DDR3 引脚约束与物理板不匹配** | 中 | 高: 校准失败 | k717 约束来自同一开发板系列, 但需确认 ECO 板的 DDR3 引脚与 k717 的一致。若不一致需从原理图重新生成 |
| **时钟域 crossing 数据完整性** | 中 | 高: 数据错乱 | 用 XPM_FIFO_ASYNC (充分验证过的 Xilinx 宏), 配合 Gray 码指针。125↔200MHz 频率比合理, 不会出现亚稳态遗漏 |
| **时序收敛 (ui_clk ~200MHz)** | 高 | 高: 布线失败 | 200MHz 在 Kintex-7 上可行但需要仔细约束。MIG 会自动约束 DDR3 物理接口, 但用户逻辑 (buffer_mgr + axi wrappers) 的 200MHz 路径需要检查 |

### 9.2 中风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|:---:|------|------|
| **DDR3 带宽不足** | 低 | 中: 丢数据 | 1G 以太网线速 ~125MB/s, DDR3 带宽 ~6.4GB/s (200MHz×64bit×4:1), 写路径远不饱和。但回显延迟 2s 导致缓冲区可能涨到 250MB → 256MB 总容量刚好够, 需监控 |
| **MIG ui_clk 频率不确定** | 低 | 中: 定时器不准确 | k717 显示 ~200MHz, 但具体值取决于 DDR3 时钟频率÷4。需从 MIG 生成的参数确认精确值, 调整 DELAY_CYCLES |
| **AXI burst 长度与 TCP segment 不匹配** | 低 | 中: 效率低 | TCP MSS=536B, 64-bit AXI 每拍 8B, 需要 67 拍 = 536B。burst 长度需动态计算, 边界对齐 |
| **HLS IP 的 BRAM tcp_send_bufs 与 DDR3 双写竞争** | 中 | 中: 数据重复/丢失 | 第一阶段: 保留 BRAM echo 路径不变, DDR3 作为附加路径并行写入。第二阶段: 移除 BRAM echo, 纯 DDR3 路径 |

### 9.3 低风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|:---:|------|------|
| **axi_master_read/write 的 bug** | 低 | 低: 可修复 | k717 的 AXI wrapper 已在原工程验证过, 但需检查 corner case (如 len=0, 地址不对齐) |
| **LED 复用冲突** | 低 | 低: 不影响功能 | 当前 D0 用于 UART 活动指示, 改为 calib_done 后失去 UART 活动指示。可考虑用 D1-D3 的其他组合 |
| **net_stats 命令缓冲溢出** | 低 | 低: 可修复 | 新增 ?ddr 命令约 80 字节输出, 当前 net_stats 缓冲足够 |

---

## 10. 验证计划

### 10.1 阶段 1: Vivado 综合验证

1. 综合通过, 无 critical warning
2. 时序收敛: ui_clk 路径 WNS >= 0ns
3. 资源利用率报告: BRAM/FF/LUT 在合理范围

### 10.2 阶段 2: 板级基础验证

1. 烧录 bitstream, DONE=HIGH
2. LED: D0=calib_done=HIGH (MIG 校准完成), D3=ddr3_locked=HIGH
3. UART ?net: 现有网络功能不受影响 (ping 通, ARP 正常)
4. UART ?ddr: 显示 calib_done=1, locked=1, 各连接 seg_count=0

### 10.3 阶段 3: DDR3 读写测试

1. 通过 UART 命令 (或 wrapper 内测试逻辑) 触发 DDR3 写入测试模式
2. 写入已知 pattern, 读回验证
3. 验证 2s 延迟定时器

### 10.4 阶段 4: 端到端 TCP echo 延迟验证

1. PC 端 TCP 连接 FPGA port 7
2. 发送数据, 验证 2s 后回显
3. pktmon 抓包验证时序

---

## 11. 附录: k717 文件路径速查

```
参考工程根目录: D:\repo\ECO\DEMO\k717_ddr3_axi_read_write\

RTL 源文件:
  k717_ddr3_axi_read_write.srcs/sources_1/new/ddr3_axi_read_write.v
  k717_ddr3_axi_read_write.srcs/sources_1/new/axi_master_read.v
  k717_ddr3_axi_read_write.srcs/sources_1/new/axi_master_write.v

IP 核:
  k717_ddr3_axi_read_write.srcs/sources_1/ip/mig_7series_0/
  k717_ddr3_axi_read_write.srcs/sources_1/ip/clk_wiz_0/

约束文件:
  k717_ddr3_axi_read_write.srcs/constrs_1/new/ddr3_read_write_axi.xdc
  k717_ddr3_axi_read_write.srcs/constrs_1/new/ddr3_read_write.xdc
  DDR3_PIN_XDC.ucf  (根目录)

MIG 例化模板:
  k717.../ip/mig_7series_0/mig_7series_0.veo  (Verilog 例化模板)
  k717.../ip/mig_7series_0/mig_7series_0.xci  (IP 配置, XML 可读)
```

---

*文档版本: v1.0 — 2026-08-22 — DDR3 集成方案设计阶段*
# perfv — FPGA Network Protocol Stack (HLS)

FPGA IP 协议栈项目，从 Verilog UDP echo demo 逐步演进为 HLS 全栈实现。

## 关键工程

| 目录 | 内容 | 状态 |
|------|------|:--:|
| `udp/` | 原始 Verilog UDP echo demo (Vivado 2018.1) | 参考 |
| `stream_light/` | 原始 Verilog 流水灯 | 参考 |
| `stream_light_hls/` | 流水灯 HLS 重写 | ✅ |
| **`udp_hls/`** | **HLS 网络协议栈 (主工程)** | ✅ |
| `uart_test/` | 参考 UART Verilog 实现 | 参考 |

## udp_hls/ 工程概要

- **器件**: xc7a35tftg256-1
- **工具**: AMD Vitis HLS 2025.2 + Vivado 2025.2
- **时钟**: e_rxc 125MHz (GMII PHY)
- **接口**: GMII (AXI-Stream) + UART (调试控制台)

### 架构 (双 IP)

```
IP1: 网络协议栈 @125MHz
  MAC + ARP(L1+L2) + IP + ICMP + IGMP + TCP + UDP + DHCP + Stats
  HLS: 34,180 LUT / 27 BRAM  |  Vivado: ~15,000 LUT (71%)

IP2: UART Console @125MHz (同频直连, 无跨时钟域)
  9600-8N1, AXI-Stream in
  HLS: 5,274 LUT / 3 BRAM
```

### 源文件 (`src/`)

| 文件 | 功能 |
|------|------|
| `eth_types.h` | 协议类型, struct 定义, 常量 |
| `eth_utils.h` | CRC32, IP checksum, bit_reverse |
| `layer_mac.cpp` | MAC 层: GMII↔AXI-Stream, VLAN(802.1Q/802.1ad), CRC32 |
| `layer_arp.cpp` | ARP: L1(8-LRU-LUT)+L2(256-BRAM), Reply+Request |
| `layer_ip.cpp` | IP: checksum 校验, protocol 分发(1/2/6/17) |
| `layer_icmp.cpp` | ICMP: Echo Reply (ping) |
| `layer_igmp.cpp` | IGMPv1/v2: Membership Report |
| `layer_tcp.cpp` | TCP: Reno+滑动窗口+RTO+MSS/WS options, 3连接, port 7 echo |
| `layer_udp.cpp` | UDP: 8080 echo, ARP lookup integration |
| `layer_dhcp.cpp` | DHCP: DORA sequence, IP 自动获取 |
| `layer_stats.cpp` | 统计计数器 + ARP dump→msg_stream |
| `udp_echo.cpp` | 顶层集成, HLS 入口 |

### 构建流程

1. `run_hls.bat` → 网络 IP HLS 综合 (csim + csynth)
2. `uart_hls/run_hls.tcl` → UART IP HLS 综合
3. `run_vivado_wrapper.tcl` → Vivado synth+impl+bitstream
4. `program.tcl` → 烧录

### HLS 关键约束

```cpp
#pragma HLS INTERFACE axis port=rx_stream    // AXI-Stream
#pragma HLS INTERFACE ap_ctrl_none port=return // free-running
config_rtl -reset all -reset_async -reset_level low
```

- 时钟: 125MHz (8ns), 异步低复位
- 层间通信: struct 引用 (非 stream, 避免 FIFO 开销)
- 共享 buffer: `static uint32_t buffer[512]` → BRAM 推断
- ARP table: `static arp_entry_t[256]` → BRAM
- TCP conn: `static tcp_conn_t[MAX_TCP_CONN]` → BRAM

### 常见问题

1. **pragma 必须在函数内**: `#pragma HLS RESOURCE` 不能放在文件作用域
2. **`uint8_t` 索引截断**: 地址 ≥256 时需用 `uint16_t`
3. **跨周期变量**: 用 `static` 保存，不依赖 `rx.xxx = 0` (每周期清零)
4. **`fpga_gclk` 未用**: 声明但不连接会导致 DONE=LOW，需移除端口
5. **DONE=LOW 调试**: 先分别测各 IP 能否独立烧录, 定位问题 IP
6. **UART 同频**: 当前 UART 与网络共用 e_rxc (125MHz)，波特率分频=13020

### 板级信息

- 目标板: Digilent/210203367162A
- MAC: 00:0A:35:01:FE:C0
- IP: 静态 192.168.0.2 / DHCP 自动
- UART: 9600-8N1, P9(RX)/N9(TX)
- 命令: `?help ?mac ?ip ?dhcp ?arp ?stat`

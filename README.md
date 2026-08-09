# udp_echo HLS — FPGA 网络协议栈

基于 AMD Vitis HLS 2025.2 的 FPGA 千兆以太网协议栈实现，从原始 Verilog UDP echo demo 逐步演进而来。

## 硬件

- **器件**: xc7a35tftg256-1 (Artix-7 35T)
- **开发板**: Digilent/210203367162A
- **时钟**: e_rxc 125MHz (GMII from PHY)
- **接口**: GMII (千兆以太网) + UART (调试控制台)

## 协议支持

| 层级 | 协议 | 端口 | 说明 |
|------|------|:---:|------|
| L2 | Ethernet II + VLAN (802.1Q/802.1ad) | — | RX/TX, 双层 QinQ |
| L2.5 | ARP | — | L1:8(LRU)+L2:256(BRAM), Reply + 主动查询 |
| L3 | IPv4 | — | checksum 校验 |
| L3 | ICMP | — | Echo Reply (ping) |
| L3 | IGMPv1/v2 | — | Membership Report (组播 239.0.0.1) |
| L4 | UDP | 8080 | Echo |
| L4 | UDP | 68 | DHCP Client (DORA) |
| L4 | TCP | 7 | Echo Server (Reno + sliding window + 选项) |
| App | UART Console | — | 9600-8N1, ?help ?mac ?ip ?dhcp ?arp ?stat |

## 资源占用 (Vivado 最终布线)

| 资源 | 已用 | 可用 | 利用率 |
|------|------|------|------|
| Slice LUTs | 14,761 | 20,800 | 71% |
| Slice Registers | 14,434 | 41,600 | 35% |
| BRAM Tiles | 46 RAMB18 + 2 RAMB36 | 150 | ~32% |
| DSP48E1 | 10 | 90 | 11% |
| Timing (WNS) | +inf | — | ✅ |

## 项目结构

```
udp_hls/
├── src/                    # 网络协议栈 HLS 源码
│   ├── eth_types.h         #   协议类型定义
│   ├── eth_utils.h         #   CRC32, checksum, 工具函数
│   ├── layer_mac.cpp       #   MAC 层 (GMII + VLAN + CRC)
│   ├── layer_arp.cpp       #   ARP (L1+L2 两级缓存)
│   ├── layer_ip.cpp        #   IP 层 (checksum + protocol 分发)
│   ├── layer_icmp.cpp      #   ICMP Echo Reply
│   ├── layer_igmp.cpp      #   IGMPv1/v2
│   ├── layer_tcp.cpp       #   TCP (Reno + 选项 + 多连接)
│   ├── layer_udp.cpp       #   UDP (echo + DHCP)
│   ├── layer_dhcp.cpp      #   DHCP Client (DORA)
│   ├── layer_stats.cpp     #   统计计数器 + ARP dump
│   └── udp_echo.cpp        #   顶层集成
├── uart_hls/               # UART Console 独立 IP
│   └── src/uart_console.cpp
├── tb/                     # 测试平台 (13 项 C 仿真)
├── wrapper.v               # Vivado 顶层 wrapper
├── run_hls.tcl             # HLS 综合脚本
├── run_vivado_wrapper.tcl  # Vivado 实现脚本
├── ARCHITECTURE.md         # 详细架构文档
└── README.md               # 本文档
```

## 构建

```bash
# 网络 IP HLS 综合 (125MHz)
cd udp_hls
cmd //c run_hls.bat

# UART IP HLS 综合 (125MHz)
cd udp_hls/uart_hls
cmd //c "C:\...\vitis-run.bat --mode hls --tcl --part xc7a35tftg256-1 --freqhz 125000000 run_hls.tcl"

# Vivado 综合 + bitstream
cd udp_hls
vivado -mode batch -source run_vivado_wrapper.tcl

# 烧录
vivado -mode batch -source program.tcl
```

## UART 命令

| 命令 | 功能 |
|------|------|
| `?help` | 命令列表 |
| `?mac` | 显示 MAC 地址 |
| `?ip` | 显示 IP (DHCP 后自动更新) |
| `?dhcp` | DHCP 状态 + 分配的 IP |
| `?arp` | ARP 缓存表 |
| `?stat` | 收发包统计 |

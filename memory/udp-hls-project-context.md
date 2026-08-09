---
name: udp-hls-project-context
description: udp_hls HLS 网络协议栈 — 架构、资源、构建、板级信息
metadata: 
  node_type: memory
  type: project
  originSessionId: c9327a9f-9795-4727-9c2d-62d7406c8740
---

# udp_hls — FPGA 网络协议栈 (HLS)

## 概述

从原始 Verilog UDP echo demo 逐步演进为 HLS 全协议栈。双 IP 架构 (网络 @125MHz + UART @125MHz)，xc7a35tftg256-1 器件，Vivado 实际布线 LUT 71%。

## 目录结构

```
udp_hls/
├── src/          # 网络 IP (13 源文件, HLS 入口: udp_echo.cpp)
├── uart_hls/     # UART IP (独立 HLS 项目)
├── tb/           # C 仿真 (13 测试)
├── wrapper.v     # Vivado 顶层
├── run_*.tcl     # 构建脚本
└── ARCHITECTURE.md / README.md
```

## 架构

- **MAC**: AXI-Stream GMII + VLAN(802.1Q/802.1ad) RX/TX + CRC32
- **ARP**: L1(8-LRU-LUT)+L2(256-BRAM), Reply+主动查询
- **IP**: checksum 校验, protocol→1(ICMP)/2(IGMP)/6(TCP)/17(UDP)
- **TCP**: Reno+滑动窗口+RTO+MSS/WS, MAX_TCP_CONN=3, port 7 echo
- **UDP**: 8080 echo + 68 DHCP client
- **UART**: 9600-8N1, ?help/?mac/?ip/?dhcp/?arp/?stat
- 层间: struct 引用, 共享 buffer[512], 无内部 stream
- 统计: 每 ~0.8s 自动 dump→msg_stream→UART

## 构建

1. `udp_hls/run_hls.bat` → 网络 IP HLS
2. `udp_hls/uart_hls/` → UART IP HLS (125MHz)
3. `run_vivado_wrapper.tcl` → Vivado bitstream
4. `program.tcl` → 烧录

## 关键参数

- 时钟: 125MHz e_rxc (单时钟, 双 IP 共享)
- MAC: 00:0A:35:01:FE:C0
- IP: 192.168.0.2 (静态) / DHCP 自动
- HLS pragma: ap_ctrl_none, axis on streams
- 复位: async low

## 已知问题

- `fpga_gclk` 端口声明但未连接 → DONE=LOW, 需移除
- HLS pragma 必须在函数作用域
- uint8_t 不能做 buffer 索引 (≥256 截断)
- 网络 IP 需从 PHY 获取 e_rxc (125MHz), 无 PHY 时钟则无法启动

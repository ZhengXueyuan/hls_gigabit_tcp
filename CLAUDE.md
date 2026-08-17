# udp_hls_eco — Kintex-7 ECO 板网络协议栈 (施工中)

perfv `udp_hls` HLS 网络协议栈移植到 ECO 板 (XC7K325T-2FFG676C) 的副本工程。
原始工程 (D:\repo\perfv) 不改。移植总纲: `MIGRATION_K7325T.md`; 施工日志: `PORT_NOTES.md`
(**每次实验先追加记录再动手**); 全局 HLS 铁律在用户 CLAUDE.md (ap_ctrl_none body II=1 /
异步引脚同步器写在 wrapper / csim≠板级 等)。

## 当前状态 (2026-08-18)

- ✅ UART console 板级通 (`?mac ?ip ?stat`), RX 通路逐字节验证完美
- ✅ 协议栈 4 个 C++ bug 已修并重新综合 (03:45): MAC padding (runt) / DHCP 帧结构 /
  DHCP 洪泛 / wrapper rx_last 极性。csim 14 项全过。
- 🔧 **唯一遗留: FPGA TX 帧到不了 PC (pktmon 零包)**。已破案: demo 克隆生成器
  eth_crc32 用 unreflected CRC → 线上 FCS 位反转 → 网卡静默丢。修复 (0xEDB88320
  reflected) 已应用, 板级复核中 (agent 任务 #14 在跑, 别重复派活)。
- ⬜ 端到端验证: ping → UDP 8080 → TCP 7 (TX 打通后)

## 工程结构

| 文件 | 内容 |
|------|------|
| `src/*.cpp` | HLS 协议栈源码 (MAC/ARP/IP/ICMP/IGMP/TCP/UDP/DHCP/stats) |
| `udp_echo_prj/solution1/syn/verilog/` | 网络 IP 综合产物 (36,200 LUT, 事件驱动 FSM 无 II 要求) |
| `uart_hls/uart_prj/solution1/syn/verilog/` | UART IP (1,765 LUT, **必须 Latency 0 / Interval 1**) |
| `wrapper_1g.v` | 主顶层: MMCM 200M + util_gmii_to_rgmii (k720 逐字) + RX/TX FIFO 帧桥 + demo 克隆生成器 + net_stats |
| `net_stats.v` | UART 探针: `?net ?txd ?rxd ?raw` (计数+帧捕获, 50MHz 独立) |
| `xdc/eco_rgmii_phy1.xdc` | 引脚 + 时钟约束 (phy1_rxc 8ns master + BUFG 反相 generated) |
| `wrapper_min*.v` + `eth_rebuild_*.v` + `eth_test_gen.v` | 调试变体 (demo 重建 bisect 用) |

## 构建

```bash
cmd //c run_hls.bat                       # 网络 IP (csim+csynth)
cd uart_hls && cmd //c run_hls.bat        # UART IP
cmd //c run_vivado_phy1g2.bat             # 主工程 → vivado_prj/udp_dual_phy1g2/.../wrapper_1g.bit
vivado -mode batch -source program_eco.tcl -tclargs <bit 路径>   # 烧录 JTAG 1MHz
```

## 板级调试工具

- UART COM8 9600-8N1 (PowerShell + System.IO.Ports); `udp_console_test.ps1` / `net_test.ps1`
- PC 抓包: pktmon comp 117 (Killer E5000B) 混杂模式; demo bitstream 对照实验同板同线
- 验证 ping 必须确认走有线网卡 (WLAN 假阳性, 用户纠正过)

## 本工程特有坑 (教训)

1. **网卡静默丢弃三原因**: runt <64B / FCS 错 / 字节错位 — FCS 错最容易在"自己验证自己"
   的闭环里漏掉 (生成器 CRC 与校验方同源)。对照实验的"同一帧"必须字节级比对 FCS。
2. HLS IP 是 call-based: TVALID 帧内空洞、TREADY 仅外层 FSM 拉高 → wrapper 必须用
   FIFO 整帧缓冲桥 (TX 2048×9, TLAST=TDATA[8], ≥12 周期 IFG)。
3. k720 工程的"实际" ethernet_test ≠ src/ 树 (工程版带 gmii_arbi+mac_test+6 个 Xilinx IP),
   对照位流按工程版还原。
4. ODDR 的 Q 只能接 OBUF/port — 想在 ODDR 输出采样 pad 电平要用 IOBUF (T=0)。
5. 功率门控实验若把 IP 复位 (ip_enable=0), 其 TX regslice 会打垃圾帧污染线上 TXEN —
   必须同时门控 tx_push; 且 Vivado 会把常复位 IP 优化掉 (利用率失真)。

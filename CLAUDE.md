# udp_hls_eco — Kintex-7 ECO 板网络协议栈 (施工中)

perfv `udp_hls` HLS 网络协议栈移植到 ECO 板 (XC7K325T-2FFG676C) 的副本工程。
原始工程 (D:\repo\perfv) 不改。移植总纲: `MIGRATION_K7325T.md`; 施工日志: `PORT_NOTES.md`
(**每次实验先追加记录再动手**); 全局 HLS 铁律在用户 CLAUDE.md (ap_ctrl_none body II=1 /
异步引脚同步器写在 wrapper / csim≠板级 等)。

## 当前状态 (2026-08-18)

- ✅ UART console 板级通 (`?mac ?ip ?stat`), RX 通路逐字节验证完美
- ✅ 协议栈 4 个 C++ bug 已修并重新综合: MAC padding (runt) / DHCP 帧结构 /
  DHCP 洪泛 / wrapper rx_last 极性。csim 全过。
- ✅ **TX 已打通** (2026-08-18 破案): 根因 = FCS **字节序必须 LSB-first**
  (demo 帧线上 FCS = CA A3 F9 63 = zlib 寄存器 0x63F9A3CA 小端; 之前发的 63 F9 A3 CA
  被网卡静默丢)。修复 = reflected CRC-32 (0xEDB88320) + 按 fcs[7:0],[15:8],[23:16],[31:24]
  发出, 已应用到全部 7 个 Verilog 生成器 + HLS layer_mac.cpp。wrapper_min 板级验证:
  pktmon 25s = 25 帧 FPGA ARP ✓ (与 demo 逐字节一致)。
- ✅ **端到端 ping 已通** (2026-08-18 09:05 位流): ping 192.168.100.2 4/4 回复 0ms。
  ICMP 校验和第二 bug 修复: `buffer[tx_base] &= 0xFFFF00FF` 只清了校验和字段高字节,
  请求校验和低字节 (0xD4) 残留污染求和 → 改 `&= 0xFFFF0000`; TB 已加校验和检查。
- ⬜ 下一轮: UDP 8080 echo (当前超时 — 疑 UDP RX 校验和验证/回复构造同类问题,
  用 pktmon --hex 独立校验线上字节) → TCP 7 echo。

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
   的闭环里漏掉 (生成器 CRC 与校验方同源)。对照实验的"同一帧"必须**全帧逐字节**比对 FCS
   (之前只比前 24 字节, 漏掉了 FCS 字节序)。
2. **FCS 字节序铁律**: 本板 PHY/PC 链只接受 LSB-first 线上字节序 (demo 帧 = CA A3 F9 63)。
   FCS 的"标准"有实现歧义 — 以权威 demo 位流的线上字节为基准, 不要自证。
3. HLS IP 是 call-based: TVALID 帧内空洞、TREADY 仅外层 FSM 拉高 → wrapper 必须用
   FIFO 整帧缓冲桥 (TX 2048×9, TLAST=TDATA[8], ≥12 周期 IFG)。
4. k720 工程的"实际" ethernet_test ≠ src/ 树 (工程版带 gmii_arbi+mac_test+6 个 Xilinx IP),
   对照位流按工程版还原。
5. ODDR 的 Q 只能接 OBUF/port — 想在 ODDR 输出采样 pad 电平要用 IOBUF (T=0)。
6. 功率门控实验若把 IP 复位 (ip_enable=0), 其 TX regslice 会打垃圾帧污染线上 TXEN —
   必须同时门控 tx_push; 且 Vivado 会把常复位 IP 优化掉 (利用率失真)。

# udp_hls_eco — Kintex-7 ECO 板 FPGA 网络协议栈

基于 AMD Vitis HLS 2025.2 的 FPGA 千兆以太网协议栈实现,从 perfv 工程 (Artix-7)
移植到 ECO 开发板 (Kintex-7 XC7K325T)。原始工程在 `D:\repo\perfv\udp_hls`,
本目录是副本 (原工程保持不变)。移植总纲见 [MIGRATION_K7325T.md](MIGRATION_K7325T.md),
完整施工日志见 [PORT_NOTES.md](PORT_NOTES.md)。

> **状态 (2026-08-18)**: ✅ **ping 192.168.100.2 已通 (4/4 回复 0ms)** — 端到端链路打通!
> 根因链: FCS 字节序 LSB-first + ICMP 校验和字段只清 1 字节 (均被"自证闭环"掩盖)。
> UART console、RX 通路、ARP、ICMP 板级验证 ✓。遗留: UDP 8080 echo 超时 (疑同类校验和
> bug, 下一轮用 pktmon --hex 独立校验), 之后 TCP 7。

## 硬件

- **器件**: xc7k325tffg676-2 (Kintex-7 XC7K325T, FFG676)
- **开发板**: ECO 板 (R3 PCB, 与 DEMO/k701-k734 同板)
- **PHY**: RTL8211E-VL, 用 PHY1 (丝印 ETH1), RGMII 4bit DDR, 1.8V IO (bank 34)
- **引脚** (k719/k720 demo 引脚组, 板级实测确认 — R3 原理图分配不成立):
  rxc=AB2, rxd=AE2/AE1/AC1/AC2, rxctl=AF3, txc=AB1, txd=AB4/AA4/AA3/AA2, txctl=Y3
- **PHY 配置**: strap 配置 (TXDLY=RXDLY=1, PHYAD=0x1), 不用 MDIO — 与 demo 一致
- **时钟**: phy1_rxc 125MHz (RGMII 1G) → LUT1 反相 BUFG (gmii_clk);
  fpga_gclk 50MHz (G22) → MMCM 200MHz (IDELAYCTRL 参考)
- **UART**: B17(RX)/A17(TX), CH340E, 9600-8N1, PC 侧 COM8
- **复位**: D26 (KEY1, 低有效)  |  **LED**: A23/A24/D23/C24
- **MAC**: 00:0A:35:01:FE:C0  |  **IP**: 192.168.100.2 (PC 有线网卡 192.168.100.1/24)

## 协议支持

| 层级 | 协议 | 端口 | 说明 |
|------|------|:---:|------|
| L2 | Ethernet II + VLAN (802.1Q/802.1ad) | — | RX/TX, 双层 QinQ, <46B 自动 padding (2026-08-18 修) |
| L2.5 | ARP | — | L1:8(LRU)+L2:256(BRAM), Reply + Request |
| L3 | IPv4 | — | checksum 校验 |
| L3 | ICMP | — | Echo Reply (ping) |
| L3 | IGMPv1/v2 | — | Membership Report (组播 239.0.0.1) |
| L4 | UDP | 8080 | Echo |
| L4 | UDP | 68 | DHCP Client (DORA, 2026-08-18 修帧结构+洪泛) |
| L4 | TCP | 7 | Echo Server (Reno + 滑动窗口 + 选项, 3 连接) |
| App | UART Console | — | 9600-8N1, `?help ?mac ?ip ?dhcp ?arp ?stat` |

## 架构 (双 IP + wrapper)

```
wrapper_1g.v  (Vivado 顶层)
├── IP1: udp_echo  HLS 网络协议栈 @125MHz gmii_clk
│     MAC + ARP + IP + ICMP + IGMP + TCP + UDP + DHCP + Stats
│     ap_ctrl_none 自由运行, 事件驱动 FSM (无 II 要求)
│     HLS 综合: 27 BRAM / 4 DSP / 15,655 FF / 36,200 LUT (17%)
├── IP2: uart_console  HLS UART @50MHz fpga_gclk
│     Latency 0 / Interval 1 (铁律 ✓)  |  268 FF / 1,765 LUT
├── RGMII 适配: util_gmii_to_rgmii (k720 demo 原版逐字)
├── AXI-Stream 帧缓冲桥 (IP 是 call-based, TVALID 帧内有空洞):
│     TX: 2048×9 FIFO 整帧缓冲后连续发出 (TLAST=TDATA[8], ≥12 周期 IFG)
│     RX: 2048×9 FIFO 按 IP TREADY 节奏喂
├── demo 克隆帧发生器 (k720 ipsend 同款 72B ARP 帧 @1Hz, CRC32 已修位序)
└── net_stats UART 探针: ?net ?txd ?rxd ?raw (收发包计数 + 帧捕获)
```

## 资源占用

| 模块 | LUT | FF | BRAM | 说明 |
|------|-----|----|------|------|
| udp_echo (HLS 综合 2026-08-18) | 36,200 | 15,655 | 27×18K | xc7k325t, 17% LUT |
| uart_console (HLS 综合) | 1,765 | 268 | 0 | Latency 0 / Interval 1 ✓ |
| wrapper_min (无 HLS IP 最小设计) | 600 | 1,082 | 0 | WNS=0.608, 0.298W |

完整 Vivado 布线结果见各 `vivado_prj/*.runs/impl_1/*_utilization_placed.rpt`。

## 构建流程

```bash
# 1. HLS 综合两个 IP (csim + csynth; Vitis 2025.2 无 v++ 命令行, 必须走 vitis-run)
cmd //c run_hls.bat                     # 网络 IP → udp_echo_prj/solution1/syn/verilog/
cd uart_hls && cmd //c run_hls.bat      # UART IP → uart_hls/uart_prj/solution1/syn/verilog/

# 2. Vivado 综合 + 实现 + bitstream (主工程: wrapper_1g + 双 IP + RGMII)
cmd //c run_vivado_phy1g2.bat           # → vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit

# 3. 烧录 (JTAG 1MHz 自动)
vivado -mode batch -source program_eco.tcl -tclargs <path/to/xxx.bit>
```

最小实验工程: `run_vivado_min*.bat` (wrapper_min/min_reg/min_pin 变体, 见 PORT_NOTES)。

## 板级测试脚本

| 脚本 | 用途 |
|------|------|
| `udp_console_test.ps1` | UART console (?mac 等命令, COM8 9600) |
| `net_test.ps1` | UART 探针 (?net ?txd ?rxd ?raw) |
| `ping_test.ps1` | ping 192.168.100.2 |
| `echo_test.ps1` / `icmp_test.ps1` / `tcp_test.ps1` | UDP 8080 / ICMP / TCP 7 回显 |
| `nic_stats.ps1` | PC 网卡计数 (FPGA 帧是否到达) |
| `check_link.ps1` | 网卡链路状态 |

pktmon 抓包法 (PC 网卡 comp 117 = Killer E5000B, **混杂模式**才能看到非本机 IP 的包):

```powershell
pktmon start --comp 117 --flags 0x20 -f D:\repo\ECO\udp_hls_eco\pk.etl
pktmon stop
pktmon format pk.etl -o pk.txt   # 以太网 RX 帧以 "PktGroupId" 分组
```

## 已知问题与修复记录

| # | 问题 | 状态 |
|---|------|------|
| 1 | ARP 帧 46B runt < 64B → 网卡静默丢弃 | ✅ 已修 (MAC padding) |
| 2 | DHCP 帧缺 IP 头 + 缓冲越界 | ✅ 已修 (完整 IPv4 头 + 新帧布局) |
| 3 | DHCP 无限洪泛 (~134ms/次) | ✅ 已修 (DHCP_FAILED 状态 + 重试复位) |
| 4 | wrapper rx_last_in 极性反 | ✅ 已修 (dv 下降沿) |
| 5 | demo 克隆生成器 FCS 错 (两重: ① unreflected CRC 多项式 ② 线上字节序 MSB-first) → 所有帧被网卡当 FCS 错静默丢弃 | ✅ 已修 (reflected CRC-32 + **LSB-first 字节序** fcs[7:0],[15:8],[23:16],[31:24], 板级验证 pk21 = 25 帧 ✓) |
| 6 | TX 帧到不了 PC (pktmon 零包) | ✅ 已通 — ping 4/4 0ms 板级验证 |
| 7 | ICMP 回复校验和错 (0x4600, 应 0x46D4) → Windows 静默丢 | ✅ 已修 (`&= 0xFFFF00FF` 只清高字节 → `&= 0xFFFF0000`), TB 加校验和检查 |
| 8 | UDP 8080 echo 超时 | 🔧 疑 UDP RX 校验和/回复构造同类 bug, 下一轮 pktmon --hex 独立校验 |

> **FCS 铁律 (本板 PHY/PC 链)**: 线上 FCS 字节序必须 LSB-first — demo 帧 FCS = CA A3 F9 63
> (zlib 寄存器 0x63F9A3CA 的小端输出)。FCS 的"标准"有实现歧义, **必须以权威 demo 位流的
> 线上字节为基准, 不能用自己的参考实现自证** (自证闭环漏掉了字节序)。之前的功率/结构/
> 相位假设全部撤销, 归因于此。
>
> **校验和铁律**: 线上校验和/内容问题必须用 `pktmon etl2txt --hex` 抓原始字节 +
> Python 等独立参考实现校验 — 与设计同源的参考自证两次漏检 (FCS 字节序、ICMP 校验和)。

## 项目结构

```
udp_hls_eco/
├── src/                    # 网络协议栈 HLS 源码
│   ├── eth_types.h         #   协议类型 + BOARD_IP/MAC 定义
│   ├── eth_utils.h         #   CRC32, IP checksum, 工具
│   ├── layer_mac.cpp       #   MAC 层 (GMII + VLAN + CRC + padding)
│   ├── layer_arp.cpp       #   ARP (L1+L2 两级缓存)
│   ├── layer_ip.cpp        #   IP 层 (checksum + 分发)
│   ├── layer_icmp.cpp      #   ICMP Echo Reply
│   ├── layer_igmp.cpp      #   IGMPv1/v2
│   ├── layer_tcp.cpp       #   TCP (Reno + 选项 + 多连接)
│   ├── layer_udp.cpp       #   UDP (8080 echo + DHCP)
│   ├── layer_dhcp.cpp      #   DHCP Client (DORA)
│   ├── layer_stats.cpp     #   统计计数器 + ARP dump
│   └── udp_echo.cpp        #   顶层集成 (HLS 入口)
├── uart_hls/               # UART Console 独立 IP
├── tb/                     # C 仿真测试 (14 项)
├── wrapper_1g.v            # 主顶层: RGMII + 双 IP + FIFO 桥 + 探针
├── wrapper_min*.v          # 最小实验变体 (调试用, 见 PORT_NOTES)
├── net_stats.v             # UART 统计探针模块
├── util_gmii_to_rgmii.v    # k720 demo RGMII 转换器 (原版)
├── xdc/eco_rgmii_phy1.xdc  # 约束 (引脚 + 时钟)
├── run_hls.bat / run_hls.tcl
├── run_vivado_phy1g2.bat / .tcl   # 主 Vivado 构建
├── program_eco.tcl         # 烧录 (JTAG 1MHz)
├── ARCHITECTURE.md         # 协议栈架构文档
├── MIGRATION_K7325T.md     # 移植指南 (硬件结论 + 操作步骤)
├── PORT_NOTES.md           # 完整施工日志 (所有实验记录)
└── 网络验证指南.md          # 网络验证步骤
```

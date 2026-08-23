# udp_hls_eco — Kintex-7 ECO 板 FPGA 网络协议栈

基于 AMD Vitis HLS 2025.2 的 FPGA 千兆以太网协议栈实现,从 perfv 工程 (Artix-7)
移植到 ECO 开发板 (Kintex-7 XC7K325T)。原始工程在 `D:\repo\perfv\udp_hls`,
本目录是副本 (原工程保持不变)。移植总纲见 [MIGRATION_K7325T.md](MIGRATION_K7325T.md),
完整施工日志见 [PORT_NOTES.md](PORT_NOTES.md)。

> **状态 (2026-08-23)**: ✅ **全链打通并通过压测** — `py_net_test.py` (anaconda python)
> **7/7 全 PASS**: ping / UDP 64B / UDP 512B / TCP 25B / TCP 1608B / **TCP 2000B×3**。
> 可用功能: UART console (`?mac ?ip ?stat ?net`)、ARP、ping (ICMP)、UDP 8080 echo、TCP 端口 7 echo。
> **2000B 第4段错位已破案修复**: 根因 = wrapper `rx_fifo` 溢出 (2048深/1900门限 顶不住
> 4段背靠背 ~2392B, DUT 排空 ~1字节/20周期), **非 HLS 协议栈竞态** (xsim 直喂 DUT 2000B
> 逐字节全对)。修复: `rx_fifo` 2048→4096 / 门限 1900→3900 / 指针 11→12bit, 生产位流 7/7 PASS。
> 完整调查链见 [RX_FIFO_OVERFLOW_ANALYSIS.md](RX_FIFO_OVERFLOW_ANALYSIS.md)。
> 注意是治标 (4096 约容 ≤6 段); 治本 = 提升 DUT 排空速率, 列为后续可选优化。

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
│     RX 已重构为 hls::stream 模式 (UG1399): MAC RX → frame_fifo(512深)
│       → frame_done 当拍暂存 frame_buf[400] → 各层 0 基偏移解析;
│       共享 buffer[768] 现为 TX 专用 (TX_SCRATCH/DHCP/TX_UDP)
│     HLS 综合: 27 BRAM / 4 DSP / 15,655 FF / 36,200 LUT (17%)  (2026-08-18, 重构前)
├── IP2: uart_console  HLS UART @50MHz fpga_gclk
│     Latency 0 / Interval 1 (铁律 ✓)  |  268 FF / 1,765 LUT
├── RGMII 适配: util_gmii_to_rgmii (k720 demo 原版逐字)
├── AXI-Stream 帧缓冲桥 (IP 是 call-based, TVALID 帧内有空洞):
│     TX: 2048×9 FIFO 整帧缓冲后连续发出 (TLAST=TDATA[8], ≥12 周期 IFG)
│     RX: 4096×9 FIFO (阈值 3900, 2026-08-23 由 2048/1900 加深 — 修 2000B 溢出)
│         按 IP TREADY 节奏喂
├── demo 克隆帧发生器 (k720 ipsend 同款 72B ARP 帧 @1Hz, CRC32 已修位序)
└── net_stats UART 探针: ?net ?txd ?rxd ?raw (收发包计数 + 帧捕获)
```

## 资源占用

| 模块 | LUT | FF | BRAM | 说明 |
|------|-----|----|------|------|
| udp_echo (HLS 综合 2026-08-18, stream 重构前) | 36,200 | 15,655 | 27×18K | xc7k325t, 17% LUT |
| uart_console (HLS 综合) | 1,765 | 268 | 0 | Latency 0 / Interval 1 ✓ |
| wrapper_min (无 HLS IP 最小设计) | 600 | 1,082 | 0 | WNS=0.608, 0.298W |

> 注: 2026-08-23 RX stream 化重构 + 修复后的最新综合数据以 `udp_echo_prj/solution1/syn/report/`
> 为准 (PORT_NOTES 记录重构后约 BRAM 3% / LUT 20%); 上表 36,200 LUT 为重构前 (2026-08-18)
> 记录值。

完整 Vivado 布线结果见各 `vivado_prj/*.runs/impl_1/*_utilization_placed.rpt`。

## 构建流程

```bash
# 1. HLS 综合两个 IP (csim + csynth; Vitis 2025.2 无 v++ 命令行, 必须走 vitis-run)
cmd //c run_hls.bat                     # 网络 IP → udp_echo_prj/solution1/syn/verilog/
cd uart_hls && cmd //c run_hls.bat      # UART IP → uart_hls/uart_prj/solution1/syn/verilog/
#   便捷变体: _run_csynth_only.bat (跳过csim) / _run_csim_only.bat / _run_cosim.bat

# 2. Vivado 综合 + 实现 + bitstream (主工程: wrapper_1g + 双 IP + RGMII)
cmd //c _run_vivado_caller.bat          # → vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit
#   (等价底层脚本: run_vivado_phy1g2.bat)

# 3. 烧录 (JTAG 1MHz 自动)
cmd //c _run_prog_caller.bat
#   (等价: vivado -mode batch -source program_eco.tcl -tclargs <path/to/xxx.bit>)
```

最小实验工程: `run_vivado_min*.bat` (wrapper_min/min_reg/min_pin 变体, 见 PORT_NOTES)。
ILA 调试变体: `wrapper_1g_ila.v` + `run_vivado_ila.bat` (工程 `vivado_ila_prj/`),
捕获 `ila_capture.bat`, 分析 `ila_analyze2.py`。
xsim RTL 仿真: `tb_udp_echo.v` (DUT-only) / `tb_wrapper_rx.v` (FIFO+DUT 复现溢出),
刺激 `gen_stim.py`→stim.memh, 校验 `parse_resp.py`。

## 板级测试脚本

| 脚本 | 用途 |
|------|------|
| `py_net_test.py` | **一键回归 (anaconda python): ping/UDP64/UDP512/TCP25/TCP1608/TCP2000×3 — 7/7 PASS** |
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
| 8 | UDP 8080 echo 超时 | ✅ 已修 — 真根因 = `ap_uint<9>` 地址字段截断 TX_UDP_BASE=512→0 (改 `ap_uint<10>`) + `uint8_t wi` payload 索引溢出 (改 `uint16_t`) |
| 9 | TCP 2000B 第4段错位 (非确定偏移~1739) | ✅ 已破案修复 — 根因 = **wrapper rx_fifo 溢出** (2048深/1900门限, 非 HLS 竞态); 修复 2048→4096/3900, 7/7 PASS。详见 RX_FIFO_OVERFLOW_ANALYSIS.md |

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
├── tb_udp_echo.v           # xsim RTL TB: DUT-only 2000B 复现/验证 (证 DUT 无错)
├── tb_wrapper_rx.v         # xsim RTL TB: rx_fifo+DUT, 复现 wrapper FIFO 溢出
├── gen_stim.py             # 生成 xsim 刺激 stim.memh
├── parse_resp.py           # 校验 DUT 回显逐字节
├── py_net_test.py          # 板级一键回归 (7/7 PASS, anaconda python)
├── wrapper_1g.v            # 主顶层: RGMII + 双 IP + FIFO 桥 + 探针 (rx_fifo 4096/3900)
├── wrapper_1g_ila.v        # ILA 调试变体 (ila_0 探针, 工程 vivado_ila_prj/)
├── wrapper_min*.v          # 最小实验变体 (调试用, 见 PORT_NOTES)
├── net_stats.v             # UART 统计探针模块
├── util_gmii_to_rgmii.v    # k720 demo RGMII 转换器 (原版)
├── xdc/eco_rgmii_phy1.xdc  # 约束 (引脚 + 时钟)
├── run_hls.bat / run_hls.tcl
├── _run_csynth_only.bat / _run_csim_only.bat / _run_cosim.bat
├── _run_vivado_caller.bat / run_vivado_phy1g2.bat / .tcl   # 主 Vivado 构建
├── _run_prog_caller.bat / program_eco.tcl   # 烧录 (JTAG 1MHz)
├── run_vivado_ila.bat / ila_capture.bat / ila_analyze2.py  # ILA 调试链
├── ARCHITECTURE.md         # 协议栈架构文档
├── RX_FIFO_OVERFLOW_ANALYSIS.md  # 2000B 破案最终权威分析
├── MIGRATION_K7325T.md     # 移植指南 (硬件结论 + 操作步骤)
├── PORT_NOTES.md           # 完整施工日志 (所有实验记录)
└── 网络验证指南.md          # 网络验证步骤
```

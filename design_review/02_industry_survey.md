# 02 行业调研: FPGA 10G 以太网 / TCP 协议栈方案调研

> 日期: 2026-08-23 | 调研人: Agent 2 (Web 调研, 只读)
> 背景: udp_hls_eco 现为 1G RGMII + HLS 单 FSM (约 1 字节/20 周期, ~50Mbps), 目标为 Kintex-7 XC7K325T (326,080 LUT / 407,600 FF / 445 BRAM36 / 16 GTX) 上的 10G 纯硬件 TCP/IP 协议栈: 低延时 UDP 组播行情线速不丢包 + TCP 少量长连接 (4-16) 亚微秒延迟。
> 结论先行: **XC7K325T 实现 10G 数据面 + 4-16 连接 TOE 在资源上完全可行**; 最大风险不是逻辑量, 而是"单 FSM 顺序处理"这一架构模式必须替换为多级流水 + fast/slow path 分流。

---

## 1. 开源方案

### 1.1 Corundum (alexforencich, UCSD, FCCM 2020) — 开源 100G NIC 标杆
- **架构**: 三层嵌套 — top (PCIe/DMA/PTP/MAC 硬件) → interface (每 OS 网络接口的队列管理) → port (每 MAC 的 TX/RX engine + scheduler + scratchpad)。**端口与网络接口分离**: 多端口可共享队列, 由可替换的 TX scheduler 映射, 支持流迁移/负载均衡。
- **datapath**: AXI-Stream 为主; 10G 端口为 64bit @ 156.25MHz; 自定义 segmented memory 接口做 DMA; 队列状态仅 128bit/队列, 4096 队列只用 2 URAM; TX 端软件分类入队 + 校验和卸载, RX 端 RSS flow-hash 分流队列。
- **资源量级** (整卡含 PCIe DMA + 队列管理, 100G): Alveo U200 ~71.7K LUT / 115K FF / 141 BRAM / 34 URAM; U250 ~53.7K LUT。FCCM 论文: 双 10G 端口 + PCIe Gen3 x8 设计 (ExaNIC X10) 用不到 KU035 的 1/4 逻辑。
- **注意**: 官方支持 Virtex-7 / UltraScale / UltraScale+ (含 NetFPGA SUME), **不含 Kintex-7 KC705**; 其 10G/25G MAC/PHY 来自同作者的 verilog-ethernet。Corundum 对我们最大的借鉴是分层与队列/状态的组织方式, 而非直接移植。
- 来源: [Corundum GitHub](https://github.com/corundum/corundum) / [FCCM 2020 论坛](https://www.fccm.org/past/2020/forums/topic/corundum-an-open-source-100-gbps-nic/#post-1110) / [DeepWiki (taxi 版资源数字)](https://deepwiki.com/fpganinja/taxi/8.1-corundum-rtl-hardware) / [Corundum 板卡列表](https://github.com/tieovi/corundum)

### 1.2 verilog-ethernet (alexforencich) — 到 UDP 为止, 无 TCP
- 完整模块库: `eth_mac_10g/25g`、10G/25G PCS/PMA、ARP/IPv4/UDP、FCS、PTP, 顶层 `udp_complete` (1G) / `udp_complete_64` (10G/25G) 为 UDP+IPv4+ARP 全栈。**TCP 模块不存在** — TCP 需自建或另选方案。这是本工程 1G 栈的理论对照物。
- 来源: [verilog-ethernet GitHub](https://github.com/alexforencich/verilog-ethernet) / [DeepWiki 概览](https://deepwiki.com/alexforencich/verilog-ethernet/1-overview)

### 1.3 fpga-network-stack / Limago (ETH Zürich + UAM, FPL 2019) — 最接近我们目标的 TOE 开源栈
- Limago (FPL 2019): 100G TOE, 512bit @ 322MHz, 148.8Mpps (64B 包), 支持 Window Scale, 外部 DDR4 缓冲 (支持 512 连接)。**注意: 大部分模块是 Vivado-HLS (C++) 合成**, 纯 HDL 仅 ~6%; 单周期校验和是手写 HDL (HLS 满足不了延迟) — 印证"HLS 不适合延迟敏感数据面"。
- 后继 fpgasystems/fpga-network-stack: 10-100G TCP/IP + UDP + RoCEv2。TOE 结构对我们最有参考价值:
  - **Session Lookup Controller** (4-tuple → session ID, 基于 CuckooCAM 流查找: 单周期查/删, 322MHz 下 >300M 查/秒, stash 使占用 >90%, 64bit 3-tuple key 比 SmartCAM 省 22% BRAM);
  - **State Table** (完整 TCP 状态机) + **SAR 表** (每连接 seq/ack/窗口/乱序跟踪, RX/TX 分离); 内存寻址 2bit 区 + 14bit 会话 + 16bit 偏移, 支持 16K 会话 × 64KB 缓冲;
  - **三个定时器**: 重传 RTO / 零窗口探测 / 关闭定时; **Event Engine** 统一调度 SYN/ACK/重传/FIN/RST 事件;
  - 校验和: RX 首级即校验, TX 单周期 (CSA 7-3 进位保存加法器树) 完成。
- 来源: [Limago GitHub](https://github.com/hpcn-uam/limago) / [FPL 2019 论文 (10.1109/FPL.2019.00053)](https://www.sgpjbg.com/baogao/139677.html) / [fpga-network-stack DeepWiki TOE](https://deepwiki.com/fpgasystems/fpga-network-stack/2-tcp-offload-engine)

### 1.4 其他
- **NetFPGA SUME** (Virtex-7 690T, 4×10G): 学术平台, 有 P4→NetFPGA 工具链 (源自 Xilinx P4-SDNet); 平台本身是 PCIe 网卡, 无现成 TCP 栈, 多用于转发面研究。来源: [NetFPGA 概述论文](https://www.semanticscholar.org/paper/NetFPGA-rapid-prototyping-of-high-bandwidth-devices-Zilberman-Audzevich/1666c63b92a87a54f1b3578a48c87a7fb5041963)
- **FlexTOE** (NSDI 2022, BSD-3): 细粒度并行 TCP 数据面卸载, 针对 Netronome SmartNIC 而非 FPGA; 理念 (数据面卸载、控制面保留主机) 可借鉴。来源: [FlexTOE GitHub](https://github.com/tcp-acceleration-service/FlexTOE) / [NSDI'22](https://www.usenix.org/conference/nsdi22/presentation/shashidhara)
- **hpb TOE** (2017 开源 Verilog TOE, 区块链背景, 已停更) 与 **SiTCP-XG** (BeeBeans 商业 10GbE TCP/IP, 支持 Kintex-7 并有 KC705 例程): 均可作实现对照。来源: [hpb relatedrepos](https://relatedrepos.com/gh/hpb-project/TOE) / [SiTCP-XG](https://mono.ipros.com/en/product/detail/2000615916/)
- 学术 10G TOE (Sensors 2023): 1024 会话, 收 9.5Gbps, 最小 TX 延迟 600ns, "双队列存储"结构, 1024B payload 下延迟比同类硬件实现好 55%、仅为软件栈 3.2% — 证明 10G 量级 TOE 在 K7 类器件上可全硬件达成。来源: [MDPI 检索](https://www.mdpi.com/search?sort=pubdate&page_no=3&page_count=50&year_from=1996&year_to=2024&q=FPGA-based%20applications)

---

## 2. AMD 方案与 IP

### 2.1 7 系列 10G 以太网 IP 路径 (Kintex-7 必须用这条)
- **重要**: PG210 "10G/25G High Speed Ethernet Subsystem" (AXI-Stream 64bit@156.25MHz 10G 配置) 面向 UltraScale/UltraScale+, 其官方资源表 (xcku11p, MAC+PCS BASE-R 无 FEC/AN): **~6.2K LUT / 7.5K FF / 4×BRAM36**, 加 AN/LT → 10.8K LUT, 加 RS-FEC → 15.9K LUT。**该数字仅作量级参考, 不能直接用于 K7**。来源: [PG210](https://www.amd.com/content/dam/xilinx/support/documents/ip_documentation/xxv_ethernet/v4_1/pg210-25g-ethernet.pdf) / [官方资源表](https://download.amd.com/docnav/documents/ip_attachments/xxv-ethernet.html)
- **K7 正路 = PG157 (AXI 10-Gigabit Ethernet Subsystem)**: 内含 10G MAC (XGMII 64bit @ 156.25MHz, AXI4-Stream 客户端接口) + 10-Gigabit Ethernet PCS/PMA (GTXE2, 10GBASE-R/SR/LR 光口与 KR 背板), 支持 Kintex-7。PCS/PMA v2.6 (V7/K7 BASE-R) 实测: **无 MDIO ~2.2K LUT / 2.3K FF, 有 MDIO ~2.7K LUT / 2.7K FF**, 3 BRAM; MAC 部分精确值以 Vivado IP 配置对话框为准 (整体 MAC+PCS 子系统估计 8-15K LUT 量级)。10G 需要 1 个 GTX @ 10.3125Gbps (refclk 156.25MHz), XC7K325T-2 的 GTX 完全支持。来源: [PG157 PDF](http://www.xilinx.com/support/documentation/ip_documentation/axi_10g_ethernet/v1_2/pg157-axi-10g-ethernet.pdf) / [10G PCS/PMA v2.6 手册](https://manualzz.com/doc/11226012/xilinx-v2.6-10-gigabit-ethernet-pcs-pma-product-guide)
- 替代: verilog-ethernet 的 `eth_mac_10g` + `10g_ethernet_pcs_pma` (开源, 无官方数字, 量级与 Intel 同类 1.6-4.5K ALUT 相当), 或自写 10GBASE-R PCS。

### 2.2 Vitis Networking P4 (VNP4, 原 SDNet) — fast/slow path 的官方工程化表达
- **引擎架构**: parser / deparser / match-action / lookup 四类引擎; lookup 引擎 = BCAM (exact, 10-1024bit 键宽)、STCAM (LPM)、TCAM (≤992bit, ≤32K 条目)、RAM 直查表; 编译器按 P4 表类型自动选引擎。
- **三时钟域设计** (这是"线速路径 vs 慢处理"的硬件答案): ① line rate 域 (读/改包, 必须每拍吞吐) ② packet rate 域 (每包一次的操作, 如单次查表) ③ control rate 域 (配置/控制, 低速); 自动生成背压与级间缓冲。
- **性能/资源**: 200Gbps / 300Mpps; 极复杂 parser (130K 条解析路径) 仅 31K LUT; 100G 教程设计里查表占 LUT 77-91% (表是资源大头)。
- 与 Solarflare 关系: 收购后的 Solarflare Onload 是软件用户态栈, 与 VNP4 无直接耦合; 对我们是**设计思想借鉴** (引擎化 + 三域划分 + 表驱动), 工具链本体面向 UltraScale+。来源: [VNP4 产品页](https://www.amd.com/en/products/adaptive-socs-and-fpgas/intellectual-property/ef-di-vitisnetp4.html) / [WP555](https://www.amd.com/content/dam/amd/en/documents/products/vitis/wp555-vitis-networking-p4.pdf) / [UG1308](https://www.xilinx.com/content/dam/xilinx/support/documents/sw_manuals/xilinx2022_2/ug1308-vitis-P4-user-guide.pdf)

### 2.3 AMD SmartNIC 生态
- **Vitis Networking Stack (SmartNIC 参考设计)**: Vivado/Vitis 2023.2+, Alveo U250/U280, PCIe Gen4 x16 + 100G; 可勾选启用 **TOE / RoCEv2 / 虚拟交换机** 模块 — 说明 AMD 有官方 TOE 模块 (仅 UltraScale+ 发布)。来源: [SmartNIC 角色演进 (2026)](https://z.shaonianxue.cn/33568.html)
- **历史**: Xilinx 从未在 7 系列提供过公开 TOE 参考设计, 7 系列 TOE 生态由第三方 IP 商 (Design Gateway 等) 占据。来源: [DG TOE100G 数据手册](https://dgway.com/products/IP/TOE100G-IP/dg_toe100gadvip_data_sheet_xilinx/dg_toe100gadvip_data_sheet_xilinx.htm)

---

## 3. TOE 关键机制 (商业思想 → FPGA 可实现抽象)

### 3.1 fast path / slow path 划分原则
- 商业范例 (Design Gateway TOE100GADV): **TOE 硬件只跑高速 TCP 数据, ICMP/DHCP 等低速协议交给板载 CPU 接口** — 即显式的 fast/slow 分流。来源: [DG TOE100GADV](https://dgway.com/products/IP/TOE100G-IP/dg_toe100gadvip_refdesign_xilinx/dg_toe100gadvip_refdesign_xilinx.pdf)
- 抽象到 FPGA 的划分:
  - **必须线速旁路 (fast path)**: 帧接收 → 解析 → 精确表查 (5-tuple/CAM) → 校验和验证/增量更新 → TCB 状态机 (seq/ack 推进) → 载荷交付; 发送方向: 应用数据 → 分段 (TSO) + 增量校验和 → MAC。这些操作全部是每包 O(1) 且不依赖慢资源。
  - **可慢处理 (slow path)**: TCP 握手/挥手、重传计时 (RTO 毫秒级)、零窗口探测、拥塞窗口维护、ARP/ICMP/DHCP、管理面 — 全部放入慢时钟域, 经 BRAM mailbox/FIFO 与 fast path 解耦; 慢路径满 100-1000 拍再响应一个事件完全无感。
- VNP4 的 line/packet/control 三域是对该原则的完整工程化模板 (见 2.2)。

### 3.2 校验和增量卸载 (incremental checksum)
- TSO 分段、重传、NAT 改写时只有少量头字段变化 (IP ID、seq、长度): 按 RFC 1624 只对变化字段做增量补码更新, 避免整包重算 — 这正是 Solarflare TSO 依赖 "TX checksum offload" 的原因。来源: [sfc tx_tso.c 实现](https://android.googlesource.com/kernel/common/+/d15e4b825dc0b0ad24a54d493be2f17bd8eb7f0b/drivers/net/ethernet/sfc/tx_tso.c)
- 实现参考: Limago 用 **CSA 7-3 进位保存加法器树单周期算校验和** (纯 HDL, HLS 延迟不达标)。来源: [Limago FPL 2019](https://www.sgpjbg.com/baogao/139677.html)

### 3.3 TSO / LRO
- TSO: 硬件按递增 seq/IP ID 拆分大块数据, 生成各段头 (FIN/PSH 仅最后段), Solarflare 实测对延迟无影响, 可常开。来源: [XtremeScale 手册 p.114](https://www.manualslib.com/manual/1487705/Solarflare-Solarflare-Xtremescale-Series.html?page=114)
- LRO: 收端合并小包降 CPU; **有中断合并延迟代价**, 且 MTU>3979B 时 Solarflare 自动禁用 — 低延迟交易场景默认不启用或极小合并窗口。来源: [Ultra SFN7142Q 手册](https://www.manualslib.com/manual/1308187/Solarflare-Ultra-Sfn7142q.html?page=265)
- 对我们: TSO 有用 (TCP 大块行情重传), LRO 不适用 (小包延迟敏感)。

### 3.4 TCB 连接块组织 (有限连接数 4-16 的场景)
- 教训: 每连接一套 FSM 扩展不成立 — 60K 连接 ≈ 30M LUT; 必须**集中式状态表 + 共享控制器** (BRAM 存 TCB, 单 FSM/流水顺序处理, 命中率靠表小/缓存)。来源: [TOE 设计挑战](https://wenku.csdn.net/column/2ojmyonpt7)
- 有限连接做法: 4-16 连接 = 16 × 128-256bit 状态字 ≈ 1/8 个 BRAM36, **每槽可单周期读改写, 甚至无需查找** (固定槽位索引或微型 CAM); 数据缓冲用 BRAM FIFO (当前 wrapper 的 4K 深 rx_fifo 模式可延续)。参考: Corundum 128bit/队列 × 4096 = 2 URAM; fpga-network-stack SAR 表 + 14bit 会话号。
- 流水建议 (CSDN 方法论): 4+ 级流水 — 收帧/分段 → 解析/校验和 → 状态决策 → 数据交付/ACK 生成, AXI-Stream 全程避免整包缓存。来源: 同上

### 3.5 5-tuple 哈希分流
- 有限连接用**微型 CAM 或哈希 + 命中验证**即可 (4-16 项); 大数据量场景的参考实现: Corundum RSS flow hash、fpga-network-stack CuckooCAM (单周期, >90% 占用)、VNP4 BCAM。来源: 见 1.1 / 1.3 / 2.2

### 3.6 重传/超时放慢路径的可行性
- 明确可行: fpga-network-stack 的 RTO/探测/关闭三定时器是独立模块, 由 Event Engine 低频触发 (ms 级), 与线速数据面完全解耦; 对 4-16 连接, 一个慢时钟域的周期扫描计数器 (每 1024 拍扫 16 槽) 即可实现。来源: [fpga-network-stack DeepWiki](https://deepwiki.com/fpgasystems/fpga-network-stack/2-tcp-offload-engine)

---

## 4. 行情/交易低延时实践

- 延迟阶梯: 内核协议栈 5-20μs (中断/DMA/上下文切换) → DPDK/Onload 内核旁路 1-2μs → **FPGA 全硬件 <1μs 且零抖动** (确定性来自数据流架构而非取指执行)。来源: [TechNova FPGA 行情架构](https://technologynova.org/%e7%ba%b3%e7%a7%92%e7%ba%a7%e4%ba%89%e5%a4%ba%ef%bc%9a%e5%9f%ba%e4%ba%8efpga%e7%9a%84%e8%b6%85%e4%bd%8e%e5%bb%b6%e8%bf%9f%e8%a1%8c%e6%83%85%e8%a7%a3%e7%a0%81%e6%9e%b6%e6%9e%84%e8%ae%be%e8%ae%a1)
- 商用量级: nxFeed (Enyx/Exegy): 均值 <1.2μs / 最坏 <8μs (SOP-to-SOP); Silicom fbSmartNIC 2.0: **UDP 口收 → 用户逻辑 → TCP 口发 455ns wire-to-wire**, MAC 固定 67ns; 支持 64 路 UDP 组播流。来源: [nxFeed](https://www.enyx.com/nxFeed/) / [Silicom fbSmartNIC](https://www.silicom.dk/ip_service/smartnic-financial-framework/)
- 典型架构: 10/25/40/100G MAC + UDP 卸载 → 硬件解码 (ITCH/FAST/FIX) → **A/B 冗余 feed 按消息仲裁/去重 + 序列号 gap 检测** → 归一化 → PCIe 直送或 UDP 组播重发; 全部在卡上。Design Gateway AAT: ITCH 解码 + OUCH 下单全硬件 (Alveo), 亚微秒。来源: [AAT](https://dgway.com/AAT/AAT_Main.html)
- 交易 TCP 特征: 订单走 TCP (可靠, 小包 64B 级高频、每包延迟敏感、少量长连接); 关键技巧 — **FPGA 预组装报文, 软件只填最终订单字段, 硬件完成头部并发送 (partial packet assembly)**, 把 TCP 延迟压到仅剩硬件路径。来源: [Pico TCP vs UDP](https://www.pico.net/kb/what-are-the-relative-merits-of-tcp-and-udp-in-high-frequency-trading/)
- 对我们的含义: 行情 UDP 组播路径必须**完全绕过 TCP 逻辑** (校验、分发、A/B 冗余全部线速数据面); TCP 路径优化目标 = 每包固定延迟 (小包), 而非吞吐。

---

## 5. 资源量级参考 (XC7K325T 预算)

| 组件 | 公开量级 | 备注 |
|---|---|---|
| 10G MAC+PCS (K7, PG157 路径) | PCS/PMA ~2.2-2.7K LUT; 子系统估计 8-15K LUT | 精确值看 Vivado; UltraScale+ PG210 无 FEC ~6.2K LUT 作量级参考 |
| verilog-ethernet eth_mac_10g | 无官方数; Intel 同类 1.6-4.5K ALUT | 需自行综合验证 |
| Corundum 全功能 100G NIC (含 PCIe DMA) | ~54-72K LUT / ~10-30 万 FF / 141-178 BRAM | 单 10G 端口 MAC+datapath 只占其中一小部分 (<10K LUT 量级) |
| VNP4 极复杂 parser | 31K LUT | 130K 解析路径的极端案例 |
| 100G 教程 P4 表 | 占设计 LUT 的 77-91% | 表驱动架构的资源大头是查表 |
| TCB 16 连接 × 256bit | <0.2 个 BRAM36 | 微不足道 |
| 校验和 CSA 单周期引擎 | ~1-3K LUT | HLS 达不到延迟, 手写 |
| 队列 4096×128bit (Corundum) | 2 URAM ≈ 等效 ~18 BRAM36 | 我们 4-16 连接用量 << 此数 |

- **结论**: 10G 数据面 (MAC+PCS ~8-15K) + 解析/查找/校验和流水 (~10-20K) + TCB/缓冲 (数十 BRAM) 合计 **~25-45K LUT (<15% 器件), BRAM < 10%**, 16 个 GTX 只耗 1-2 个。资源完全不是约束; 约束在架构 (多级流水 + fast/slow path) 与 156.25MHz 时序收敛。

---

## 6. 对本项目的可借鉴点汇总

1. **架构范式必须切换**: 当前 HLS 单 FSM (~1B/20cyc) 与 10G 的 8B/cyc @156.25MHz 相差 160 倍; 所有开源 10G+ 方案 (Corundum/verilog-ethernet/Limago) 均为多级流水, Limago 连校验和都要手写 HDL (HLS 延迟不达标)。数据面建议纯 RTL, HLS 只保留 slow path 控制逻辑。
2. **fast/slow path 是核心结构**: 线速路径 = 收帧→解析→查表→校验→TCB→交付 (及反向 TSO+增量校验和); slow path = 握手/重传/RTO/ARP/ICMP/DHCP/管理, 全部慢时钟域经 BRAM mailbox 交互 (Design Gateway CPU 接口、VNP4 control 域同思路)。RTO ms 级, 慢扫 16 槽完全可行。
3. **K7 的 10G 物理层用 PG157 (axi_10g_ethernet) 或 verilog-ethernet 10G MAC/PCS**, 不要照抄 UltraScale+ 的 PG210 路径; XGMII/AXI-Stream 64bit @156.25MHz 即 10G 线速, 与现有 RGMII wrapper 架构同构。
4. **TCB 直接映射 BRAM**: 4-16 连接每槽 128-256bit 状态字单周期读改写, 固定槽位索引免查表; 数据缓冲沿用 BRAM FIFO 模式 — 资源开销可忽略。
5. **行情路径零 TCP 干扰**: UDP 组播 RX 旁路一切 TCP 逻辑, A/B 冗余按序仲裁 + 序列号 gap 检测放数据面; 交易 TCP 小包目标 = 固定延迟 (预组装 + partial packet), 不用 LRO, TSO 仅重传场景需要。
6. **校验和用增量 + CSA 树**: 收端验证与发端生成都单周期完成, 避免整包缓存, 直接解决当前"排空 1 字节/20 周期"的瓶颈模式。
7. **可参考的现成件**: fpga-network-stack 的 TOE 结构 (Session Lookup/State Table/SAR/Event Engine) 是最贴近我们规模的蓝图; 商业对标 Silicom 455ns UDP→TCP 转发证明目标 (亚微秒) 在硬件上可达。

# udp_hls → Kintex7 ECO 板移植笔记 (PORT_NOTES)

> 2026-08-16, 由 Claude 从 D:\repo\perfv 移植。原工程未动。总纲见同目录 MIGRATION_K7325T.md。
> 本文记录本次移植的所有决策、踩坑、验证结果 — 按用户要求, 经验落盘。

## 物理层结论 (gmii_probe 板级实测, 2026-08-16)

- probe 在 R3 原理图 PHY1 引脚组: rxc=0 (W1 完全无沿) → 物理板不遵循 R3 原理图的 PHY1 分配
- probe 在 k719/k720 demo PHY1 引脚组 (AB2 等): rxc=2.5M = PHY 空闲钟 → **demo 引脚组才是物理真相**
- probe 在 demo PHY2 引脚组 (AA23 等): rxc=2.5M 同样 (PHY2 也活着, 无链接)
- **网线没插进板子**: ping 192.168.100.2 时 probe 零帧 (rxdv_hi=0); PC 网卡 1G 链路连的是别处
  (可能路由器)。等用户回来把网线插进板子 RJ45 (PHY1 口), 主设计已按 demo 引脚组重定向。
- 主设计不用 MDIO (wrapper mdc=0/mdio=z), PHY 靠 strap 配置 — 与 demo 同策略

## 网络调试状态 (2026-08-17 凌晨 v5 — 纠偏 + 攻坚中)

- ⚠ **纠偏**: 之前判定的"垃圾帧" (EtherType 0x889E/0x88C7) 其实是 **Microsoft SSDP/WSD 的
  合法 EtherType** — PC 自己的协议! "TX 相位错位导致坏帧"推断不成立, 撤销。
- 真实状态: 环回双向全通; 正常模式 PC→FPGA 在特定相位偶尔通 (mini 曾见 frm=1@+3.34ns);
  **FPGA→PC 方向从未送达任何帧** (pktmon 多次, FPGA MAC 零出现)
- 主设计 (HLS IP) 任何相位都不回 ping; HLS IP 自身的周期广播 (25s/帧) 也从未到 PC
- 🔄 攻坚 agent 进行中: MDI 方向性 (far-end loopback)、TXDLY strap、TXCTL 空闲电平、
  mini 相位扫描 + pktmon 找 TX 窗口 — 日志见下文"攻坚日志"

## 攻坚日志 (2026-08-17, RGMII 100M 单向不通 — 根因已定位)

> **最终结论速览** (详见下方各节): ① RX 方向根因 = RGMII 100M nibble/周期
> 格式 + 错误拼装 — **已修复并板级验证** (PC 帧逐字节正确); ② TX 方向:
> 格式/时钟源/相位/环回全部修复并验证 (环回数据逐字节正确), 但 **线侧
> 数据 TX = PHY 硬件故障** (100M 与 1G 全部配置、全相位下 PC 零帧, 1G
> 链路都能协商 UP 说明 idle 通路正常 — 只有数据帧到不了线上)。

### ★★★ 根因: RTL8211E 的 100M RGMII = "每时钟周期 1 个 nibble", 不是 1G 式 DDR 字节流

**板级铁证** (mini_proj_C 实测, 2026-08-17):
- PC 发 1 帧 64 字节最小帧 (ARP 42B, 补零到 60B+FCS4B, 线上 8+64=72B),
  探针看到 **rxdv_hi=144** = 72 线上字节 × 2。
- 若 PHY 按字节/周期 (1G 式 DDR) 转发, 应看到 rxdv_hi=72; 144 = 每字节 2 周期
  → **PHY 在 100M 下每 RXC 周期只驱动 1 个 nibble** (RXD/RXCTL 均如此)。
- 数据率论证: 100M 线速 = 25M 码组/s (4B5B), RGMII 若 2 nibble/周期 (200Mbps)
  PCS 物理上无法消费 → 100M RGMII 必然 1 nibble/周期 (下降沿 = 复制或 don't-care,
  RGMII spec v2.0 明确)。TXC 由 MAC 提供 (RTL8211E Table 3: TXC 是输入, 所有速率)。

**两个方向的既有实现全错 (全是 1G 式字节/周期 DDR)**:
- **TX (FPGA→PC) 不通的真相**: PHY 100M 只采样上升沿 nibble, 而我们每周期送
  2 个不同 nibble (D1=lo, D2=hi) → PHY 只吃到低 nibble → 无有效 SFD/数据 →
  线上无帧 (或坏帧被 PC 丢弃) → pktmon 零帧、FPGA MAC 零出现。
- **RX (PC→FPGA) "特定相位偶通" 的真相**: PHY 送 1 nibble/周期, FPGA 用 IDDR
  {Q2,Q1} 拼出 {n,n} nibble 复制字节 → 数据全错, MAC 丢帧。@3.34ns 的 frm=1
  只是 RXCTL 控制级计数 (RXDV 复制正确), 数据内容从未验证过。
- **环回"双向全通"的真相**: TXEN/RXCTL 双沿复制正确 → 控制级计数通过
  (frm=1, rxdv_hi=63/144), 数据内容 (nibble 复制) 从未检查。引脚/通路判定仍有效,
  "数据通路正确"的结论需撤销。
- v4 "0x889E 垃圾帧" 已被 v5 撤销 (SSDP/WSD 是 PC 自己的流量) — 与 TX 无关。
- **相位不是主因**: 100M 下 nibble 全周期稳定, 采样点任意相位都行;
  相位扫描看到的"窗口"是控制级计数的假象。

**修复方案** (mini v2 = top_mini_v2.v 验证中, 见 gmii_probe_eco/):
- TX: 每周期 1 nibble, D1=D2=同一 nibble, 每字节 2 周期 (先低后高)。
- RX: 只用上升沿采样, 2 周期 nibble 累加成字节; RXCTL 用 rxctl_q1。
- 主设计数据率: MAC @25MHz 产字节 = 200Mbps > 100M 线速 → TX 需限流
  (net_tx_ready 每 2 周期给 1 周期), RX 天然慢于 MAC 无需背压。
- 相位调器保留 (调试用), 但不再是必须。

**验证计划**:
1. mini v2 (格式 A/B 交替发帧 + RX 三种拼字节方式计数) 板级 + pktmon
   → 确认 TX 格式 B 帧到 PC、RX 2 周期累加能匹配 PC MAC
2. wrapper v2 (100M 正确桥 + TREADY 限流) → ping → UDP 8080 → TCP 7

### ★★★ 最终结论: PHY 的线侧数据 TX 通路硬件故障 (2026-08-17 上午)

**决定性实验链 (全部板级实测):**
- 100M 强制 (0x2100): 环回数据逐字节正确 (C 模式 + 相位 10-12 @+),
  RX 数据逐字节正确, PC 链路 UP — 但线 TX 在所有相位/格式/FCS 下零帧。
- **1G AN (0x1140): 链路成功协商到 1 Gbps (PC 显示 1G!)** — 125MHz 下
  相位全扫描 + 持续发帧 — 线 TX 依旧零帧。
- PC 网卡强制 100M-FD: 依旧零帧。NIC 性能计数器: 接收错误/丢弃全 0 →
  线上根本没有帧到达 (连坏帧都没有)。
- **结论: RTL8211E 的 RGMII-TX-输入 → 线侧数据通路 (PCS-TX/内部FIFO/
  MLT3 数据) 硬件故障**。环回 (PHY 内) 数据正确 + 链路 idle 正常 (100M
  和 1G 都 UP) + RX 方向完全正常 — 全部指向 "数据帧永远到不了线上"。
- 板级证据链完整: 引脚/时钟/格式/相位/环回/RX 全部排查并验证过。

**修复交付:**
1. **RX 方向修复 (已板级验证)**: wrapper_v2.v 的 100M 正确桥 — 自对齐
   nibble 累加器 (SFD 5,D 重对齐) + RXCTL 上升沿采样。mini 的等价逻辑
   已逐字节验证 PC 帧内容正确。
2. **TX 方向修复 (已板级验证到环回)**: nibble/周期格式 + TXD 挂 MMCM 输出
   (PHY 用内部时钟采样, 不用 TXC!) + 相位 @+10-12。环回数据逐字节正确。
3. **未解决**: 线侧数据 TX = PHY 硬件故障 — 建议换 PHY 或换板验证。
4. 附带修复的工具 bug: mini 匹配器比较顺序反、报告缓冲 128→160 溢出、
   FCS 未随 DA 重算。
5. wrapper_v2 的 uart_console 响应不触发 (回声正常, ?mac+CR 无响应) —
   v1/v2 两个 wrapper 都有, 为独立问题 (与控制台 IP 的 HLS 响应路径有关)。
6. **wrapper_v2 最终版 (08:01)**: TX 桥已改为 gmii_clk 域 (TXD/TXCTL 挂
   MMCM 输出, 移除 raw-RXC BUFG 与 AXIS 跨时钟同步) — 对应 mini 验证过的
   "TXD 必须能随相位移动" 结论。位流 = vivado_prj/udp_dual_v2.runs/impl_1/
   wrapper_v2.bit (已烧录, 链路 UP 100M)。启动后需 @+ 10-12 步校准 TX
   采样点 (与 mini 相同, 每次上电重复)。

## ETH1 (PHY1, AB2 组) 测试方案准备 (2026-08-17)

### PHY1 空闲状态验证 (AB2 探针, 板级实测)
- AB2 探针 (probe_proj, AB2 组 + MDIO AA25/Y25): **rxc=2.5M, rxdv_hi=0** —
  PHY1 活着, 空闲钟 2.5M, 无链接 ✓ (用户插线前无帧, 与预期一致)。
- **MDIO 总线判定 (关键!)**: AA25/Y25 扫描 = p00 和 p01 都答且**值完全相同**
  (r0=6c02 r1=794d r2=016e r3=ffff = 100M-FD 已解析 + 链接 OK — 这是 AA23
  PHY2 的状态!)。AB2 PHY1 空闲无链接, 其 PHYSR 不可能 = 0x6c02 →
  **p01 不是独立设备, 是同一个 PHY2 对两个地址都应答**。
- **W4/W1 总线 (demo 配方 MDIO)**: AB2 探针改 W4/W1 (LVCMOS18) 扫描 =
  **mdio: no-dev** — PHY1 的 MDIO 不在 W4/W1。
- **结论: AB2 PHY1 的 MDIO 不可达 (两个候选总线都无独立设备); PHY1 纯 strap
  配置 (与 demo 同策略)**。向 PHYAD 1 写 0x2100 (AA25/Y25) 实际影响的是 PHY2
  (同一设备), 对 PHY1 无效 — 计划中的 "强制 100M" 不适用; PHY1 链路速度由
  AN 决定 (用户插线后看 RXC 频率: 125M/25M/2.5M)。
- ⚠ 用户插 ETH1 线后的观察项: (a) AB2 探针 RXC 频率 → 协商速率; (b)
  mini_ab2 位流 (MDW_PHYAD=1, 但 MMCM 只在 25MHz 时锁定 — 100M 链接才可用);
  (c) wrapper_v2_phy1 位流 (AB2 组 + LVCMOS18 + MDIO AA25/Y25) — 同样只有
  100M 链接时 MMCM 才锁。

### PHY1 位流交付 (已构建)
- `udp_hls_eco/vivado_prj/udp_dual_v2_phy1/.../wrapper_v2.bit` — wrapper_v2_phy1.v
  (MDW_PHYAD=1) + xdc/eco_rgmii_phy1.xdc (AB2 组, bank 34 LVCMOS18, MDIO
  AA25/Y25 LVCMOS33, 40ns)。
- `gmii_probe_eco/mini_proj_ab2/.../top_mini_v2.bit` — top_mini_ab2.v
  (MDW_PHYAD=1) + mini_ab2.xdc (AB2 组 + LVCMOS18 + MDIO AA25/Y25)。
- `gmii_probe_eco/probe_proj_ab2w1/.../top_rgmii.bit` — W4/W1 MDIO 判别探针
  (已用, 结论 no-dev)。
- 构建工具: run_vivado_v2_phy1.tcl/bat, build_mini_ab2.tcl/bat,
  build_probe_ab2_w1.tcl/bat。
- 参数化: top_mini_v2.v / wrapper_v2.v 增加 MDW_PHYAD; top_mini_v2.v 的
  M_PDIV/M_ODIV 扩到 7 位 (4 位会把 24 截断成 8 — mini_ab2 首次构建的
  PDRC-34 VCO 200MHz 坑, 已修)。

**遗留物 (gmii_probe_eco/ 下):**
- top_mini_v2.v: 100M 诊断探针 (A/B 格式 + C/P/L 命令 + 64-nibble dump +
  MDIO 写/环回切换) — mini_D2.xdc (AA23+MDIO), mini_proj_D2 位流可用。
- top_mini_1g.v: 1G 变体 (AN 0x1140, 125MHz MMCM) — mini_proj_1g 位流可用。
- probe_aa23: PHYSR/BMSR/PHYCR/RXERC 读探针 (top.v 的 md_regad 已改为
  r0=0x11, r1=0x01, r2=0x10, r3=0x18)。
- tools/: crc32.ps1 (帧 FCS 计算), pktmon_capture.ps1 (抓包+汇总)。

### ★★★ TX 方向三大发现 (2026-08-17 上午) — 环回数据判定实验

1. **PHY 用内部时钟采样 TXD, 不用我们的 TXC**: 环回损坏模式对 TXC 相位扫描
   完全不敏感 (TXD 固定在原始 RXC 时) — 扫描 47ns 无变化。
2. **TXD 必须挂在 MMCM 输出上 ('C' 模式)**: TXD 与 TXC 同源 (gmii_clk) 时,
   相位扫描移动 TXD 相对 PHY 内部采样点 — @+ 10-12 步时环回数据**完全干净**:
   [55×7, D5, 00×6, 00:0A:35:01:FE:C0, 08:00...] = mini 帧逐字节正确!
   原始 wrapper 的 "TXD 固定 raw RXC" 结构 = 采样点固定落在 nibble 跳变上 = 必死。
3. **FCS bug (v7 引入)**: DA 从 FF×6 改成 00×6 时 FCS 没重算 (仍 4D 1A 07 2B)
   → PC 每帧都丢 (FCS 错误)。正确 FCS (DA=00×6) = **0B C8 1A 3C**。
   这可能就是 "PC 收不到任何帧" 的最后一块拼图 (环回 = PHY 内不回 FCS 校验,
   所以环回看不出来; PC 的 NIC 会丢坏 FCS 帧, pktmon 也看不到)。
- ✅ 环回数据正确性 = PHY 的 RGMII-TX 输入采样正确 — 已用 mini 帧逐字节验证。
- 🔄 v11 构建中: 正确 FCS → 环回关 → pktmon 验证线 TX 是否到达 PC。

### ★★★ RX 方向完全验证通过 (2026-08-17 上午)

- **匹配器修复后 rx1>0**: PC 帧到达时 rx1 计数 (LLMNR/DHCPv6/SSDP 帧,
  SA=FC:9D:05:7D:88:6B) — **RX 方向 (PC→FPGA) 数据链路全通**:
  前导/DA/SA/ET 全部正确, nibble/周期 + {当前,前驱} 字节拼装正确。
- **修复的两个 RTL bug**: (a) 匹配器移位寄存器比较顺序反了 (sr[0]=最新却与
  MAC 首字节比) — 仿真复现+修复; (b) 报告消息 131 字节 > msg[128] 缓冲 —
  计数器值大时 (如环回 3667896) ai 回绕, 消息只剩 CRLF — 已扩到 160 字节。
- 环回模式 (0x6100) 会使 PC 链路断开 (PCS 环回切断线侧) — 属正常。
- 待 v10: 环回帧内容 (mini 自己帧, DA=00:00:00:00:00:00) 判定 PHY 的
  RGMII TX 输入采样是否干净。

### ★★ RX 方向数据实为真实数据 + 匹配器 bug (2026-08-17 上午)

- **RX (PC→FPGA) 数据 = 真实帧**: mini v7 的 64-nibble dump 显示 LLMNR 帧完整内容
  [55×7, D5, FF×6, FC:9D:05:7D:88:6B, 08:00, IP头...] — 前导/DA/SA/ET 全对!
  此前 v3-v6 看到的 [f,0,f,0...] 坏模式 = 环回帧 (mini 自己帧经 PHY 回送被破坏),
  不是 PC 帧。PC 帧经 PHY 的 100M PCS 解码 → RGMII = 数据正确。
- **匹配器 bug (定位+修复)**: rx1/rx2/rf 恒 0 的根因 = 移位寄存器比较顺序反了
  (sr[0] 是最新字节, 却与 MAC 首字节 P0 比较)。仿真复现 → 8 处比较全部反转。
- 另一个 bug: tx_adv ('P' 模式) 被两个 always 块驱动 (multi-drive, 综合保留
  GND) → 'P' 模式从未生效。已修复 (解码器单驱动)。
- 环回 (PCS loopback) 返回的 mini 自己帧 = 数据损坏 ([f,0,f,0...] 模式) —
  环回路径经 PHY 的 RGMII TX 输入采样 → 损坏 → **PHY 的 RGMII TX 输入侧
  采样/处理是坏的** → 与 TX 方向 (FPGA→PC) 完全不通一致。
- 待 v9 验证: 修复后的匹配器 + 每窗口重新武装的 dump → 环回数据内容判定。

### ★★★ 重大发现: PHY 的 100M 数据通路输出固定坏模式 (2026-08-17 上午)

mini_v3 (D2 位流, MDIO 启动写 0x2100 + 'L' 环回 + 帧内容 dump db=):
- **PCS 环回 (0x6100) 板级确认**: 环回返回 ~34k 帧/窗口 = mini 发送速率,
  rxdv_hi=3,667,896/33,962帧 = 108 周期/帧 = (格式A 72 + 格式B 144)/2
  → **PHY 的 RGMII RX (我们的 TX 输入) 按输入格式原样回送** (帧长/定时正确)。
- **帧内容 dump (首帧前 32 nibble)**: `55555555555555d f0f0f0f0 55555555`
  = [55×7, D5, 0F×4, 55×4] — 前导+SFD 完全正确, 之后 = 固定坏模式。
- **PC 帧 (LLMNR, DA=FF×6) 与 mini 自己的帧 (DA=FF×6) 返回/送达的内容
  完全一样** → 坏模式与输入无关 (至少 DA 区) → **PHY 的 100M 数据通路在
  前导之后输出固定模式** — 两个方向都坏 (RX 方向 + 环回)。
- 相位扫描 (28×@+, ~47ns) 不改变该模式 → 不是我们的采样相位问题
  (100M nibble 全周期稳定, 采样点无影响 — 坏在 PHY 内部)。
- 结论: **不是 FPGA 的 RGMII 格式问题, 是 RTL8211E 的 100M PCS 数据通路**
  把有效输入 (PC 的合法帧 / 我们的合法 TX 帧) 变成 [0F×4, 55×4...]。
  控制通路 (RXDV/TXEN/帧长) 正常。链路 UP (PC 100M), MDI idle 正常。
- 🔄 进行中: probe_aa23 位流 (AA23+MDIO, 读 PHYSR 0x11/BMSR/PHYCR/RXERC)
  判定 PHY 认为自己处于什么状态 (速率/双工/AN)。
- 已排除: RGMII 100M 格式 (spec 确认 nibble/周期, 我们的格式 B 正确),
  TXC 相位, TXD/TXC 时钟关系, 网线 (RX 方向完整帧), 采样相位。

### mini_v2 实测进展 (2026-08-17 上午)

- ✅ **RX 格式二次确认**: PC 发 64B 帧 (ARP 42B 补零), rxdv_hi=144 = 72 线上字节 × 2;
  LLMNR 282B 帧 → rxdv_hi=588 = 294 线上字节 × 2 (282+4FCS+8前导)。nibble/周期 无歧义。
- ✅ mini_v2 报告通道工作 (6 字段: clk/rxdv_hi/frm/rx1/rx2/rxa)
- ❌ **FPGA→PC 全相位扫描仍零帧**: mini_v2 连续发帧 (格式A/B交替, 65k帧/s,
  带合法 CRC), 28 次 @+ (≈47ns, 超过 1 整周期) 期间 pktmon 全程零 Rx。
  → 相位 (TXC 相对 TXD) 不是 TX 不通的原因。格式 B (nibble/周期) 也修复不了 TX。
  → TX 问题指向: PHY 的 RGMII TX 采样 (可能用内部 RXC 锁相时钟而非外部 TXC),
    或 PHY TX 数据通路/配置。
- 🔧 mini_v2 发现 RTL bug: RX 匹配计数器被两个 always 块驱动 (multi-driven,
  综合保留 GND 驱动) → rx1/rx2/rxa 恒 0, 已修复 (窗口复位移入匹配块)。
- 🔄 mini_v3 (build_mini_D2) 构建中, 新增:
  - MDIO (AA25/Y25) 启动写 BMCR=0x2100 (强制 100M-FD, 稳定链路)
  - UART 'L' 命令: 翻转 BMCR bit14 (PCS 环回) → 环回数据正确性 = RGMII TX
    采样正确性的判决实验 (环回 rx1>0 ⇒ PHY 正确收到我们的 TXD)
  - UART 'C' 命令: TXD 时钟在 原始RXC / MMCM输出(gmii_clk) 之间切换 →
    覆盖 "PHY 用内部时钟采样 TXD" 的假设 (TXD 需要相对 RXC 移动)

## 网络调试状态 (2026-08-17 凌晨 v4 — 垃圾帧破案)

- ✅ 环回全通 (TX+PHY+RX, rxdv_hi=63/frm=1) — 引脚组/FPGA 数据通路/PHY 通路全对
- ✅ **pktmon 抓到 PC 收到 25 个垃圾帧 (EtherType 0x889E = 0x0800 错位)** — PHY 采样 TXD 相位错
  → 线上全是坏帧; RX 采样同理错。一个相位设置修两向
- ✅ 相位调节器就位 (MMCME2_ADV @+/- 1.67ns/次, UART 命令, wrapper + mini 双份)
- 🔄 **校准进行中**: mini_proj_C (帧发生器+相位调器) 构建中 → UART 观察 rxdv_hi 出现的相位
- 校准后: 主设计烧录 + 同相位 @+ 序列 → ping → UDP 8080 → TCP 7

## 网络调试状态 (2026-08-17 凌晨更新 v3 — 环回判决后)

- ✅ **MAC 环回测试通过** (rdv_hi=63/frm=1/窗口): TX 引脚 + PHY 数据通路 + RX 引脚全对
- ✅ 相位可调 wrapper 就绪 (RXC→MMCME2_ADV VCO600÷24=25MHz 闭环, @+/- 56步≈1.67ns)
- ❌ 相位扫描: 基线 1/8, +6.7/-13.3/-26.7/-20ns 全部 0/10 — 相位不是主因
- 🔍 **新主嫌疑: 网线帧级损坏** — 环回不经网线全通, 正常模式全死, 1/8 是漏网帧;
  PHY 的 DSP 在坏线上锁不住 100M 数据 → 帧静默丢弃 → RXDV 从不置位
- 🔄 进行中: 强制 10M (0x0100) 判决 — 10M 只要求 2 对线, 若 10M 下帧通 → 网线在 100M 下不行

## 网络调试状态 (2026-08-17 凌晨更新 v2)

- ✅ AA23 组 = 接线 PHY 的引脚组 (mini 探针两次实测 125MHz: 446 行/60s 和 297 行/40s)
- ✅ MMCM 反馈环修复 (CLKFBIN) — agent 静态分析 + 对比 demo/probe 闭环实例确认
- ✅ MDIO 写事务可用 (板级验证: BMCR 写入生效, 寄存器变化确认)
- 🔍 **autoneg 死循环**: PHYSR bit11 (速率解决) 从未置位; RXC 在 125MHz↔2.5MHz 间摆动
  (1G↔10M 反复协商, 链路从不定稳) — 解释了一切"时好时坏"
- 🔄 强制 1G (0x0140) 板级验证失败 (链路 DOWN — PC 是 AN 模式, 1G 必须双方协商);
  **进行中: 强制 100M-FD (0x2100) — PC 并行检测自动落 100M, 应能稳定**
- ⚠ LED 映射混乱 (D1 可能物理坏; 用户可读的是 D0/D2/D3) — 已放弃 LED 诊断, 改用
  mini 探针 UART 作为唯一可靠观测通道
- 用户问题 (时钟传递逻辑): mini 的时钟路径 = 纯 BUFG, 无组合逻辑 — 时钟消失 = PHY
  链路抖动, 非 FPGA 逻辑问题 (125M 出现/消失与链路状态一一对应)

## 网络调试状态 (2026-08-17 凌晨更新)

- ✅ AA23 组 = 接线 PHY 的引脚组: mini 探针实测 AA23 上有 125MHz (446 行/60s) — 1G RXC 确认
- ✅ MMCM 反馈环修复 (CLKFBIN), D2 锁定位流验证过
- ❌ 主设计 (AA23 组 + demo 全配方 + 已锁 MMCM) ping 仍 0/15
- 🔍 新根因线索: PHYSR **bit11=0 = 速率/双工从未协商完成** (bit12=1 页已交换) —
  链路在 autoneg 死循环, RXC 时有时无 (先 125MHz 后消失 — 链路反复重启)
- 🔄 agent 进行中: probe 加 MDIO 写事务 (BMCR=0x0140 强制 1000M 全双工关 autoneg) 打破死循环
- ⚠ 板子 LED 映射: 我的 led_d0..3 = A23/A24/D23/C24 = 板子 D0/D1 双色; D2/D3 位 (C26/D24/D25/E25)
  未被驱动 (悬空随机) — 用户读 LED 要看 D0/D1
- mini 探针 selftest (BUFG 接 G22) 板级验证通过 — 探针硬件通路 OK

## 网络调试状态 (2026-08-16 深夜更新)

- ✅ UART console 板级 PASS; MDIO 可用 (AA25/Y25, PHYAD0 答, ID 001C/C915, 链路 UP)
- ✅ PC↔板 ETH2 物理链路证实 (拔线断网实验), PC 网卡 1G
- ⚠ 用户关键发现: **ping 192.168.0.2 (demo IP) 走 WLAN** (ARP 缓存显示 0a-91-3a-43-8c-72 = WLAN 设备) —
  demo 的"8/8 ping 成功"是假象, demo 引脚组从未被真正验证!
- ❌ 主设计 ping 192.168.100.2 (走有线, 路由正确): 三个引脚组候选 (AB2 组/AA23 组/W1 组) 全 0/x
- ❌ 诊断版 LED: D2 灭 = 200MHz MMCM (IDELAYCTRL refclk) **未锁定**; D3 无变化 = gmii_clk 疑似死
  (或 2.5MHz 慢闪未观察到)
- 🔄 agent team 进行中: (a) MMCM 不锁排查 (对比 vendor clk_ref.xci + probe 的可锁定 MMCM);
  (b) 最小单 BUFG RGMII RX 探针 (无 CDC/无双 BUFG, 三组引脚 XDC 变体)
- 待办: agent 结果 → 修复 → ping; 链路速度仍未 100% 确认 (PHYSR bits15:14=10=1000M 但 resolved 位=0)

## 进度时间线

- [x] 复制工程: udp_hls → udp_hls_eco (35MB, 排除 .cache/.runs/.Xil), gmii_probe → gmii_probe_eco
- [x] 硬件规格: FPGA=XC7K325T-2FFG676C (FFG676!); PHY1=RTL8211E RGMII 4bit, bank34 @1.8V
- [x] set_part 全部改 xc7k325tffg676-2 (4 个 HLS 脚本 + vivado tcl)
- [x] UART IP HLS 综合通过 (Latency 0, RTL 确认新器件号) — 27s
- [x] 修 TB bug: ICMP dst_mac 检查偏移少 8 字节 preamble (见下)
- [ ] 网络 IP HLS 全流程 (csim+csynth+export) — 后台跑中
- [ ] Vivado 综合实现 → bitstream
- [ ] 烧录 + ?mac UART 验证
- [ ] gmii_probe 物理层验证
- [ ] ping / UDP / TCP 迭代

## 硬件结论 (最终版 — strap agent 三重交叉验证: pymupdf 导线追踪 + junction 检测 + demo XDC)

- **PHY = RTL8211E-VL**: 只支持 RGMII, 1.8V 电平。**TXDLY=1, RXDLY=1** (排阻焊死) →
  PHY 内部对 TXC/RXC 加 2ns 延迟, FPGA 侧纯上升沿 IDDR/ODDR 即可, 无需 IDELAY/ODELAY
- **PHYAD = 0x1** (PHY_AD[2:0]=001), MDIO 1K 上拉到 1.8V, AN[1:0]=11 全广告
- bank34=1.8V (LVCMOS18), bank14/15=3.3V
- **CLK_50M = G22 (MRCC) 确认**; UART = B17(RX)/A17(TX) 确认; reset = D26 = KEY1 按键 (按下低)
- LED1-8 = A23/A24/D23/C24/C26/D24/D25/E25, 高电平点亮 (4.7K 串阻)
- 之前正文中 "B19/C17, C26/G25" 是 pdftotext 行错位误读 — 以上表为准; XDC 已按正确值写好
- PHY1 引脚表 (已核对, 与 xdc/eco_rgmii.xdc 一致): 见 XDC 文件

### 关键决策: 原理图 vs demo 引脚冲突 (已解决)

- 早期 pdftotext 行错位误判原理图 UART=B19/C17、CLK=C26/G25 → 与 demo (B17/A17/G22) 冲突
- 经坐标级导线追踪: 原理图实际就是 **B17/A17 + G22 + D26** — 与 demo 完全一致, 无冲突
- 物理板 = 原理图 = demo, 三方一致。C26=LED5, G25=KEY2 (当初的误读)

## 踩坑记录 (2026-08-16)

### 1. Git Bash 调 cmd 的 .bat 三连坑 (耗时 ~40min)
- **Edit 工具写 .bat 会变成 LF-only** → cmd 报 `'xxx.bat' 不是内部或外部命令`
  (内容存在、cwd 正确、if exist 都过, 就是跑不了)。修复: `sed -i 's/$/\r/'`
- **cmd 在 && 复合命令里对 .bat 预解析早于 cd 生效** → `cmd //c "cd /d X && run_hls.bat"`
  永远找不到。`dir` 能找到但执行找不到。
- **正解**: launcher .bat 内多行 `cd /d` + `call 全路径\目标.bat`, 从 Git Bash 用
  单引号全路径调用: `cmd //c 'D:\path\launcher.bat'`
- 已沉淀到全局记忆 windows-bat-execution-gotchas

### 2. TB 检查偏移 bug (ICMP dst_mac)
- 现象: csim 报 `FAIL: reply dst_mac == sender MAC`, 捕获帧 cap[0..5]=55:55:55:55:55:55
- 根因: capture() 包含 8 字节前导码, dst_mac 在 cap[8..13] 而非 cap[0..5]
  (同 TB 里 EtherType 检查用 cap[20]=12+8 已暗示)。ICMP 的 arp_lookup 修复本身是对的
- 修复: 偏移改 cap[8..13]

### 3. 后台任务假完成
- run_in_background 的 exit code 被管道 tail 吞掉, .bat 找不到也报 exit 0
- 正解: 命令内重定向到日志文件, 完成通知后先查日志再信

### 4. UART TX 9.5 位元间距 bug (本移植最大坑, 2026-08-16 板级定位)
- **现象**: uart_console 回显干净、响应 (192-bit 移位寄存器突发) 全乱码; gmii_probe 报告
  同样乱码 (首字节 'p' 干净后面全乱)。csim TB 全过 → C++ 模型对、RTL 错 — 但其实是
  **时序问题而非数据问题**。
- **根因**: 原 TX FSM "停止位在 mid-cell 驱动后立即结束" → 背靠背字节的起始沿间距只有
  **9.5 位元** (标准 10)。接收方在 9.5T 采样停止位时恰好撞上下一个字节的起始沿 → framing
  error 级联。旧板 (Perf-V) 的适配器宽容所以板级验证通过; ECO 板的 CH340 不宽容。
  回显因 RX 握手抖动带来的微小间隙幸存, 响应流是无间隙突发所以必死。
- **修复**: 字节在停止位元的**结束** (tcnt wrap) 才结束 → 完整 10 位元间距。
  uart_console.cpp (HLS) + gmii_probe/top.v (Verilog) 都改了。
- **教训**: 全局 CLAUDE.md 里 "TX 停止位驱动后立即结束, 支持零间隔突发" 的经验是旧板
  适配器特定的 — 严格按 UART 标准做 (10 位元间距) 才可移植。
- 排查过程 (价值): 多波特率抓取对比 (9600/19200/4800 响应长度比) → CR/CRLF 对照 (排除
  \n 注入) → 位滑移/移位量暴力匹配 (排除数据路径) → 精确周期仿真模型复现 → 定位时序。
  教训: 乱码先查"是不是标准时序", 再查数据。

## 构建命令 (ECO 板)

```bash
# UART IP HLS
cmd //c 'D:\repo\ECO\udp_hls_eco\uart_hls\run_uart_hls.bat'
# 网络 IP HLS
cmd //c 'D:\repo\ECO\udp_hls_eco\run_net_hls.bat'
# csim-only 快速迭代
cmd //c 'D:\repo\ECO\udp_hls_eco\run_csim.bat'
# Vivado 集成
cmd //c 'D:\repo\ECO\udp_hls_eco\run_vivado_wrapper.bat'   # TODO 还没写
```

## 验证顺序 (按用户指令: 编译 → UART → UART 迭代 IP 栈 → 交付)

1. HLS 两 IP 综合 + Vivado bitstream 生成 ✅
2. 烧录 + COM8 发 `?mac` ✅ **2026-08-16 04:20 通过**:
   `?mac`→`MAC: 00:0A:35:01:FE:C0`, `?ip`→`IP: 192.168.100.2`, `?help`/`?` 全对,
   NO_EXTRA_BYTES (9.5 位元修复后)
3. gmii_probe 验证 PHY (rxc=125M + MDIO p01 0x001C/C915) — 重建中 (同款 TX 修复)
4. ping 通 → UDP 8080 → TCP 7 逐项迭代
   PC 侧已确认: Killer E5000B 有线网卡 = 192.168.100.1, 链路 Up, WLAN 192.168.0.43 无冲突
   注意: 本 shell 无管理员权限 — 改 IP/pktmon 需要用户手动

## 2026-08-17 晚 — PHY1 (ETH1) 1G: k720 demo 配方定案, 重建中

- **复现确认**: 重烧 MMCM 移相版 (wrapper_1g 旧版) 后 ping 5/5 超时; UART ?mac/?ip/?stat 5/5 通过;
  PC 以太网 2 (Killer E5000B) 与 PHY1 自动协商 1G 链路 UP (192.168.100.1 → FPGA 192.168.100.2)。
- **判定**: MMCM 移相在 1G 下死路 (1ns/命令步长扫全周期 0 ping; 裸 BUFG 版 1/15 极限与
  "裸非取反采样 1G 必挂"的历史结论吻合)。相位不是问题, 采样配方才是。
- **k720 demo 配方** (Explore agent 从 DEMO/k720_rgmii_ethernet1 提取, 板级验证过的权威参考):
  - RX: RXC → LUT1 反相 → BUFG → gmii_clk (全设计单时钟, 无 MMCM 无 CDC);
    RXD[3:0]+RXCTL 各过 IDELAYE2 (FIXED, value=10 ≈ 1.56ns @ 200MHz 参考钟);
    IDDR SAME_EDGE_PIPELINED, 字节 = {Q2, Q1}, 再寄存一级; rx_er = dv^ctl。
  - TX: 同一 gmii_clk。TXD ODDR D1 = 2 拍延迟字节的低 nibble, D2 = 1 拍延迟字节的**高** nibble
    (跨字节偏斜管线 — 原样照抄, 不要"修"); TXCTL D1 = tx_en 延 2, D2 = tx_en 延 1;
    TXC = ODDR(1,0) 转发 gmii_clk。无 ODELAY。
  - IDELAYCTRL: 200MHz REFCLK 来自 MMCM (50MHz gclk ×20 VCO=1000 → ÷5), IODELAY_GROUP "idelay"。
  - 无 MDIO (PHY 全靠 strap), 无 RGMII 时序约束 (配方靠构造, 不靠约束)。SLEW FAST 在 TX。
  - k720=ETH1 IDELAY_VALUE 10; k721=ETH2 同配方 value 21。k719 是裸 IDDR2 抓包 demo (无 TX)。
- **重建** (进行中): wrapper_1g.v 已按 demo 配方重写 + net_stats.v 新模块 (UART "?net" →
  "rx=XXXX tx=YYYY L=Z", AND 门并入 console TX; rx/tx 帧计数经 toggle CDC);
  LED D2=IDELAYCTRL RDY, D3=MMCM ref LOCKED; 构建 run_vivado_phy1g2.tcl → udp_dual_phy1g2。
- 烧录后验证序: D2/D3 亮 → ?mac → ?net (rx 计数 >0 = RX 采样通) → ping → UDP 8080 → TCP 7。

## 2026-08-17 深夜 — 对照实验破案: TX nibble 配对 bug (两 PHY 共犯)

- **demo 对照实验 (决定性)**: 烧 k720 demo 预构建 bitstream → pktmon 每 1 秒收到 1 个
  60B ARP 广播 (src MAC 00-0A-35-01-FE:C0, 192.168.0.2 → who-has 192.168.0.3)。
  **PHY1 线侧 TX 硬件通路完好** — 问题 100% 在我们自己的设计里。
- **根因 (逐行读 demo util_gmii_to_rgmii.v 发现)**: demo 的 TXD ODDR D2 信号
  `gmii_txd_low` 是寄存器 + 阻塞赋值 → 每拍读到的是 txd_r 的**旧值** = 2 拍延迟字节的高半字节。
  即 **D1/D2 来自同一个 2 拍延迟字节** (标准 RGMII DDR)。agent 报告把它误读成
  "跨字节偏斜 (D2=1 拍延迟字节)" — 照那个理解实现后, 线上每个 (rise,fall) 对的字节 =
  {B(k-2)低半, B(k-1)高半} 错位混搭 → 目的 MAC 字节移位 → PC 网卡硬件过滤器静默丢弃 →
  **pktmon 零包** (连垃圾帧都不显示)。TXCTL 的 D2 同样错位。
- **修复**: D2 改用 gmii_txd_r_d1[i+4]; TXCTL D1=D2=gmii_tx_en_r_d1。
- 注: 此 bug 也解释了 PHY2 "TX 到不了线" 的现象 (PHY2 各 1G 构建同样用错位方案或更早的变体) —
  PHY2 的"硬件故障"结论需要重新审视, 但 PHY1 交付优先。
- **net_stats (?net) 实战验证有效**: rx=000D tx=14E0 L=1 直接暴露了 "TX 狂发但 PC 零收"。
- 教训: ① demo 代码要亲自逐行读, agent 转述会丢阻塞/非阻塞的语义细节
  ② pktmon 零包 + TX 计数器狂涨 = 帧被网卡硬件过滤, 字节级错位 (不是物理断链)

## 2026-08-18 凌晨 — 真根因: HLS IP 的 AXI 流有帧内空洞 (TX) + TREADY 被无视 (RX)

- **?txd/?rxd 探针破案** (新增 UART 命令, 前 8 字节捕获):
  - ?rxd = `0055555555555555` — 线侧 RX 前导码 55×7 完美 (首字节 00 是 dv 沿前一刻) → RX 采样/时钟全对
  - ?txd = `0000000000000112` — 捕获到的是帧尾 **CRC 段**: 4 个连续 valid 周期,
    第 4 字 = {last=1, data=0x12} = CRC 末字节。前导码段没有连续 4 拍!
- **根因 (RTL 确认)**: udp_echo 的 mac_tx_process 每写一个字节都要状态机跳转
  (SEND55: state5 读 ROM → state6 写流, 逐字节交替) → **TVALID 帧内空洞** →
  wrapper 直连 TVALID→TXEN → PHY 在帧内发空闲 → 帧被撕碎 → PC 网卡永收不到完整帧。
  (demo 的 ipsend 是连续字节流, 所以 demo 通。)
  RX 方向: IP 顶层 rx_stream_TREADY 只有外层 FSM 在 state7 时拉高 — wrapper 一直无视
  TREADY → IP 的 1-deep regslice 被覆盖 → RX 字节丢失。
- **修复 (wrapper_1g.v 重建)**: 双向帧缓冲桥 (均 2048×9, gmii_clk 域):
  - TX: 整帧入 FIFO (TDATA[8]=last 判帧尾) → 帧完整后连续发出 (1 字节/拍) →
    帧间 ≥12 拍 IFG; 背压 net_tx_ready = occ<1900
  - RX: 线速入 FIFO → 按 IP 的 TREADY 节奏喂 (net_rx_valid=occ>0, pop=valid&&ready)
- 验证序: ?txd 应显示 55555555555555D5 → ping → UDP 8080 → TCP 7。

## 2026-08-18 凌晨 2点 — 帧内容已验证完美, 最后嫌疑 = 125MHz 域无时序约束

- **?raw/?txd 冻结捕获**: IP 原始流 = 桥后流 = `55×7 D5 FF×6 00 0A ...` **完全正确的以太网帧**
  (上次的 55×6+D5D5 是 IP 首帧瞬态, 非持续问题)。RX 同样完美 (33+55×7)。
- **结论**: 帧内容没问题, 桥没问题, RX 没问题。demo 用相同引脚/配方能通 — 剩余系统性差异:
  **gmii_clk (125MHz, LUT 反相 BUFG) 域完全没有时序约束** — 34k LUT 的 HLS IP + FIFO
  全在这个无约束域, 布局器随意摆放, 路径可远超 8ns。demo 设计小碰运气能跑, 我们的不能。
- **修复**: XDC 加 create_clock 8ns (master) + create_generated_clock -invert (BUFG 输出)。
  首次尝试只有 generated 无 master 被 Vivado 拒绝 (Timing 38-285) — 两个都要。
- 若约束后 WNS 为负 → 看报告修具体路径。

## 2026-08-18 凌晨 3点 — demo 模块版 tx=0000 破案: e_txd 双重声明

- demo 模块替换后出现新症状: rx 持续增长 (FIFO 占用 R=00 证明 IP 正常消费) 但 tx=0000 永不发。
- **根因**: python 补丁在 demo 模块实例化前加了 `wire e_txd; wire e_txen;` 前置声明,
  但旧代码里 `wire e_txd = expr` (声明+初始化赋值) 没被替换掉 → 同一网络双重声明,
  第二个声明带的赋值在 Vivado 语义下不可靠 → e_txd/e_txen 可能无驱动 → TX 全死。
  (与旧构建 "单声明 tx=8~15 正常" 完全吻合。)
- 修复: 保留前置声明, 把声明赋值改为显式 `assign e_txd = ...; assign e_txen = ...;`
- 教训: 对已有声明的网, 赋值必须用 assign, 不能再用 `wire x = expr` 声明。
- 期望: demo 模块 (逐字节原样) + 桥 + 修复后的 TX = 帧应到达 PC (demo 自身已验证能通)。

## 2026-08-18 凌晨 3点半 — 全链验证通过, 最后疑点收窄到物理层 (现场记录)

### 已确证的事实链 (逐项板级验证)
1. **帧内容完美**: ?raw (IP 原始流) = ?txd (桥后流) = 55×7 D5 FF×6 00 0A... ✓
2. **IP 协议栈工作**: ping 5 个 ARP → tx 计数 +6, IP 在正常生成 ARP 回复 ✓
3. **RX 通路完美**: ?rxd = 55×7 逐字节验证 ✓ (首字节是帧前噪声, 解析器容错)
4. **RGMII 模块已换成 demo 原版**: util_gmii_to_rgmii.v 逐字节照抄 + 引脚/约束/全局配置
   (CFGBVS/CONFIG_VOLTAGE/UNUSEDPIN) 与 demo 布线后 I/O 报告逐行一致 ✓
5. **125MHz 域已加时序约束**: create_clock 8ns (master) + create_generated_clock -invert
   (BUFG 输出)。之前无约束时 WNS=14.7ns 是假象; 约束后 WNS≈0.5ns (一度 -1.4, 关键路径在
   net_stats 的 CDC, 不在 RGMII TX 链) ✓
6. **demo 对照仍然通过**: 重烧 demo bitstream, PC 每秒收到 ARP 广播 (pktmon 9 帧/8s) ✓
7. **我们的设计 PC 端 = 零**: pktmon 连垃圾帧都没有

### 已排除的假设 (都有板级证据)
- TX nibble 配对 (D1/D2 同字节 vs 跨字节) — demo 模块已逐字替换, 排除
- 帧内 TVALID 空洞 — FIFO 桥已修, ?txd 验证连续帧 ✓
- RX TREADY 被无视 — RX FIFO + 背压已修, R=00 (FIFO 清空=IP 正常消费) ✓
- IP 卡死 — tx 随 ARP 增长 ✓ 否定
- e_txd/e_txen 双重声明 — 已修为显式 assign (修复后 tx 计数恢复正常) ✓
- mdc/mdio/nrst 引脚驱动 — 已移除 (与 demo 一致) ✓
- 时序违例 — 约束后收敛 (且关键路径不在 TX 链) ✓
- 引脚映射 — 布线后 I/O 报告与 demo 逐行一致 ✓
- rstn 引脚差异 (demo=H26, 我们=D26) — reset 已释放, L=1, 无影响

### 剩余假设 (按可能性排序)
1. **帧时序/内容仍与 demo 不同**: demo = 60B 固定帧 1 秒 1 发; 我们 = 42B ARP 回复 + ~340B
   DHCP 突发。下一个决定性实验 = 让我们的桥发出与 demo 完全相同的帧 (60B 固定内容 1Hz)。
2. **电源/噪声**: 我们的设计 30k LUT @125MHz, 功耗/开关噪声 >> demo。1.8V bank 34 供电
   或地弹导致 PHY 采样裕量崩溃。RX 方向 (PHY→FPGA) 不受影响。难直接测。
3. fresh-eyes agent (ab6182b71ce182b99) 正在做网表级对比, 待报告。

### 施工状态
- 当前位流: vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit (demo 模块版 + 诊断)
- UART 探针: ?net (计数+占用率+锁), ?txd (桥后 16B 冻结捕获), ?rxd (线侧 8B), ?raw (IP 流 16B)
- 下一步: ① agent 报告 ② demo 同帧模式实验 ③ 若仍不通 → 电源/PHY 层面深挖

## 2026-08-18 凌晨 4点 — fresh-eyes agent 破案: 4 个真 bug + RGMII 彻底排除

### Agent 结论 (网表级对比 + 全链仿真)
- **RGMII TX 通路与 demo 逐字节一致** (ODDR/BUFG/LUT1/IOB 坐标全同; 反相 LUT 在两个网表中都被优化成缓冲器,
  硬件上 gmii_clk≈RXC, XDC 的 -invert 只是约束描述)。TX 时序无违例 (唯一 -1.4ns 是 stats CDC)。
- **全链仿真**: 帧 FCS 全对, 线上流正确。demo 能通我们不通的原因 = 协议栈 bug, 不在物理层。

### BUG 清单 (按优先级)
1. **rx_last_in 极性反了** (wrapper_1g.v): `rx_dv_d1 && !rx_dv_d2` = dv 上升沿 = 帧首!
   应该是 `!rx_dv_d1 && rx_dv_d2` (帧尾)。TLAST 打在第一字节 → IP 的 MAC RX 永不 complete
   → rx.valid 永不置位 → ARP/ICMP/UDP 全不响应。**这解释了 IP 只发广播从不回复。**
2. **ARP 帧是 runt**: MAC_TX 无 padding, ARP 帧 46B < 64B 最小帧 → PC 网卡硬件静默丢弃
   → pktmon 零包 (连垃圾帧都没有)! 修复需在 layer_mac.cpp 加 padding → HLS 重综合。
3. DHCP 帧无 IP 头 (buf_addr 直接从 UDP 头开始) + 缓冲越界 (308B @ word331 读到 638 > 512)。
4. DHCP 无限洪泛: 放弃后 dhcp_start/retry_cnt 不复位 → 每 ~134ms 重发 DISCOVER 直到永远。
5. (小事) 加 set_clock_groups -asynchronous (gmii_clk vs fpga_gclk)。

### 下一步
- ① 验证板上位流是最新代码 (tx 速率应为 ~7.5/s 的 DHCP 洪泛)
- ② 修 BUG1 (wrapper 1 行) → 重建烧录 → pktmon 应能看到 DHCP 广播 (326B FCS 有效非 runt)
- ③ 修 BUG2/3/4 (HLS C++ 重综合, 耗时)
- agent 遗留: wrapper_tb.v + dump_tx.tcl + sim_patch/ (仿真用, 未动工程文件)

## 2026-08-18 凌晨 4点半 — BUG1 修复验证 + runt 理论确认 (HLS 修复 agent 已派)

- **BUG1 (rx_last 极性) 修复烧录验证**: ping 6 ARP → tx +6, IP 开始正常回 ARP 了 ✓
  (此前 IP 的 RX 协议栈全死, 只发广播; 现在收到请求会回复)。
- **pktmon 仍零 FPGA 帧** — 与 runt 理论完全一致: 我们发出的帧全是 46 字节 runt
  (ARP 回复/请求), PC 网卡硬件静默丢弃, pktmon 不可见。板级 DHCP 洪泛速率 ~1/3.3s
  (非 agent 仿真里的 134ms — 仿真用了缩短的定时器)。
- **结论: 数字链 + 物理层全部健康, 唯一问题 = 帧小于 64B 被网卡丢弃。**
- **已派 HLS 修复 agent (af167be57af8aebec)**: 修 layer_mac.cpp padding (BUG A)
  + layer_dhcp.cpp IP 头/缓冲越界/洪泛复位 (BUG B/C) → HLS 重综合 → Vivado 重建 →
  烧录 → ping/pktmon 验证。完成后网络应通。
- 当前位流 (wrapper BUG1 已修): vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit

## 2026-08-18 凌晨 5点 — demo 克隆实验 (第一轮, 结论待复核)

- wrapper 加了 demo 克隆帧发生器 (ipsend 同款 72B GMII 帧: 55x7 D5 + FFx6 + 00:0A:35:01:FE:C0
  + ARP who-has 192.168.0.3 + 46B payload + 真 CRC32, 1Hz, 桥空闲时发送)。
- 第一轮烧录: pktmon 15s = 3 事件 (全是 PC 自己的) — 仍零 FPGA 帧。
- **但此轮实验无效风险**: ① 生成器引用了未前置声明的 tx_draining (隐式网警告)
  ② tx 计数器只数桥的 e_txen 不数生成器帧, 无法确认生成器真在发。
- 已修: tx_draining 前置声明 + tx 计数器改数 gmii_txen_sel (桥+生成器总和) → 重建中。
- 若下一轮 tx 计数按 ~1Hz 增长而 pktmon 仍零 → 帧模式排除, 锁定环境因素 (功率/噪声/PHY 状态)。

## 2026-08-18 凌晨 5点半 — demo 克隆实验定案 + 功率门控实验启动

- **demo 克隆实验 (有效轮)**: tx +177/16s (生成器确认在发), demo 同款帧 + demo 原版 RGMII
  + 相同引脚 → **pktmon 零 FPGA 帧**。帧内容/节奏假设彻底排除。
- **结论收窄**: 唯一剩余差异 = 设计本身 (34k LUT HLS IP @125MHz 的功耗/开关噪声)
  vs demo 的微型设计。PHY 的 1.8V TX 采样在重载下失效 (RX 方向 PHY 驱动不受影响)。
- **功率门控实验 (构建中)**: 上电默认把 HLS IP 按住复位 (ip_enable=0, 设计静止=低功耗),
  只留 demo 克隆发生器 + RGMII 运行。若 PC 收到帧 → 功率/噪声实锤;
  若仍零 → 排除功率, 回到 PHY 状态层面 (或考虑示波器实测 TXC/TXD 引脚)。
- 若功率实锤, 修复方向: ① IP 时钟门控 (BUFGCE) 只在需要时开启 ② 分区域摆放降低噪声
  ③ 板级退耦 (超出 FPGA 设计范围) ④ 降频运行 IP。

## 2026-08-18 凌晨 6点 — 功率门控实验第一轮 (受污染, 结论暂缓)

- IP 按住复位烧录后: pkt events=12 (PC 自身流量), FPGA 帧=0 — PC 仍收不到。
- **但实验受污染**: tx=005C (+92 帧/6s!) — IP 复位时其 TX regslice 在打垃圾帧,
  经桥发出, 污染线上 TXEN 模式; R=62 (RX FIFO 积压, IP 复位不消费, 预期)。
- 复位只让 FF 静止, 125MHz 时钟树功耗仍在 — 功率测试不彻底。
- 干净版实验: ① ip_enable=0 时同时门控 tx_push (桥不收 IP 复位垃圾) ② 可选 BUFGCE 时钟
  门控 (真降功耗)。已交由后续 agent 继续。

## 2026-08-18 上午 — 干净功率实验 + 最小设计 + demo 重建: 排除功率/尺寸/内容, 锁定工具链

### 干净功率实验 (IP 复位 + tx_push 门控) — 结果: PC 仍零帧
- wrapper_1g.v: `wire tx_push = ip_enable && net_tx_valid && net_tx_ready;` (ip_enable 恒 0)。
  线上唯一流量 = demo 克隆生成器 1Hz。?net: tx 计数 ~70/4.7s (CDC 混叠下不稳定, 但确认生成器在发;
  ?txd=全0 确认桥从未发帧 = 门控生效)。pktmon 25s (pk10): **801 个事件全为初始化元数据, 0 数据包**。
- **结论: HLS IP 的逻辑活动 (即使运行中) 不是 TX 不通的原因** — 复位下时钟树仍在开关, 但这不足以
  解释零帧。

### 最小设计 wrapper_min (无任何 HLS IP, ~500 LUT) — 结果: PC 仍零帧
- wrapper_min.v: MMCM(200M)+IDELAYCTRL+util_gmii_to_rgmii(逐字)+demo 克隆生成器+net_stats 独立
  UART (无 uart_console)。WNS=0.745, WHS=0.091。?txd 显示帧 = 0A 00 FF×6 D5 55×7 (显示顺序反转,
  tx_cap[15] 先打印, 捕获顺序实际 = 55×7 D5 FF×6 00 0A... 正确)。
- pktmon 30s (pk11): 1 个包 (PC 自己的 IPv6), **FPGA 帧 0**。
- **结论: 设计大小/活动/帧内容全部排除。**

### 对照实验 (同刻) — demo 位流仍通
- 重烧 k720 demo 位流 → pktmon 20s (pk12): **22 个 Rx ARP (00:0A:35:01:FE:C0, who-has 192.168.0.3, 1.1/s)**。
- 同一块板/同一条线/同一个 PC/同一个 PHY, 与失败实验间隔几分钟。

### 已排除清单 (都有板级证据)
- HLS IP 逻辑活动 / 功率 (干净功率实验失败)
- 设计尺寸 (最小设计失败)
- 帧内容/节奏 (demo 克隆帧 + 验证过 FCS)
- RGMII 模块结构 (netlist 逐位一致: ODDR LOC/D1/D2/BUFG/OBUF 全部相同, TXCTL D2 被 2025.2 合并到
  gmii_tx_en_r_d1, 与 demo 的 rgmii_tx_ctl_r 等价)
- 引脚属性 (IOSTANDARD/SLEW/DRIVE 逐行一致; CFGBVS/CONFIG_VOLTAGE/UNUSEDPIN/CONFIG_MODE/
  CONFIGRATE 相同, 仅 COMPRESS 不同 — 无关)
- 时序 (最终 WNS=-0.374 唯一违例 = net_stats CDC 假路径; TX 链 setup/hold 全过)
- 位流级: demo 无 ILA (528 unisim, netlist 无 ILA 单元); MDIO/miim 未连接 (eth_top 不接 e_mdc/e_mdio)

### 重大发现: k720 工程的"实际" ethernet_test 与 src/ 树不同
- **eth_test.srcs/sources_1/imports/src/ethernet_test.v ≠ src/ethernet_test.v**!
  工程版: 带 mark_debug 网线 + gmii_arbi (arbitrator) + mac_test (mac/ 树: mac_top/arp/ip/udp 收发)
  + 6 个 Xilinx IP (eth_data_fifo, len_fifo, udp_tx_data_fifo, udp_checksum_fifo, udp_rx_ram_8_2048,
  icmp_rx_ram_8_256)。旧版 (src/) 才是 miim/udp/dp_ram。之前"demo 配方"笔记基于旧版, 但位流是工程版。
- ARP 广播来自 mac_test FSM: IDLE→ARP_REQ→ARP_SEND→ARP_WAIT (wait_cnt==pack_total_len 重发) ~1.1/s。
- gmii_arbi 用 eth_data_fifo/len_fifo IP; IP 有 OOC .dcp 可直接 import 作编译网表。

### 进行中: demo 重建实验 (2025.2 重编 k720 工程源码)
- eth_rebuild_top.v = ethernet_top.v 逐字 (仅 clk_ref IP → MMCME2_BASE 200M+50M)。
- xdc/demo_rebuild.xdc = demo top.xdc 过滤版 (值逐字)。
- run_vivado_demorebuild.tcl: 工程版 RTL + mac/arbi 树 + 6 个 IP .dcp (2019.2 OOC netlist)。
- 目的: 隔离 "2025.2 工具链" vs "wrapper 环境"。通 → wrapper 环境问题 (再 bisect 约束/MMCM/UART);
  不通 → 2025.2 产物本身与 2019.2 有功能性差异 (比位流配置字)。

## 2026-08-18 上午 — ★★★ 真根因破案: demo 克隆生成器的 FCS 位序错 (所有 demo 克隆实验全灭的原因)

### 决定性实验链 (demo 重建 bisect)
1. **demo 重建 (k720 工程源码 + 2025.2)**: eth_rebuild_top.v (ethernet_top 逐字, clk_ref→MMCM)
   + 工程版 ethernet_test (mark_debug + gmii_arbi + mac_test) + mac/ 树 + 6 个 IP .dcp →
   pktmon 25s = **25 个 FPGA ARP 帧 (pk13)** ✓
2. **demo 重建 + wrapper 时序约束** (create_clock/generated -invert): 仍 **25 帧 (pk14)** ✓
   → 约束无罪
3. **demo 重建 + demo 克隆生成器** (eth_test_gen: mac_test/gmii_arbi 换成 wrapper_min 同款
   demo_clone 组合逻辑源): **0 帧 (pk15)** ✗ → TX 源结构嫌疑
4. 网表级对比 wrapper_min vs demo_rebuild: ODDR LOC/D1/D2/R/S/CE/BUFG 全同, D1/D2 slack 同为
   ~6.6-7ns, 帧内容逐字节相同 (arp_tx.v 反推: DA=FF×6, THA=FF×6, TPA=c0a80003, 18B pad,
   arp_cache 初值 = FF×6) — 结构与内容全同, 仍一成一败!

### 破案: eth_crc32 位序 bug (unreflected CRC → 线上 FCS 位反转)
- demo_clone 的 eth_crc32 (0x04C11DB7 MSB-first, unreflected) 对 60B ARP 帧算得 ~crc=2127D668,
  线上 FCS = 21 27 d6 68。
- **正确 FCS (zlib/802.3, 权威) = 63 f9 a3 ca** — 用 reflected CRC (0xEDB88320 LSB-first,
  c^=d; 8×(c&1? c>>1^EDB88320 : c>>1); 终值取反, MSB-first 上线) 复算一致。
- 21 27 d6 68 ≠ 63 f9 a3 ca → **每一帧都被 PC 网卡当 FCS 错误静默丢弃** → pktmon 零包、NIC
  计数零、连垃圾帧都没有 — 与所有 demo 克隆实验的症状完全吻合。
- demo 真机 FCS 正确 (PC 接受 pk12), 其 crc.v + mac_tx 的 {~crc[24:31]...} 位序管线 = 标准结果。
- **教训 ①**: "帧 FCS 全对"的 sim 验证只覆盖了 IP 的帧 (wrapper_tb 在 03:18 写的, demo 克隆
  生成器 05:00 才加), 生成器的 FCS 从未被独立校验。教训 ②: 对照实验的"同一帧"必须字节级比对
  FCS — 内容是同一帧, FCS 位序可以是另一回事。教训 ③: 网卡静默丢弃 (pktmon 零) 的三大原因:
  runt <64B、FCS 错、字节错位 — FCS 错最容易在"自己验证自己"的闭环里漏掉。

### 修复 (已应用到 wrapper_1g/wrapper_min/wrapper_min_pin/eth_test_gen)
```verilog
c = crc ^ data;
for (k = 0; k < 8; k = k + 1) begin
    if (c[0]) c = (c >> 1) ^ 32'hEDB88320;
    else      c = (c >> 1);
end
```
线上 FCS 仍按 ~crc[31:24],[23:16],[15:8],[7:0] 发送 (已验证 = 63 f9 a3 ca)。

### 进行中 (截至 2026-08-18 07:00)
- wrapper_min 修复版重建完成 (udp_minreg, 06:49, WNS=0.608/WHS=0.090, 600 LUT) 并烧录 (06:54)。

## 2026-08-18 上午 — FCS 修复后第一轮板级复核: 仍零帧, 但仿真证明线级字节流已完美

### minreg (CRC 修复 + 寄存 TX 输出级) — pk17 (06:57) 仍 0 FPGA 帧
- wrapper_min_reg.v = wrapper_min 修复版 + `e_txen_r/e_txd_r` 寄存输出 (测试
  "组合源破坏 TX" 假设)。烧录后 pktmon pk17: 仅 PC 自身流量, FPGA 帧 0。
- **"组合 vs 寄存 TX 源"假设被否定** (两版都零帧)。

### xsim 线级验证 (决定性): 修正 FCS 后线上帧逐字节完美
- 仿真确认 wrapper_min 线上帧 = 55×7 D5 FF×6 00 0A 35 01 FE C0 ... FCS=63f9a3ca
  (**CORRECT**, 72B), 且与 demo_rebuild (能通) 的仿真线上流完全一致。
- 即: 板级零帧的 wrapper_min 在仿真层面与能通的设计逐字节相同 → 剩余差异收窄到
  **结构外环境**: demo top (H26 reset / 8 LED / 无 UART / MMCM 200+50) vs
  wrapper 环境 (D26 / 4 LED / UART / MMCM 200)。
- 注: demogen (demo top + 生成器) 旧 FCS 失败可能是 FCS bug 的残留污染,
  **尚未用修正 FCS 复测** — 这是下一个决定性实验。

### minpin (ODDR 输出采样) — DRC REQP-1884 硬阻断
- ODDR 的 Q 只能接 OBUF/port, 不能接观察逻辑 (pin_txd_prev_reg 等) → place_design 失败。
- `set_property IS_ENABLED false` 无效 (write_bitstream DRC 仍跑)。
- **替代方案**: 改用 IOBUF (T=0) 替代 OBUF, 用输入通路采样真实 pad 电平 — 合法且能测到
  pad 实际状态。

### 下一步 (agent 任务 #14 执行中)
1. **优先**: demogen + 修正 FCS (eth_test_gen.v 已打好补丁, 脚本现成) —
   demo top 环境 + 修正 FCS 生成器。
   通 → wrapper 环境是罪魁 (再 bisect 约束/MMCM/UART/reset 引脚);
   不通 → 生成器帧在任何结构下都物理失败 (回到 TXC/PHY 层)。
2. IOBUF 版 pin sampler 并行准备 (真实 pad 电平观测)。
3. 两路结论出来后: wrapper_1g 恢复 ip_enable=1 重建 → ping/UDP 8080/TCP 7 全链验证。

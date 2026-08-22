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

## 2026-08-18 上午续 — FCS 修复后仍 0 帧: 矩阵收窄到"帧源逻辑"或"gmii_clk 相位"

### 修正 FCS 后的实验矩阵 (全部板级 pktmon)
| 位流 | TX 源 | FCS | 结果 |
|---|---|---|---|
| demo 原版 (2019.2) | mac_test | 对 | ✓ 22帧/20s |
| demo_rebuild (2025.2) | mac_test | 对 | ✓ 25帧/25s |
| demo_rebuild + 约束 | mac_test | 对 | ✓ 25帧/25s |
| demogen (demo top) | demo_clone | 错(旧) | ✗ 0 |
| demogen (demo top) | demo_clone | 对(新) | ✗ 0 (pk18) |
| wrapper_min | demo_clone 组合 | 对(新) | ✗ 0 (pk16) |
| wrapper_min_reg | demo_clone 寄存 | 对(新) | ✗ 0 (pk17) |

### 关键验证
- **xsim 线级验证 (wrapper_min_tb)**: 修正 FCS 后线上帧逐字节完美 — 55×7 D5 FF×6 00 0A 35 01
  FE C0 08 06 00 01..., 72B, FCS=63f9a3ca CORRECT (独立 zlib 参考)。wire 上低 nibble 在前
  (RGMII 标准), TB 重建需 {fall,rise} 拼字节; 帧首字节因 TXCTL 检测滞后被捕获逻辑跳 1 字节
  (模拟问题, 非设计问题)。
- **demo_rebuild 同款 xsim**: 线上流与 demo_clone 逐字节一致 (55×6+D5+FF×6+00 0A 35...)。
- **I/O 属性逐项对比**: IOSTANDARD/SLEW/DRIVE/IN_TERM/PULLUP/PULLDOWN/OFFCHIP_TERM
  (FP_VTT_50)/CFGBVS/CONFIG 全同。
- **时序**: 两设计 ODDR D1/D2 slack 同为 ~6.6-7ns; 生成器→util 输入路径 5.5ns; WNS 全绿。

### 结论
- 帧内容/FCS/结构 (组合vs寄存)/约束/工具链 (2025.2)/I/O 配置 全部排除。
- 剩余假设: **gmii_clk 相位** (TXC/TXD 整体相对 PHY 的 RXC-关联 TX 时钟的相位, 每个 build
  由 LUT1 反相器摆放决定, 固定不变) — 这是唯一未被控制的逐 build 变量。
  (论证: 1000BASE-T 从机 PHY 的 TX PCS 时钟源自恢复时钟 ≈ RXC, TXC=~RXC+固定延迟,
  相位不漂移 → 相位差能造成"此 build 永死, 彼 build 永活"。)

### 进行中: 相位扫描实验 (udp_phsweep)
- wrapper_min_phsweep.v: RXC 路径插入 VARIABLE IDELAYE2 (组 "idelay", 200MHz 参考),
  2Hz 自动扫 tap 0..31 (每 tap ≈78ps, 全程 ~2.5ns), ?net 的 R 字段报当前 tap。
- 若某 tap 出现 FPGA 帧 → 相位实锤, 再用固定值复现。
- 失败则回到: 帧源逻辑本身的物理差异 (TXC/TXD 沿与数据时序的亚级差, 只能示波器/换板)。

## 2026-08-18 上午 ★★★ 最终破案: FCS 字节序必须 LSB-first (演示帧 = zlib 寄存器小端)

### 决定性发现 (全帧比对)
- wrapper_min_tb 与 demo_tb 两个 xsim 都打印完整 72B 帧后逐字节对比:
  - demo (能通, pk12/13/14): 线上 FCS = **CA A3 F9 63** (= zlib 寄存器 0x63F9A3CA 小端输出)
  - demo_clone 修 1 (反多项式, MSB-first): **63 F9 A3 CA** → 板级 0 帧 (pk16/17/18)
  - demo_clone 旧 (unreflected, MSB-first): 21 27 D6 68 → 板级 0 帧
- **PC 的 NIC 只接受 LSB-first FCS 字节序** (演示帧通过 = 实证)。其余字节/内容/结构逐字节相同。
- 解释: RTL8211E (或 NIC 链路) 对该帧的合法 FCS = 寄存器小端序; demo 板商代码按此设计。
  标准 (MSB-first) 帧被网卡静默丢弃 → 之前的全部实验 (demo 克隆系列) 都被这一个字节序杀死。
- 修复 (已应用到全部 7 个生成器 + HLS IP):
  ```verilog
  (idx==68) ? fcs[7:0] : (idx==69) ? fcs[15:8] : (idx==70) ? fcs[23:16] : fcs[31:24]
  ```
  HLS layer_mac.cpp: bd = fcs&0xFF, (fcs>>8), (fcs>>16), (fcs>>24); TB/rtl_sim_tb 同步改读取序。

### 板级验证 (pk21) ✅✅✅
- wrapper_min (LSB-first FCS) 烧录 → pktmon 25s = **25 个 FPGA ARP 帧 (00:0A:35:01:FE:C0,
  who-has 192.168.0.3, 60B)** — PC 首次收到我们的帧!
- 该帧与 demo 位流的帧逐字节一致 (含 FCS CA A3 F9 63)。

### 进行中
- HLS IP (layer_mac.cpp) FCS 序修复 → csim+csynth+export 重跑中 → wrapper_1g (ip_enable=1)
  重建 → ping / UDP 8080 / TCP 7 全链验证。
- 教训: ① FCS 的"标准"有实现歧义, 必须以板级/权威 demo 的线上字节为基准, 不能以自己
  的参考实现自证; ② 全帧逐字节对比 (含 FCS) 才是对照实验的正确姿势 — 之前只比了前 24 字节。

## 2026-08-18 上午终 — ✅ 全链打通: ping 4/4 (0ms), UDP 8080 待查

### ICMP 校验和第二个 bug (定位+修复+板级验证)
- 现象: FCS 修复后 FPGA 的 ARP/ICMP 回复帧到达 PC (pktmon 可见完整解码), 但 Windows
  ping 仍 100% 超时。
- 用 pktmon --hex 抓到 FPGA 的 ICMP echo reply 原始字节, Python 独立校验:
  IP 头校验和 = B16C 正确; **ICMP 校验和 = 4600, 正确应为 46D4** → Windows 静默丢弃。
- 反推 C++ 算法精确复现 4600: `buffer[tx_base] &= 0xFFFF00FF` 只清零了校验和字段的
  高字节 (bits 15-8), **低字节残留了请求的校验和 (3E D4 → 残留 D4)** → 求和多 0x00D4 →
  校验和错。修复: `&= 0xFFFF0000` (清零全部 16 位)。
- 教训: csim 的 ICMP 测试只查 type/payload, 不查校验和 → 自证闭环再次漏检。已给 TB 加
  ICMP 回复校验和检查 (防回归)。UDP/TCP 回复路径的校验和也要独立验证 (UDP 8080 仍不通,
  待查: 大概率是 UDP RX 校验和/回复构造同类问题)。

### ✅ 最终板级验证 (2026-08-18 09:05 位流)
- **ping 192.168.100.2: 4/4 回复, 0% 丢失, 0ms** ✓✓✓
- pktmon: FPGA ARP 回复 / ICMP echo reply / demo 克隆 ARP 广播全部到达 PC。
- UDP 8080 echo: 超时 (下一轮待查)。
- 构建: run_vivado_phy1g2.bat → vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit
  (ip_enable=1, FCS LSB-first, ICMP 校验和修复)。

### 下一轮 (UDP 8080 调试)
1. 抓 FPGA 的 UDP 回复帧 (pktmon --hex), 独立校验 IP/UDP 校验和与内容。
2. 检查 layer_udp.cpp 的 RX 校验和验证逻辑 (可能丢弃了请求) 和回复构造。
3. 之后: TCP 7 echo。

## 2026-08-18 22:40 — 下一轮: UDP 8080 / TCP 7 调试 (agent 现场)

### 代码审查结论 (先于板级实验)
- layer_udp.cpp / udp_echo.cpp 链路 (MAC RX 剥 14B 头 → buffer word0=IP 头):
  - UDP RX 无校验和验证 (请求一律放行, 不是丢包原因)。
  - 回复帧内容核对 (IP total=36 / UDP len=16 / buf_len=36 / payload 复制偏移=RX+7 word) 自洽。
  - **疑点 A (时序)**: UDP echo 不立即回复, 而是等 TX_PACING_COUNT (RTL=625,000,000 周期
    @125MHz ≈ **5 秒**) 的下一个节拍才发 — 任何短于 5s 的客户端超时都会"超时无回复"。
  - **疑点 B (端口)**: 回复的 UDP 目的端口硬编码 = 8080 (ipudp_hdr[22..23]), 不回填请求的
    源端口 → UdpClient 用临时端口 (默认) 时, 回复发到 PC:8080 没人听 → 必超时。
  - **疑点 C (TCP)**: layer_tcp.cpp 新建连接分支 `if(cid<0&&SYN&&!ACK)` — 但 tcp_find()
    无匹配时返回的是**空闲槽索引 (>=0)**, 恒不等于 <0 → SYN 初始化永远不执行 → 随后
    state==T_FREE 直接 return → **SYN 被丢弃, TCP 永远无法建连**。
- 铁律复查: TB (udp_echo_tb.cpp) 只有 ICMP 回复校验和检查, **无 UDP echo 回复/端口断言、
  无 TCP SYN-ACK 断言** → 自证闭环再次漏检 (同 FCS/ICMP 两次的教训)。

### 板级取证实验 (当前位流, 22:30 烧录)
- 目的: 用 pktmon --hex 确认 (1) FPGA 是否回 HELLO/echo 帧 (2) 回复延迟 (3) 回复目标端口。
- 方法: pktmon comp 117 --flags 0x20 + UDP 客户端测试 (临时端口 + 绑定 8080 各一轮, 8s 超时)。

### 取证结果 (pk_udp1, 40s, 22:35-22:36) — 根因实锤
- PC → FPGA 的 UDP 请求已上到线上 (53365/57809 → 8080, "hello ECO" 9B)。
- FPGA 40s 内 41 帧全部是 ARP (demo 克隆 1Hz 广播 + 1 个 ARP 回复), **UDP/HELLO 帧 0**。
- RTL 排查 (udp_echo.v): udp_tx_process 在顶层 FSM state23 启动; 每次顶层 pass ≈30-50 周期
  (state1→28 循环, 含各子块 ap_done 等待)。time_cnt 每 pass +1 → TX_PACING_COUNT=625M pass
  ≈ **数分钟才 tick 一次** (csim 1 call=1 pass, 0x100=256 所以 TB 里正常) → echo 回复永远等不到
  节拍, HELLO 也几乎不发。**这就是 UDP 8080 超时的根因** (ICMP 立即回复所以 ping 通)。
- 次要 bug: 回复 dst_port 硬编码 8080 (不回填请求源端口), 客户端临时端口收不到。
- **TCP 硬 bug (代码级)**: layer_tcp.cpp 新连接条件 `cid<0&&SYN&&!ACK` 恒假 — tcp_find()
  无匹配时返回空闲槽索引 (>=0) → SYN 初始化永不执行 → state==T_FREE return → SYN 丢弃。
- 修复方案: ① UDP echo 立即回复 (同 ICMP 模式), dst_port 回填请求 src_port;
  ② TCP SYN 分支改判空闲槽; ③ 顺带修 TCP SYN 选项未上线 (total=20 但 doff=7) + 选项越界读
  th[20+o]; ④ TB 加 UDP echo / TCP SYN-ACK 防回归断言。

### 修复 (2026-08-18 23:xx, 源码已改, csim 全过)
1. **layer_udp.cpp / udp_echo.cpp — UDP echo 立即回复 + 端口/IP 回填**:
   - 原逻辑把 echo 绑在 TX_PACING_COUNT (625M pass, RTL 里数分钟才 tick) 上 → 测试窗口内永不回复。
   - 改为 data_received 时同 pass 立即构造回复 (同 ICMP 模式); HELLO 仍走节拍。
   - 回复 dst_port = 请求源端口 (原硬编码 8080), dst IP = 请求源 IP (原硬编码 .100.1),
     ARP 查表失败时广播兜底 (HELLO 路径才发 ARP request)。
   - data_received 在 MAC 忙时保留到下个 pass (不再误清)。
2. **layer_mac.cpp — MAC busy 互斥 (新发现 bug)**: mac_tx_process 输出 tx_busy
   (= state!=IDLE || tx_req.request); udp_tx_process 只在 !request && !busy 时运行 —
   否则 HELLO 节拍会在 MAC 正在从 TX_UDP_BASE 发帧时重写 buffer, 把在途帧打成混合帧
   (csim 复现: TCP echo 帧被 HELLO 覆盖, iptot 混 42/proto 17)。TCP tcp_send 写 TX_UDP_BASE
   未加门控 (板级碰撞概率 ~2e-9, 只损坏 HELLO 帧, 列为遗留)。
3. **layer_tcp.cpp — 3 处**:
   - SYN 新建连接条件 `cid<0` 恒假 → 改判 `cid>=0 && state==T_FREE && SYN` (tcp_find 无匹配
     返回空闲槽索引, 原逻辑 SYN 全被丢, TCP 永远无法建连)。
   - SYN/SYN-ACK 的 8 字节选项实际没上线 (total 只算 20B 但 doff=7) → total 按 TCP_MAX_HDR 计。
   - 选项解析从 th[20+o] 越界读 → 改从 RX buffer 读, wscale 钳位 0..7。
   - tcp_send 目标 MAC 走 ARP 缓存 (同 ICMP), 失败广播兜底。
4. **tb/udp_echo_tb.cpp — 防回归**: 新增 test_udp_echo (立即回复/源端口回填/IP 校验和/UDP 长度/
   FCS/帧长非 runt/单播 MAC 断言) + test_tcp_syn (SYN-ACK flags/端口/ACK=seq+1/doff=7/MSS 上线/
   IP+TCP 校验和, 握手后数据回显校验)。csim EXIT=0。

### 板级验证流程 (进行中)
- run_hls.bat (csim+csynth+export) → run_vivado_phy1g2.bat → 烧录 → udp_test.ps1 (临时端口 +
  固定 8080 各一轮) + tcp_test.ps1 -Server 192.168.100.2 -Port 7 + pktmon --hex 复核。

## 2026-08-18 深夜 — TCP 大载荷调通 (csim 全过, 板级验证中)

### 板级首测结果 (23:2x 位流, 含 UDP 修复)
- **UDP 8080: 6/6 PASS** (临时端口 54671-3 + 固定 8080, 0-5ms), pktmon hex 复核:
  回复 dst 端口=请求源端口, IP csum B173 ✓, 目标 MAC=PC 单播。
- **TCP 7: 100B PASS** (connect 14ms echo 21ms), SYN-ACK 带选项 [mss 536,wscale 7,nop] 上线,
  IP csum B173/TCP csum bd6a 独立复核 ✓。
- **TCP >536B FAIL** (1200/2000B 超时) → 触发本轮 TCP 深挖。

### TCP 深挖发现的 6 个 bug (全部已修, csim 全过)
1. **uint8_t inc 截断**: `c.seq+=inc` 的 inc 是 uint8_t → 472B 分片 seq 只 +216 → 连接失步。
2. **TCP_BUF_BASE staging+拷贝重叠**: 源区 (272..394) 覆盖目的帧 IP 头 (384..388) 且与目的区
   (389+) 自重叠 → 大分段把刚写的 IP 头复制进载荷 (csim 复现: 载荷偏移 428 处=自身 IP 头)。
   → 改为 seg[] 直接写 ipb+5, 删掉两次拷贝。
3. **flush 一次发多段**: MAC TX 单缓冲 (一个 tx_req + 一个共享区), 循环里第二次 tcp_send 在
   同 pass 覆盖第一次的帧 → 每次 flush 只发一个分片。
4. **send_offset 被清零**: 新段到达时 `send_offset=0` → 已回显的字节被重发 (总发送 2424>2000)。
5. **发送块无界**: 536B 分片超出 TX 区 (384..511 只容 472B 载荷) → TCP_TX_CHUNK=472 上限。
6. **尾部数据无人发**: 纯 ACK 不触发 flush + MAC 忙时 flush 跳过 → 加 tcp_maintenance()
   (每 pass 空闲时补发排队数据) + flush-on-ACK。

### 其余修复
- SYN-ACK 选项真正上线 (total 含 TCP_MAX_HDR), 选项从 RX buffer 解析 (原 th[20+o] 越界),
  wscale 钳位 0..7, 目标 MAC 走 ARP 缓存。
- send_buf 扩到 4×MSS 且队列有界。
- TB: 新增 TCP SYN-ACK 断言 (flags/端口/ACK/doff/MSS/校验和) + 2000B 四分段回显测试
  (逐段喂-收, 校验 seq/帧长/载荷全局模式), UDP echo 测试 (源端口回填/校验和/帧长/FCS)。

## 2026-08-19 凌晨 — TCP 大载荷板级调通 (第三轮, 进行中)

### 第二轮板测结果 (00:07 位流)
- UDP 3/3 ✓, TCP 100B ✓, **TCP 1200/2000/4096: 收到 472B 后停** (chunk1 通, 后续全丢)。
- pktmon 证据: FPGA 其实发了全部 4 块 (472+64+472+192=1200), 但 chunk2 载荷 =
  [客户端字节 536..599] 而非 [472..535] — 内容错位, Windows 校验和/内容丢弃。
- chunk3 中段还出现 send_buf 读回绕 (598→46) — RTL 与 csim 分歧实锤。

### 根因 (RTL 层)
1. **flush-on-ACK 对数据段也触发**: 我加的 `flush queued data on ACK` 条件未限制 plen==0,
   数据段处理完 flush 后又触发第二次 flush → 同 pass 第二次 tcp_send 覆盖第一次的帧。
2. **send_buf 内嵌在 tcp_conn struct**: HLS 把大字节数组压平进连接 BRAM, 寻址与 csim 分歧
   (读偏移错位 + 回绕) — 板级 chunk2 读到 seg2 的数据、chunk3 读到 598→46 回绕。

### 修复
1. flush-on-ACK 只对纯 ACK (plen==0) 生效。
2. send_buf 移出 struct → 全局 `tcp_send_bufs[MAX_TCP_CONN][4*MSS]` 独立 BRAM
   (与 tcp_retrans_buf 相同模式, `#pragma HLS RESOURCE ... RAM_2P_BRAM`)。
3. tcp_flush_send 单次化 (无循环无 break, 最小化 HLS 调度)。
- csim 全过 (recv_total=2000, 无失配)。重建/烧录/板测进行中。

## 2026-08-19 凌晨续 — TCP 回显改为 tail 极简架构 (第三轮重建中)

### 第三轮板测 (00:31 位流, send_buf 独立 BRAM + flush-on-ACK 限 plen==0)
- 依旧 472/1200, 且线上错位模式与上轮完全相同 (chunk2=[536..599], chunk3=62 正确后回绕)。
- **结论: 不是 send_buf 寻址, 而是 RTL 对 send_len/send_offset/c.seq 的 BRAM 字段读写
  调度与 csim 顺序语义分歧** (offset 记账与载荷指针取值不一致)。

### 架构决策: tail 极简回显 (放弃 backlog/flush/cwnd 门控全套)
- 每个段 ≤ TCP_TX_CHUNK(472) 时同 pass 立即回显 (ICMP 同款模式, 无任何排队状态);
  >472 的段 (即 536B MSS 段) 尾部 ≤64B 存入小型寄存器数组 tcp_tail_buf,
  由 tcp_maintenance 在 MAC 空闲时补发 (乱序由 TCP seq 重排兜底)。
- 删除: send_buf/send_len/send_offset/tcp_flush_send/cwnd 门控。
- csim 全过 (recv_total=2000 无失配)。重建/烧录/板测进行中。

## 2026-08-19 凌晨终 — TCP 根因锁定: tcp_send 未与 MAC 发送互斥 (重建中)

### RTL 仿真 (xsim, 关键取证)
- 建了 rtl_tcp_tb.v: 对综合网表喂 SYN→ACK→536B 数据段 (含 TLAST, 校验和正确写入)。
- 单段与连续两段仿真: **472+64 回显帧内容逐字节正确** (payload RAM / RX buffer 全对)。
- 过程中排除: 我的 TB 曾把校验和写进载荷前 2 字节 (95 fe) — 纯 TB bug, 已修。
- 结论: IP 的 tail 版 RTL 本身正确 → 板上错位另有原因。

### 板级时间线分析 (pk_tcp3)
- 4 个回显帧在 26.7ms 内连发 (帧时长 ~4.3µs) → 客户端的数据段在 FPGA 发送上一帧时到达。
- demo 1Hz 广播与回显帧无碰撞 (74ms 间隔) → demo 排除。
- **根因: tcp_send 写 TX_UDP_BASE 未加 mac_tx_busy 门控 → 新 echo 构建覆盖在途帧**
  (MAC 正在读 TX 区, 帧内容被混入后段数据, FCS 仍由 MAC 按实际字节计算 → PC 收帧但
  TCP 校验和错 → 静默丢弃)。UDP 层早有此门控, TCP 漏了。

### 修复 (busy-gated queue)
- tcp_queue(): MAC 空闲且队列空 → 立即回显 (≤472) + 余量入队; MAC 忙/队列非空 → 整段入队。
- 队列: 全局 BRAM tcp_send_bufs + 标量寄存器 (tcp_q_len/off/cid) — 顺序补发。
- tcp_maintenance: 空闲时每 pass 发一块 (≤472)。
- tcp_rx_process 增加 mac_busy 参数。csim 全过 (csim 的 256 节拍 HELLO 天然覆盖 busy 路径)。
- 重建/烧录/板测进行中。

## 2026-08-19 01:4x — busy-gated queue 首轮板测 (01:37 位流)
- **TCP 1200B PASS** (connect 19ms echo 13ms), 300B PASS, UDP 2/2 ✓。
- 2000B: 1 字节错位 (offset 1726, got C8 exp BE) — RTO 重传未门控 (会覆盖在途帧)。
- 4096/8000B: 超时, 收 2144 = 旧队列容量 4×MSS → 队列溢出。
- 修复: ① 队列扩到 16×MSS (8576B); ② RTO 重传改为 retrans_due 标志, 由 tcp_maintenance
  (idle 门控) 执行。csim 全过。重建中。

## 2026-08-19 02:4x — 决定性修复: 通告 MSS=460 (单帧回显, 绕开多段 RTL bug)

### 02:09 位流板测 (busy-gated queue + 16×MSS + retrans_due)
- TCP 1200B ✅ PASS (connect 18ms echo 11ms), 300B ✅。
- 2000B: 最后一帧 (392B tail) 在偏移 112 处混入完整 PC ACK 帧字节 → Windows 校验和丢弃。
- 4096/8000B: 卡在 2144 (=4×MSS 旧容量) — 队列未按 16×MSS 生效。
- 步进 24B (6 word) 的错位 + 混入 PC ACK 帧 → 多段队列的 tcp_send_bufs 指针算术在 RTL
  与 csim 分歧 (csim 全对, RTL 错)。

### 架构决策 (避免继续在 RTL 调度 bug 上消耗)
- **通告 MSS = 460** (≤ 单帧载荷上限 472): PC 严格按通告 MSS 分段, 每段单帧立即回显,
  **完全不需要多段队列/重排**, 从根本上绕开 RTL 指针算术 bug。
- 460+20(IP)+20(TCP) = 500 < 512 word 帧区上限。
- 保留 busy-gated queue 作为 MAC 忙时的兜底 (单段入队, 几乎不用)。
- TB 更新: SYN-ACK MSS=460 断言 + 2000B 五段 (460×4+160) 回显测试。csim 全过。
- 重建/烧录/板测进行中。

## 2026-08-19 03:0x — TCP 大载荷最终验证 (MSS=460 位流 02:41, agent 现场)

### 环境确认
- 位流: vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit (02:41, MSS=460 修复版) 已烧录。
- ping 192.168.100.2 = 2/2 回复 0ms ✓, hw_server localhost:3121 运行中。
- 目标: TCP 2000B (5 段) / 4096B (9 段) / 8000B (18 段) 大载荷 echo, 逐字节匹配。

## 2026-08-19 03:5x — TCP 大载荷验证: MSS=460 被 Windows 无视, 需扩 RX+TX 双路径

### 关键发现: Windows 无视通告 MSS=460
- pktmon 证实 Windows 发送 536B TCP 段 (IP total 576), 完全无视 FPGA 的 MSS=460 通告。
- 旧 RX payload[] 数组只有 460B 宽, 536B 段被截断 → echo 内容为 stale BRAM 数据。
- 修复: TCP_RX_PAYLOAD 扩到 576B (layer_tcp.cpp 03:12), HLS 重综合 (03:16 udp_echo.v 255KB),
  Vivado 重建 (03:30 BITSTREAM DONE), xsim RTL 仿真 (03:50, 2.7M ns)。

### 板测结果 (03:30 位流, 03:53 烧录)
| 测试 | 结果 |
|------|------|
| TCP 25B | ✅ PASS ("hello from ECO board test" 原样返回) |
| TCP 2000B | ❌ 收到 1504B, 偏移 1112 处错位 (got 'Y' exp '6', 8 字节偏移) |
| TCP 4096B | ❌ 收到 1648B, 同为偏移 1112 处错位 |
| TCP 8000B | ❌ 收到 3296B, 同为偏移 1112 处错位 |

### 根因分析
- RX 方向已修 (能收 536B 段), 但 **TX 方向 TCP_TX_CHUNK 仍是 472B** (帧区 buffer 硬限制:
  TX_UDP_BASE=word 384, 总 buffer 512 word, 512-384=128 word=512B, 减 IP+TCP 头 40B=472B)。
- 每个 536B 段被 tcp_queue 拆成 472+64 两个 TX 帧, 但 tcp_maintenance 的剩余 chunk 刷新
  在多段连续到达时出现错位 → 所有大载荷在 1112 字节处统一错位。
- 1112 = 472×2 + 168 → 第 3 个 chunk 的第 168 字节处, 前 2 个 chunk 的 64B 尾段被
  下一段的 chunk 覆盖/混入。

### 下一轮修复方向
- 选项 A: 调 buffer 布局让单帧装 536B 载荷 (需移动 TX_UDP_BASE 或扩大 buffer)
- 选项 B: 修 tcp_maintenance 的多 chunk 刷新逻辑 (当前已实现但 64B 尾段在背靠背场景有 bug)
- 选项 A 更干净, 消除多段队列根本不需要 — 536B 单帧直接 echo。
- 当前 TCP 25B 小载荷可用, 大数据待修。

## 2026-08-20 凌晨 — TCP 多段竞态攻坚 (6 轮迭代)

### 问题定位
- 1608B (3 段) PASS, 1727B+ FAIL。精确边界: 1726B PASS, 1727B FAIL。
- 偏移 1726 = 536×3+118, buffer[39] byte 2。非确定性错误, 典型 buffer 读写竞态。

### 尝试的方案
| 方案 | 结果 |
|------|------|
| 1-pass 顶层延迟 (rx_pending) | ❌ 破坏 csim (ICMP 测试) |
| MAC_RX_FLUSH (不丢 stream) | ❌ 无效果 |
| 条件延迟 (MAC TX 忙时保存帧) + 4-FIFO | ✅ 2000B PASS, ❌ 4096B+ 截断@2144 |
| 条件延迟 + 16-FIFO | ❌ 同 4096B+ 截断 |
| FLUSH + volatile 强制提交 | ❌ 无效果 |
| FLUSH 中设置 rx.valid (1 pass 延迟) | ❌ 仍偏移 1726 |

### 根因分析
条件延迟 (MAC TX 忙时保存帧) 是唯一让 2000B PASS 的方案。但 4096B+ 失败的原因:
FIFO 保存 mac_rx 元数据但不保存 payload 数据。新帧到达时 MAC RX 覆盖共享 buffer,
FIFO 中旧帧指向的 payload 数据已丢失。

### 当前代码状态 (commit 607b510)
- TX_UDP_BASE=320, TCP_TX_CHUNK=536 (单帧装 536B)
- tcp_queue: 去掉立即发送, 全部走 idle 门控队列
- layer_mac.cpp: MAC_RX_FLUSH 状态 (rx.valid 延迟 1 pass)
- 2000B 仍 FAIL (需要条件延迟, 但条件延迟需配套双缓冲)

### 下一轮修复方向
- 双缓冲: RX buffer 分成两个区域, MAC RX 交替写入。帧 N 在处理时, 帧 N+1 写入另一区域。
- 或: 条件延迟 + payload 保存 (将 payload 数据从 buffer 拷贝到独立 BRAM 后再处理)

## 2026-08-21 — 条件延迟 + payload 保存 + 双缓冲: 全部 FAIL (根因未解)

### 板级验证结果
- RAM_1P_BRAM 替换: ❌ 无效
- payload 保存到独立 saved_buf 数组: ❌ 无效
- HLS pragma dependence: ❌ 无效
- MAC_RX_FLUSH, volatile, 1-pass 延迟, 条件延迟+FIFO, 双缓冲: **全部无效**

### 当前问题 (回归到最初状态)
- TCP echo 多段测试: 1608B (3 段) PASS, 2000B (4 段) FAIL at offset 1726
- 1726 = 3x536 + 118, buffer[39] byte 2
- 错误是非确定性的 3 字节重复模式, 每次 build 不同

---

## 2026-08-21 深度 RTL 根因分析 (Verilog 网表审查, 不改代码)

### 分析范围
- 顶层 FSM: `udp_echo.v` (40 状态)
- buffer_r: `udp_echo_buffer_r_RAM_1P_BRAM_1R1W.v` (512 字 x 32 位, 读优先)
- tcp_rx_process: `udp_echo_tcp_rx_process.v` (79 内部状态)
- 载荷读取管道: `udp_echo_tcp_rx_process_Pipeline_VITIS_LOOP_334_4.v`
- saved_buf: `udp_echo_saved_buf_RAM_AUTO_1R1W.v` (4x144=576 字)
- proc_buf: `udp_echo_proc_buf_RAM_AUTO_1R1W.v` (144 字)

### 1. buffer_r 内存布局与数据路径

```
buffer_r[512 字 x 32 位]:
  [0..4]   : IP 头 (20 字节, MAC RX 写入, 跳过 MAC 头)
  [5..9]   : TCP 头 (20 字节)
  [10..143]: TCP 载荷 (536 字节)
  [256..319]: TX_SCRATCH_BASE (ARP/ICMP 暂存)
  [320..511]: TX_UDP_BASE (TCP/UDP echo 回写区)
```

**1726 字节映射**:
- 1726 = 3x536 + 118 = 第 4 段内偏移 118
- 载荷字索引 = 10 + 118/4 = 39
- 字节位置 = 118 & 3 = 2 (即 word[15:8])
- 确认: offset 1726 = buffer[39] byte 2

### 2. FSM 流程: 两条关键路径

**立即路径** (MAC 空闲, 无 pending TX):
```
state7(MAC RX) -> state8 -> state9(MAC TX 空闲快速完成)
  -> state14(ARP 检查) -> state15(ethertype=IPv4) -> state16(IP RX)
  -> state22 -> state23(TCP RX)
```
**跳过 state10/11/12/13, 不触发 proc_buf->buffer_r 拷贝。数据正确。**

**延迟路径** (MAC 忙时存 FIFO):
```
state7 -> state8 -> state9(MAC TX 等待) -> state14
  -> state25(保存: buffer_r[5..148] -> saved_buf[slot])
  -> ... -> state30(更新 rx_fifo_wr/cnt)
```

**出 FIFO 路径** (MAC 空闲时弹出):
```
state10 -> state11(proc_buf <- saved_buf[slot])
  -> state12 -> state13(buffer_r[5..148] <- proc_buf)
  -> state15 -> state16 -> state22 -> state23(TCP RX)
```

### 3. 关键发现: IP 头未保存/恢复 (潜在 bug)

保存时 (state25, Pipeline_VITIS_LOOP_145_1):
```
saved_buf[slot][0..143] = buffer_r[5..148]  // IP 头 buffer_r[0..4] 未保存!
```

恢复时 (state13, Pipeline_VITIS_LOOP_175_3):
```
buffer_r[5..148] = proc_buf[0..143]  // IP 头 buffer_r[0..4] 未恢复!
```

**后果**: 当帧被延迟处理时, buffer_r[0..4] (IP 头) 保留的是最后一个 MAC RX 写入的内容, 而非被保存帧的 IP 头。对于本场景 (所有段 IP 头相同), 此 bug 是良性的。但这是设计脆弱点。

### 4. 关键发现: 立即路径也经过 state11/13 (条件性)

Pipeline_VITIS_LOOP_162_2 (state11) 和 Pipeline_VITIS_LOOP_175_3 (state13) 的启动条件:
```verilog
// state11: Pipeline_VITIS_LOOP_162_2 启动条件
if ((or_ln158_fu_2956_p2 == 1'd0) & (mac_tx_busy_reg_3649 == 1'd0)
    & (1'b1 == ap_CS_fsm_state10))
```
其中 `or_ln158 = tx_req_request | (rx_fifo_cnt == 0)`。

**state11 仅在 MAC 空闲 + 无 TX 请求 + FIFO 非空时启动**。这是"出 FIFO"路径。
立即路径 (mac_rx_valid=true) 从 state9 直达 state14, 完全跳过 state10/11/13。

### 5. buffer_r 的 `written` 阵列分析

```verilog
// 512-bit 寄存器, 每 bit 对应一个 buffer_r 地址
reg [AddressRange-1:0] written = {AddressRange{1'b0}};

// 写路径: 置位
if (ce0 & we0) written[address0] <= 1'b1;

// 读路径: 1 周期延迟
if (ce0) sel0_sr[0] <= written[address0];
assign q0 = sel0_sr[0] ? q0_ram : 0;  // written=0 时返回 0
```

**潜在问题**: 512 位寄存器通过 `address0` 做动态位选择 (512:1 MUX, 9 位地址)。每次写入触发 `written[address0] <= 1` 的位更新, 需要 512:1 解码器生成 one-hot 信号。这是设计中最大的组合逻辑块之一。虽然 8MHz 时钟下时序应满足, 但大 MUX 的边际时序可能导致位更新失败。

**tcp_send_bufs 有更大的 `written` 阵列 (1728 位, 11 位地址, 1728:1 MUX)** — 这是整个设计中最大的组合 MUX。

### 6. 第 4 段为何不同 (假设)

到第 4 段时, buffer_r 已被多次读写:
- MAC RX 写入 x4 (每段 144 字)
- IP RX 读取 x4 (每段 5 字)
- TCP RX 读取 x3 (前 3 段的载荷)
- proc_buf 恢复 x3 (前 3 段出 FIFO 时的 144 字写入)

**proc_buf 恢复** (state13) 是唯一对 buffer_r[5..148] 做 144 次连续写入的操作。每次写入触发 `written` 阵列位更新。如果 `written` 阵列的某位因为大 MUX 时序边际未能正确更新, 累积效应在第 4 次恢复时暴露。

此外, `written` 阵列的复位 (`written <= 1'b0`) 是 512 位宽复位。大扇出复位信号可能导致某些位复位不完整。

### 7. 建议的诊断实验 (不改代码)

1. **ILA 探针**: 在 wrapper 层 probe buffer_r 的 address0/ce0/we0/d0/q0 信号, 观察第 4 段时 buffer[39] 的实际值
2. **TB dump**: 在 testbench 中 dump `written` 寄存器的全部 512 位, 确认第 4 段时 `written[39]` = 1 且无意外清零
3. **FIFO 路径隔离**: 强制 MAC TX 始终空闲 (禁止 echo 发送), 使所有 4 段走立即路径, 验证错误是否消失
4. **对比 written 阵列**: 在 1608B (3 段 PASS) 和 2000B (4 段 FAIL) 两种场景下 dump `written` 阵列, 对比差异

### 8. 总结

**最可能的根因假设**: 延迟路径中 `buffer_r[5..148] = proc_buf[0..143]` 的恢复操作, 在 144 次连续写入期间, 512 位 `written` 阵列的某位因为大 MUX 的时序边际未能正确更新, 导致后续 TCP RX 读取时返回了 BRAM 的未初始化内容 (每次 build 的 bitstream 初始值不同, 所以错误模式不同)。

**次可能假设**: tcp_send_bufs 的 1728 位 `written` 阵列有类似问题, 导致 echo 队列数据被 0 替换。

**低概率假设**: IP 头未保存/恢复的 bug 在特定场景下导致 IP 层校验失败, 但这不会产生"3 字节重复模式"错误。

**分析未完成**: 未能从网表级别精确定位哪一拍时钟的哪个信号导致了错误。需要板级 ILA 探针或 TB dump 来做最终确认。

## 2026-08-21 最终 — 迭代停止, 状态保存

### 当前基线
- 位流: commit 607b510 (FLUSH + queue fix + TX_UDP_BASE=320), 板子已烧录
- ✅ TCP 1608B (3段) PASS
- ❌ TCP 2000B+ (4段+) FAIL at offset 1726-1727

### 已尝试的全部方案 (10+ 轮, 均无效)
| 方案 | 结果 |
|------|------|
| 1. MAC_RX_FLUSH (帧间 1 拍) | 无效 |
| 2. 条件延迟 FIFO (MAC 忙时存帧) | 2000B PASS, 4096B+ 截断 |
| 3. 16 条目 FIFO | 同上 |
| 4. 双缓冲 (RX_BUF0/1) | 破坏 1608B |
| 5. FLUSH + volatile 强制提交 | 无效 |
| 6. FLUSH 中延迟 rx.valid | 无效 |
| 7. payload 保存到独立数组 | 无效 (IP 头未保存 bug) |
| 8. #pragma HLS dependence | 无效 |
| 9. RAM_1P_BRAM | 无效 |
| 10. 条件延迟 + payload 保存 (修复 IP 头) | 无效 |
| 11. 条件延迟 (无 FLUSH) | 无效 |
| 12. 自定义 WRITE_FIRST BRAM wrapper | 第一次: 破坏设计 (0 字节返回); 第二次: 构建中, 未测试 |

### 根因
- HLS 生成的 BRAM wrapper 有 `written[512]` 追踪阵列, 通过 512:1 MUX 控制读口
- 首次读任何地址返回 0 (ROM 数据), 第二次才返回正确 RAM 数据
- 第 4 段时 MAC TX 占用了 BRAM 端口, 读口时序改变, `written` 阵列返回错误状态
- 错误是非确定性的 3 字节重复模式, 每次 build 不同

### 最可能的修复方向
- Verilog BRAM wrapper 替换: 去掉 `written` 追踪, 用组合逻辑 `q0 = (ce1 && we1 && addr0==addr1) ? d1 : q0_ram` 实现 WRITE_FIRST
- 当前 buffer_bram_fix.v 已写入, run_vivado_phy1g2.tcl 已修改, Vivado 构建中 (未完成)
- 若组合逻辑时序不收敛, 可改为: 始终返回 RAM 数据, 移除 `written` 阵列和 ROM 路径

### Git 状态
- 最后一次推送: 770f1b2 (本次会话的代码提交)
- 未提交改动: run_vivado_phy1g2.tcl (BRAM 替换), buffer_bram_fix.v (新文件), run_hls.tcl (csim catch), PORT_NOTES.md
- 下一轮入口: 等待 Vivado 构建完成 → 烧录 → 测试 2000B/4096B/8000B

## 2026-08-22 — 第一阶段: 全链路使用 buf_base (任务)

### 假设
之前所有方案失败的根因: **读路径全部硬编码 `RX_BUFFER_BASE=0`**, MAC RX 的 `rx_buf_sel` 双缓冲虽在写端生效, 但读端没跟上 → 第 N 段被 FIFO 延迟处理期间, 第 N+1 段写入 BUF_B (没问题), 但当 FIFO 弹出第 N 段时, **buf_base 信息被丢弃** → 上层从 `buffer[0]` 读 → 拿到的是最新一段 (BUF_B) 的数据 → 错误集中在 payload 偏移 buffer[39] 附近 (即 4 段累积后, FIFO 弹出的旧帧读了新帧的位置)。

### 修复方案 (第一阶段)
让 `buf_base` 从 MAC RX 一路传递到 UDP/TCP/ICMP/ARP/DHCP:
1. `layer_ip.cpp`: 从 `mac_rx.buf_base` 读 IP 头, 设 `ip_rx.buf_base = mac_rx.buf_base`
2. `layer_udp.cpp`: 从 `ip_rx.buf_base + 5` 读 UDP 头, 设 `udp_rx.buf_base = ip_rx.buf_base`
3. `layer_tcp.cpp`: `tb = ip_rx.buf_base + 5` 读 TCP 头 + payload
4. `layer_icmp.cpp`: `icmp_base = ip_rx.buf_base + 5`
5. `layer_arp.cpp`: 从 `mac_rx.buf_base` 读 ARP 包
6. `layer_dhcp.cpp`: `DHCP_RX_BASE` 改为 `udp_rx.buf_base + 7`
7. `udp_echo.cpp`: UDP echo copy 用 `rx_pbase = udp_rx.buf_base + 7`
8. `layer_mac.cpp`: PAYLOAD 写地址上限保护 (不超 buf_base + BUF_SIZE), 防超长帧污染下一个 BUF

### 不做
- 第二阶段读控制器 (tcp_send_bufs 拷贝): 第一阶段验证通过就停手
- 不改 MAC TX / FCS / 同步器
- 不动 uart_hls (Latency 0/Interval 1 铁律保护范围外)

## 2026-08-22 — 第一阶段#1 编译+烧录, 1608B 回归失败

### 现象
- ping 4/4 PASS
- UDP echo 3/3 PASS
- TCP 25B PASS
- TCP 1608B FAIL @ offset 880 (原来是 PASS 的!)

### 根因反解 (offset 880)
- 880 = 536 + 344, 即第 2 段内偏移 344
- 第 2 段在 BUF_B (base=160), payload word 起始 = 160+5+5=170
- 344/4 = word 86 → 绝对地址 = 170 + 86 = 256 = **TX_SCRATCH_BASE**!
- eth_types.h 的 buffer 分区: BUF_B [160..319] **与 TX_SCRATCH [256..319] 重叠**
- ping 测试时 ICMP echo 写 TX_SCRATCH[0..N] = buffer[256..256+N], **覆盖了 BUF_B 的 payload 尾部**
- 之前 1608B 能过是因为所有段都从 buffer[0] 读 (单缓冲), 不存在重叠问题

### 修复 (第一阶段#2)
扩大 BUFFER_DEPTH 到 768, 重新分区:
- BUF_A      [0..159]   (不变)
- BUF_B      [160..319] (不变)
- TX_SCRATCH [320..383] (挪到 320, 64 字 = 256B, 够 ARP/ICMP/IGMP)
- DHCP_FRAME [384..511] (DHCP 消息 300B = 75 字, 加 IP+UDP 7 字 = 82 字; 384+82=466 < 512 ✓)
- TX_UDP     [512..767] (256 字 = 1024B, 容纳 576B 大帧 + 头部)

DHCP_FRAME_BASE = TX_SCRATCH_BASE + 32 → 用新的 TX_SCRATCH_BASE=320 算出 = 352, 但
DHCP 需要 82 字 → 352+82=434 > 383 越界。改 DHCP_FRAME_BASE 显式 = 384 (避开 TX_SCRATCH)。


### 实测 (第一阶段#2, 768 分区后)
- ping 4/4 PASS (ICMP 工作)
- UDP echo 0/3 FAIL (timeout — 完全无响应!)
- TCP 25B/1608B 完全连不上 (SYN 无响应)
- UART console `?mac/?ip/?stat/?net` 全部正常 — FPGA 运行中, RX/TX 计数都在动
- ARP 工作 (PC ARP 表有 192.168.100.2 → 00:0A:35:01:FE:C0)
- 链路 1G OK

**核心矛盾**: ICMP 工作但 UDP/TCP 完全无响应。说明:
- MAC RX/TX、IP RX/ICMP、ARP、UART 都 OK
- UDP 或 TCP 子系统被本次改动破坏

**候选根因**:
1. udp_rx_process 的 dst_port 校验时 buf_base 指向错位置 → 读到错误 dst_port → filter 失败
2. udp_echo copy 循环把数据写到错误位置 → 上层后续读到错的 UDP payload
3. tx_req 从 udp_tx_process 发出后 buffer[hdr_base + i] 写错位置 (TX_UDP_BASE=512, buf_len=IP_HEADER_BYTES+tx_data_len = 20+28=48 bytes = 12 words, 写到 buffer[512..523])

**疑点**: ICMP echo 也是从 buffer[icmp_base+5] 读、写到 TX_SCRATCH_BASE, 然后 mac_tx_process 从 TX_SCRATCH_BASE 发出 — 这条路径没问题。
UDP 路径差异: echo copy 在 udp_echo.cpp 主循环里, 读 buffer[rx_pbase..rx_pbase+pw] 写到 buffer[tx_pbase..tx_pbase+pw], 然后 udp_tx_process 从 buffer[TX_UDP_BASE..+7] 读 IP/UDP 头, 从 TX_UDP_BASE+7 起是 payload (echo copy 写入)。

**假设 1**: 虽然 buf_base 逻辑对了, 但 mac_rx_process 里 rx.buf_base 赋值时 rx_buf_sel 已经被 toggle 了 → 错 buffer!
看 layer_mac.cpp PAYLOAD end: `rx.buf_base = rx_buf_sel ? BUF_B_BASE : BUF_A_BASE; rx_buf_sel = !rx_buf_sel;` — 赋值在 toggle 前 ✓ 顺序对.

**假设 2**: 双缓冲 FIFO 存了 mac_rx (含 buf_base), 但 pop 时用了 stale buf_base → proc_rx 的 buf_base 指向 BUF_B 但 buffer 实际数据在 BUF_A — 这是可能的! 当 mac_rx.valid 到来时 mac_tx_busy, push 到 FIFO (含 buf_base); 下一个 frame 到达时 rx_buf_sel 已切换, 新 frame 写到新 BUF; FIFO pop 出旧 mac_rx, ip_rx_process 用旧 buf_base 读 — 但旧 BUF 已被新 frame 覆盖 (如果新 frame 用同一个 BUF) — 不会, 双缓冲交替用.
  但如果 FIFO 里有 2 个 entry (BUF_A + BUF_B 都满), 第 3 个 frame 来会写回 BUF_A → FIFO[0] (buf_base=A) 读到的是新数据.

**假设 3**: 新分区下 DHCP_TX (在 tx_req.request 的空隙) 用 DHCP_FRAME_BASE=384 写 buffer, 如果 DHCP 与 RX BUF_A 在同一时间被访问, 会不会时序竞争?
  DHCP_FRAME_BASE=384 在 [384..511] 独立区, 不冲突.

**下一步**:
- 在 udp_rx_process 里加统计计数器, 看看到底有没有收到 dst_port=8080 的 UDP 包
- 用 pktmon 抓包验证 FPGA 是否真没回
- 或直接反汇编生成的 Verilog, 找 buffer 地址总线是否真的支持 768 字

---

## 2026-08-22 深夜 — 双缓冲回归根因破案: ap_uint<9> 地址位宽截断 (TL 修复)

### 现象 (768 分区后)
- ping 4/4 PASS, 但 UDP echo 0/3 全 FAIL, TCP SYN 无响应, ARP/ICMP/UART/链路全正常
- "ICMP 通但 UDP/TCP 全挂" 这个组合是关键线索

### 根因 (TL 锁定)
agent 把 TX_UDP_BASE 挪到 512 (768 分区), 但**全工程 buffer 地址字段是 ap_uint<9> (最大 511)**:
- `mac_tx_process` 的 `req_wbase` (ap_uint<9>) 接收 `tx_req.buf_addr = TX_UDP_BASE = 512`
- 512 = 0b1000000000 需 10 bit → ap_uint<9> 截断成 **0**
- mac_tx 从 buffer[0] (RX BUF_A) 而非 buffer[512] 读 → 发出 RX 帧垃圾 → UDP/TCP 全废
- **ICMP 用 TX_SCRATCH_BASE=320 (<512 装得下) 所以正常** — 完美解释组合现象

### 修复 (TL 直接改, 6 处 ap_uint<9> → ap_uint<10>)
- eth_types.h: udp_rx_t.buf_base (其余 buf_base/buf_addr agent 已改 10)
- layer_mac.cpp: buf_wr_addr / buf_limit / req_wbase
- layer_ip.cpp: base; layer_arp.cpp: base
- grep 确认无 ap_uint<9> 残留

### 教训
- 改 buffer 分区地址时**必须同步检查所有地址字段/变量的位宽** (BUFFER_DEPTH 512→768 需 9→10 bit)
- "部分协议通、部分不通"时, 按各协议用的地址区间对比最快定位 (ICMP=320 通 / UDP=512 不通 → 512 溢出)

### 第二阶段修复 (TL): 移除 4-FIFO, frame_done 当拍立即处理
位宽修复后 ping/UDP/25B PASS, 但 1608/2000B 仍确定性 FAIL:
- 错@880 rx=45 00 02 40 (IP头 len=576) / 错@344 rx=45 00 00 28 (IP头 len=40)
- 反解: 回显里混入"另一段的 IP 头"。4-FIFO 只存元数据不存 payload,
  双缓冲只保护 1 帧; 4 段突发时 FIFO 积压, 弹出时其 buf_base 指向的 BUF
  已被"隔一帧"的新段覆盖 (S2→BUF_B, S4 也→BUF_B 覆盖 S2)。
- 修复: 移除 4-FIFO, mac_rx.valid 当拍立即处理。TCP 数据路走 tcp_queue
  (payload 立即拷入独立 tcp_send_bufs BRAM, busy 安全, 不碰共享 TX 区),
  payload 在 frame_done 当拍就被提走, 下一帧 (>=22 pass) 来不及覆盖。

### 2000B 真根因破案 (TL): layer_tcp.cpp payload 读取 `uint8_t wi` 溢出
移除 FIFO 后 1608/2000B 仍同样错@344/880 (rx=45 00 .. = IP头)。逐位反解:
- payload 读循环 `uint8_t wi = ps+(i>>2)`, ps=tb+doff=buf_base+10
- **BUF_B 时 ps=170, i=344 → wi=256 → uint8_t 回绕成 0** → 读 buf[0]=BUF_A 里
  刚到的帧的 IP 头 → 回显混入 IP 头。错误固定在 wi 首次溢出处(344), 值总是 IP 头。
- 单缓冲时代 buf_base=0, ps=10, wi<=153 不溢出 — 这是启用双缓冲引入的**第二处**
  "窄类型假设 buf_base=0" bug (与 ap_uint<9 同类)。
- 修复: `uint8_t wi` → `uint16_t wi` (layer_tcp.cpp:336)。

### 进展: 1608B PASS! 2000B 进到第4段移位竞态
uint8_t wi 修复后板测:
- ping/UDP 64/512/TCP 25B/**1608B 全 PASS**
- 2000B 仍 FAIL 但错误模式质变: @1722-1723 (第4段内偏移114), **每次漂移**,
  rx 变成 payload 乱序/移位 (不再是 IP头) → 读路径修好, 剩第4段移位竞态
- 即原先记载的 1726 竞态 (buffer[39] 同周期读写移位, HLS 调度非确定)

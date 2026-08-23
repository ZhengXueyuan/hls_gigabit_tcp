# 03 候选架构头脑风暴: 10G 纯硬件 TCP/IP 协议栈 (2026-08-23)

> 输入: 01 现状分析 (单 FSM 必废, 协议语义资产可复用) + 02 行业调研 (K7 资源绰绰有余,
> fast/slow path 是 TOE 核心结构)。本阶段只读, 未改任何代码。本地核查: DEMO 工程 + R3 原理图。

---

## 1. 板上 10G 可行性核查 (本地检查)

### 1.1 DEMO k719-k727 结论: **没有现成 10G 以太网工程**

- `k724_sfp1_gtx_10g_test` / `k725_sfp2_gtx_10g_test` / `k727_sfp12_gtx_10g` 均为 **GT Wizard 3.6 裸收发器回环例程** (frame_gen/frame_check + ILA), 无 10GBASE-R PCS、无以太网 MAC/组帧, 不能直接复用为网口。
- 关键证据 (k724 `gtwizard_0.xci`): QPLL FB_DIV=80 × 板载 125MHz → **QPLL VCO 10.0GHz, 线速率 = 非标 10.0Gbps** (数据宽 40bit@250MHz)。10GBASE-R 线速是 10.3125Gbps, **125MHz 参考钟整数倍出不来 10.3125** → 该"10G 工程"与真实 10G 以太网对端**无法互通**, 只证明 GTX 通道电气与回环可用。
- 全 DEMO 目录 grep 无 `axi_10g_ethernet` / `pcs_pma` / `xgmii` / `eth_mac_10g` 等 10G MAC/PCS IP; k719-721 均为 RGMII 1G 铜口。

### 1.2 硬件: SFP+ 笼与 GTX bank (原理图 R3 + k724-727 XDC)

- 两个 SFP+ 笼都在 **GTX quad 116 (Q0)**: SFP1 → GTXE2 X0Y0 (RXP=G4), SFP2 → X0Y1 (RXP=E4); TX_DIS=H23/H24; 另有 SFP_LOSS1/2、SFP_RAT_S1/2 (原理图 p11)。
- **唯一 GT 参考钟 = MGTREFCLK0_116 (D6/D5)**, 出厂 125MHz (SYS_CLK_125M)。原理图 p6 注释与 `数据手册/关于光通信晶振说明.txt` 明示: "光口万兆需将晶振更换为 **156.25MHz, 推荐 SIT9120AI-2B3-33E156.25**"。
- 原理图另列 MGTREFCLK1_116 (F5/F6) 与 quad 115 (H5/H6、K5/K6) 输入引脚 — 是否布线需人工复核原理图, 默认视为未接。

### 1.3 PLL 数学: 10GBASE-R 的前提

- 10.3125Gbps 只能走 **QPLL** (GTX CPLL 上限 ~6.6Gbps 不可用); GTX QPLL range 2 = 9.8-12.5GHz, XC7K325T-2 生产片支持 10.3125GHz VCO。
- 156.25MHz × FB66 = **10.3125GHz ✓** (标准做法, PG157 路径); 125MHz × FB80 = 10.0GHz ✗ 非以太网。
- **结论: 不换晶振 (或找到其他 156.25MHz 源) 则板上 10GBASE-R 物理不可达** — 这是本计划第一个前置决策。

### 1.4 自建 10G 链路所需 (PG157 路径)

- IP: AXI 10-Gigabit Ethernet Subsystem (PG157, 10G MAC + 10GBASE-R PCS/PMA, 官方支持 K7; 客户端 64bit AXI-Stream @156.25MHz; PCS/PMA 无 MDIO ~2.2-2.7K LUT, 子系统量级 8-15K LUT)。
- XDC 要素: ① 156.25MHz 差分参考钟 → MGTREFCLK0P/N_116 (D6/D5, 换晶振后), `create_clock -period 6.4`; ② SFP1 = X0Y0 (RXP G4/RXN G5, TXP F4/TXN F5), SFP2 = X0Y1 (RXP E4/E5), + TX_DIS/LOSS/RAT; ③ DRP_CLK G22 (LVCMOS33, 50MHz); ④ slow 域 125MHz 由系统钟 MMCM 派生。

---

## 2. 设计目标与硬指标

| 指标 | 数值 | 含义 |
|---|---|---|
| 线速 | 10.3125Gbps / 10G 净荷 | XGMII 64bit @156.25MHz = 8B/拍 |
| 64B 帧最坏 | 14.88Mpps = **67.2ns/帧 = 10.5 拍/帧** | 任何级 8 拍数据 + ≤2 拍常数开销 |
| 行情 UDP 延迟 | wire-to-wire ≤300ns (约 3 级流水) | 参考 Silicom 455ns |
| TCP 数据段延迟 | ≤1μs | 小包高频, 每包固定延迟优先 |
| 连接 | TCP 16 条长连接 + 64 组播组过滤 | 有限连接免查表 |
| 资源上限 | ≤60K LUT / ≤100 BRAM (18%/22%) | 326,080 LUT 器件 |
| 时序 | 全数据面 156.25MHz | 每级逻辑 ≤2-3 级 LUT 深 |

**无瓶颈周期算术 (对任何候选的裁决标准)**: 10G 净荷 10Gbps = 64b@156.25MHz 每拍 1 个 64bit 字。64B 帧 = 8 拍数据 + preamble/IFG 折算 10.5 拍预算, **任何"整包暂存再串行处理"的级都不达标; 只允许逐级 II=1 直通**。各口弹性缓冲: 级间 FIFO 16 深 (覆盖背压抖动 ≤4 拍 × 4B/拍·等效); GTX USRCLK 161.13MHz↔XGMII 156.25MHz 跨域 8 深 (速率差 3.1%, 微幅填放); 慢路径 FIFO 2048×64b (容纳 24 个 64B 慢帧突发, 溢出丢整帧可自愈); app 输出缓冲 = 下游节流响应时间 × 线速 (行情 4KB×8 通道 ≈ 9 BRAM36)。"IP 栈读速相对 PHY/MAC 无瓶颈"的含义: MAC 每拍喂 1 字, 分类/分流/校验和全部每帧 O(1) 常数, 不随帧长增长 — 只有 TCP 重传缓冲与 app 环形缓冲按 RTT×BW 线性增长, 但那是内存不是处理带宽。

---

## 3. 候选架构

### A) HLS 演进式: 全 HLS, hls::stream + DATAFLOW + 64bit 加宽重写

```
        ┌──────────────────────── 156.25MHz 数据面 (HLS DATAFLOW 进程) ────────────────────────┐
MAC RX ─► MAC解析(8B/cyc) ─► 分类/头校验和 ─► UDP组播直通─► app AXIS (零暂存)
(64b)  └──────────────────────────► TCP引擎(HLS) ──► TX仲裁 ──► MAC TX(64b)
                                      │慢路径协议(HLS ap_ctrl_hs) ← 125MHz 域, AXIS CDC FIFO
```

1. **框图**: 标准 UG1399 DATAFLOW: MAC RX 解析进程 (8B/cyc) → 分类进程 → UDP 直通进程 / TCP 引擎进程 → TX 仲裁 → MAC TX; slow 进程经 hls::stream (对应 RTL 为 AXIS CDC FIFO) 跨域。ap_ctrl_hs 主时钟 156.25MHz。
2. **周期算术**: UDP 旁路各进程 II=1 可达: 8 拍数据 + 2-3 拍常数 = ~10-11 拍/帧, 压线 10.5 拍预算 — 但 TCP 引擎进程含"RX 更新 TCB + 等 app 数据 + TX 组装"回环, 2 个 64B 帧同时在场即破预算; 整帧拷贝循环 (现在 TCP 的 3-4 遍) 全部不允许, 必须改元数据流 + payload 直通。
3. **fast/slow**: 划分原则同 B; slow 仍是 HLS 模块, 无独立时钟域 (同源), 靠 DATAFLOW 握手隔离。
4. **连接模型**: TCB 16×256bit BRAM, HLS 动态索引读改写 — 综合成 LUTRAM/BRAM 双口, 单周期可做但宽位选在 156.25MHz 有风险。
5. **app 接口**: hls::stream 转 AXIS 由 wrapper 桥接, 环形缓冲/doorbell 在 wrapper。
6. **资源**: 数据面 ~15-30K LUT + 慢路径复用现有代码; 但 csynth 已见 `tcp_rx_process` slack -0.53ns (171MHz 估算), 156.25MHz 收敛无保证。
7. **风险**: ① TCP 数据面 156.25MHz 收敛 (01 已有违例预兆) — 规避: TCP 引擎只做控制面, 数据搬移独立 64bit 流; ② DATAFLOW 握手 bubble 与共享 BRAM 端口冲突 → 私有化/分区 + FIFO 深度验证; ③ csim≠RTL, 宽位流控调试慢 → 强制 xsim 逐级比对。

### B) RTL fast path + HLS 慢路径混合 (预期主推)

```
          GTX X0Y0 @10.3125G ── 10G PCS/PMA (BASE-R) ── 10G MAC (PG157, 64b AXIS)
                                   │                                              │
          RX 数据面 (156.25MHz, 全 RTL, 5 级流水, 每级 II=1)                     │
 MAC ─► ①解析+CRC校验 ─► ②头解析/校验和(CSA) ─► ③分流(5-tuple 微型CAM 16项) ─┐   │
          ┌───────────────────────────────────────────────┴──────────────┐      │
          ▼ UDP组播命中                                                     │      │
  app RX AXIS 直出 (组播组过滤, 零暂存, ≤3级)                              │      │
          │                                                                │      │
          ▼ TCP 命中 (已建立连接数据段)                                     │      │
  TCB 读改写(seq/ack/窗口, BRAM 16×256b 单周期) ─► payload→app RX FIFO      │      │
          │                                                                │      │
          ▼ 其余 (ARP/DHCP/ICMP/IGMP/握手/RST/未知)                         │      │
  AXIS CDC FIFO ───────► 慢路径 (125MHz): 现有 HLS 协议层移植 (ap_ctrl_hs,  │      │
                          BRAM mailbox 交换帧 + TCB 命令/事件队列) ◄───────┘      │
 TX 方向: app TX ─► TSO/分段+增量校验和(CSA) ─► TX 仲裁 ─► MAC TX ─► PCS/PMA ◄──┘
```

1. **框图**: 如上。时钟域: fast 156.25MHz (数据面) 与 slow 125MHz (协议引擎) 间仅经 3 种接口 — RX 慢帧 FIFO (AXIS CDC)、TX 慢帧 FIFO、TCB 命令/事件 mailbox (BRAM 双口 + 同步逻辑, 事件率 ≤1 次/μs 级)。三处均无高频握手。
2. **周期算术**: ①-③ 级每级 1 拍/字: 64B 帧数据 8 拍, 各常数级 ≤2 拍 → SOP-to-EOP ≈ 10-12 拍 (64-77ns); + MAC/PCS 固定 ~67ns → wire-to-wire ~300ns 达标。TCP 数据段: 解析 (2 拍) → TCB 读改写+校验 (2 拍, 无回环) → payload 直通, 每帧 ~12 拍, 与 UDP 同级。stall 数学: 级间 16 深 FIFO 吸收任意 2 拍背压 × 8B; 唯一长 stall 源 = app 输出背压, 由接口合同约束 (行情下游引擎节流响应 ≤ 4KB/通道 缓冲); 慢路径分流即使阻塞 100 拍也只影响被堵那 1 帧 (其自身就是慢帧, 可丢可缓), 数据面其余流量不受牵连 — 这是"相对 PHY/MAC 无瓶颈"的结构性证明。
3. **fast/slow 划分**: fast = 已建立 TCP 连接纯数据段 (seq 连续或乱序入缓冲) + 全部 UDP 组播命中 (只校验 + 过滤 + 直出, **零等待**); slow = ARP/DHCP/ICMP/IGMP/广播未知帧 + TCP SYN/FIN/RST + 重传/零窗口探测/RTO 超时处理 + 连接管理。慢路径实现选型: **移植现有 HLS 层** (layer_arp/icmp/igmp/dhcp/tcp 状态机, 已板级验证, 语义资产 02 已列), 编译为 ap_ctrl_hs 独立模块跑 125MHz, 每事件 100-1000 拍无感; 不引 MicroBlaze (见 D 对比)。mailbox 协议: 慢路径写命令槽 (连接号+事件码+指针), fast path 空闲拍读槽执行 (TCB 改写/重传注入 TX), 事件返回同 mailbox; 优先级: fast 数据 > mailbox > 慢帧。
4. **连接模型**: 16 TCB × 256bit, 固定槽位索引 (微型 CAM: 16×104bit 键 = 4×IP+2×端口+协议, 全展开 LUT 比较器, 1 拍出槽号, ~2K LUT); 寄存器版 (16×256 FF, 免 BRAM 仲裁) vs BRAM 版 (1 个 BRAM36, 单周期读改写但需双口仲裁) — **裁决: 寄存器版** (16×256bit = 4K FF, 资源可忽略, 免仲裁延迟更可预测); 数据缓冲 (重传/乱序) 用 BRAM FIFO。RTO/重传定时: 慢路径 1ms tick 扫描 16 槽, 事件化注入 TX — 毫秒级, 与数据面零耦合。
5. **app 接口**: 上行 (RX) = 行情组播组过滤后**直出 AXIS** (TLAST/TKEEP/每帧首字带组号元数据旁路); TCP RX = 每连接 AXIS FIFO + 事件中断 (数据到达/断开); 下行 (TX) = app 写 **BRAM 环形缓冲 + doorbell 寄存器**, 数据面 TSO 分段 + 增量校验和 (CSA 树单周期) + 头组装, **partial packet assembly** (app 只填 payload/关键字段, 硬件组头) — 交易小包固定延迟由此保证。缓冲: 16 连接 × RTT×BW (局域网 RTT 10μs × 10G = 12.5KB/连接 → 4 段 × 1500B 环深, 8KB×16 = 16 BRAM36)。
6. **资源**: PG157 8-15K + 解析/分流/CAM 3-6K + 校验和 CSA 2-4K + TCB/定时器 1-2K + 数据面 FIFO/环形缓冲 20-40 BRAM + 慢路径 HLS 移植 10-15K LUT/10 BRAM + app 接口 2-4K → **合计 ~30-45K LUT (~13%), 40-70 BRAM (~15%)**, 16 GTX 用 1 个。时序: 各级 ≤2-3 级 LUT, 156.25MHz (6.4ns) 在 K7-2 无压力; 唯一注意 CSA 树 3 级寄存器打拍。
7. **风险**: ① 晶振/物理层 (见 1.3) — 规避: 第一阶段前置验证, 失败则整体降级 1G+新架构 (收益保留); ② fast/slow 接口死锁 (mailbox 满、慢帧 FIFO 满) — 规避: 满则丢整帧+计数, 控制面丢帧协议自愈; ③ TCP 重传语义在 fast 与 slow 间分工错位 — 规避: 重传缓冲归属 fast 数据面, slow 只发"事件命令", 单一状态源 = TCB。

### C) 全 RTL TOE: 连 TCP 状态机也手写 RTL

- 数据面与 B 相同; 差异 = 慢路径不用 HLS, TCP 状态机/重传/RTO/ARP/ICMP/DHCP 全手写 Verilog, 125MHz 域, 结构与 fpga-network-stack 的 State Table + Event Engine 同构。
1. **框图**: 同 B, 慢路径方块换 RTL (session lookup 直接合并进 TCB 槽)。
2. **周期算术**: 同 B (数据面一致); slow 侧 RTL 状态机每事件 ≤几十拍, 无差。
3. **fast/slow**: 同 B; 慢路径事件引擎 (RTO/探测/关闭 3 定时器 + 事件队列) 全 RTL。
4. **连接模型**: 同 B; 全部寄存器化, 无 HLS 中间层。
5. **app 接口**: 同 B。
6. **资源**: 慢路径 RTL 比 HLS 版少 ~5K LUT, 但开发量 +2-4 周。
7. **风险**: ① TCP 状态机 RTL 手写错一态即难查 (验证成本高) — 现有 HLS 层已板级 7/7 验证, 弃之可惜; ② 无资产复用, 周期拉长; ③ 协议演进 (加 PTP/窗口缩放) 每项都改 RTL。裁决: 可作 B 的 Plan-B, 不首推。

### D) 软核中心: MicroBlaze 协议引擎 + RTL 加速器

- 数据面同 B (RTL 分流/校验和/TCB 加速器); 慢路径改用 MicroBlaze (125MHz, BRAM 程序, AXI 总线接 mailbox/寄存器 + 软件 TCP 状态机/ARP/DHCP)。
1. **框图**: 同 B, 慢路径方块 = MB + AXI 互连 + 加速器寄存器接口; 软硬件经 AXI-Lite 寄存器 + 中断。
2. **周期算术**: 数据面不变; 慢事件响应 1-10μs (软件路径), 对握手/重传 (ms 级) 无感 — 达标; 但 MB 启动/复位/看门狗增加板级状态复杂度。
3. **fast/slow**: 同 B; slow 全软件。
4. **连接模型**: 加速器寄存器化 TCB 归 RTL 管 (软件只发命令) — 与 B 同, 软件不可见数据面内部。
5. **app 接口**: 同 B。
6. **资源**: MB+AXI ~2-4K LUT + 128KB 程序/堆栈 BRAM ≈ 36-45 BRAM, 比 HLS 慢路径贵 (BRAM 多 3×)。
7. **风险**: ① 软件路径抖动与死循环风险, 交易场景信任度低 — 慢路径可接受但调试面大; ② 工具链 + AXI 基础设施学习/验证成本; ③ 两个"世界" (RTL 数据面 + 软件控制面) 的同步契约更复杂。裁决: 慢路径用已验证 HLS 层是更短路径; MB 仅在 HLS 移植受阻时启用。

---

## 4. 对比表

| 维度 | A 全 HLS | **B RTL fast + HLS slow** | C 全 RTL | D MB + RTL |
|---|---|---|---|---|
| 数据面线速达标 | 存疑 (TCP 156.25MHz 收敛) | ✓ 结构保证 | ✓ | ✓ |
| 延迟确定性 | 中 (DATAFLOW bubble) | 高 (固定流水) | 高 | 中 (仅慢路径受影响) |
| 资产复用 (现有 HLS 层) | 需宽位重写 | **慢路径原样移植** | 弃 | 弃 |
| 开发量 (人天) | ~50-70 + 收敛风险 | **~40-60** | ~60-90 | ~60-90 |
| 主要风险 | 时序收敛/csim≠RTL | 物理层晶振 | 状态机验证成本 | 软硬契约/BRAM 占用 |
| 资源 | ~30-50K LUT | ~30-45K LUT / 40-70 BRAM | ~25-40K | ~35-50K / 80-110 BRAM |

## 5. HLS vs RTL 模块裁决表 (标准: 156.25MHz 时序 / 延迟可预测 / 开发速度 / 已验证资产复用)

| 模块 | 裁决 | 一句话理由 |
|---|---|---|
| 10G MAC/PCS (PG157) | RTL (官方 IP) | 物理层无 HLS 空间 |
| MAC RX/TX 帧格式 (64bit) | RTL | 现 HLS 逻辑 1:1 翻译, 宽位流控 RTL 更可控; 语义资产 (CRC LSB-first/VLAN/46B padding) 复用 |
| 头解析/分类/5-tuple 分流 | RTL | 1-2 拍常数, 延迟可预测; HLS 动态索引宽位选在 156.25MHz 无把握 |
| 校验和 (RX 验证/TX 生成+增量) | RTL (CSA 树) | 单周期必须 (Limago 教训: HLS 延迟不达标) |
| UDP 组播 fast path | RTL | 无状态直通, 3 级内完成, 300ns 目标依赖它 |
| TCB/seq-ack/重传缓冲 | RTL | 16×256bit 寄存器 + BRAM FIFO, 单周期确定性 |
| TCP slow path (握手/重传策略/RTO/连接管理) | **HLS 移植** | layer_tcp.cpp 已板级验证; ms 级时序, 125MHz 域, HLS 天然胜任 |
| ARP/ICMP/IGMP/DHCP | **HLS 移植** | 低速率事件型, 现有代码零重写 |
| TSO/分段+增量校验和 (TX) | RTL | 数据面频率要求, HLS 仅可做慢速控制侧 |
| App 接口 (AXIS 直出/环形缓冲+doorbell) | RTL | 数据面直通 + 简单状态机 |
| 跨域 mailbox/CDC FIFO | RTL | 标准原语, 薄封装 |

## 6. 推荐方案

**主推: B — 纯 RTL 64bit 数据面流水 (PG157 10G MAC/PCS + 解析/校验和/TCB/分流/旁路全 RTL) + 慢路径复用现有 HLS 协议层 (ARP/ICMP/IGMP/DHCP/TCP 握手/重传/RTO, ap_ctrl_hs @125MHz), 两者仅经 AXIS CDC FIFO + BRAM mailbox 解耦。**

3 个关键设计决策:
1. **数据面全 RTL、每级 II=1、帧内零整包暂存**: 64bit@156.25MHz, 64B 帧 10.5 拍预算, 分类/校验/TCB 全部 O(1) 常数级; 任何级不得出现整帧串行循环。
2. **慢路径 = 现有 HLS 层原样移植 + 显式 mailbox 接口**: 快慢只交换"帧/命令/事件"三类消息, TCB 是唯一状态源且归属 fast 数据面; RTO/重传由慢路径事件化注入, 与线速零耦合。
3. **物理层前置**: 换 156.25MHz 晶振 (SIT9120AI-2B3-33E156.25) 后走 PG157 自建 10G MAC+BASE-R PCS/PMA (GTX X0Y0 @10.3125Gbps); 此项不通过则整体降级为 1G RGMII + 同一新架构 (收益不变, 带宽减 10×)。

## 7. 分阶段施工路径 (每阶段可验证里程碑)

| 阶段 | 内容 | 验证手段 | 人天 |
|---|---|---|---|
| P0 物理层 | 换 156.25MHz 晶振 → 自建 PG157 IP (10G MAC+PCS, X0Y0), 修 XDC; 先用 GTX 回环 | 板级 ILA (TX/RX data 比对), 无对端 | 5-8 |
| P1 MAC/PCS bring-up | 光纤 SFP+ 环回线缆回环; RX CRC 校验 + 统计; 帧计数/误码 | xsim + 板上 ILA + 环回计数 | 3-5 |
| P2 UDP fast path | RX: 解析→组播过滤→AXIS 直出; TX: app 帧→校验和/组帧→MAC; 带背压与丢帧计数 | xsim; 板上对端 PC 压测 (iperf3-U 10G 网卡或 Python 大突发), ILA 抓帧首延迟 | 5-10 |
| P3 TCP fast path 数据段 | 微型 CAM 分流 + 寄存器 TCB (seq/ack/窗口) + payload FIFO + ACK 生成; RX/TX 双方向 | xsim 脚本化 5-tuple 用例; 对端 TCP 吞吐+延迟测量 | 8-12 |
| P4 slow path 补齐 | 现有 HLS 层移植为独立 IP + mailbox/CDC FIFO; 握手 (SYN/SYNACK/ACK)、ARP、ICMP ping、DHCP | xsim 全流程; 板上 ping/TCP 建连 7/7 回归 (py_net_test.py 模式) | 10-15 |
| P5 app 接口集成 | 行情 AXIS 组播分发 + 环形缓冲/doorbell + 事件; TSO/增量校验和; 全链路压测 (64B 14.88Mpps 仿真 + 板上实测) | xsim + 板上 ILA + 对端压测; 延迟计数器 (SOP-to-SOP) | 5-10 |

合计 ~40-60 人天。P2 结束即达成"行情 UDP 线速不丢包"这一可独立交付的里程碑; P3 结束达成"TCP 数据面亚微秒"; P4 结束功能全通 (与现状 7/7 对齐的 10G 版)。

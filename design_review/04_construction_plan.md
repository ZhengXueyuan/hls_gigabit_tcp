# 04 10G 纯硬件 TCP/IP 协议栈 — 调查结论与施工计划 (2026-08-23)

> 本文件是设计审查阶段的**总纲与施工计划** (三份分报告的汇总: `01_current_analysis.md` 现状审查 /
> `02_industry_survey.md` 行业调研 / `03_candidate_architectures.md` 候选架构)。
> 状态: **施工已启动 (2026-08-23, 用户拍板: 1G 先行 / 10G-ready)** — 前置决策见 §6。

---

## 1. 目标与硬指标

**终局目标**: 10G 以太网上纯硬件 TCP/IP 协议栈, 支撑低延时行情 (UDP 组播市场数据, 线速不丢包)
与交易 (TCP 少量长连接 4-16 条, 小包高频, 亚微秒级固定延迟); 对上层应用提供 TCP/UDP 调用接口。
**核心设计要求: IP 栈读速相对 PHY/MAC 完全无瓶颈。**

| 指标 | 数值 | 含义 |
|---|---|---|
| 线速 | 10.3125Gbps (10GBASE-R) | XGMII 64bit @156.25MHz = 8B/拍 |
| 64B 帧最坏 | 14.88Mpps = 67.2ns/帧 = 10.5 拍/帧 | 任何流水级只允许 II=1 直通 |
| 行情 UDP 延迟 | wire-to-wire ≤300ns | 商业参照 Silicom 455ns |
| TCP 数据段延迟 | ≤1μs (小包固定延迟优先) | 交易路径, 不用 LRO |
| 连接规模 | TCP 16 长连接 + 64 组播组过滤 | 有限连接免查表 |
| 资源上限 | ≤60K LUT / ≤100 BRAM (18%/22%) | 326,080 LUT 器件 |
| 时序 | 数据面全 156.25MHz | 每级 ≤2-3 级 LUT 深 |

## 2. 现状审查结论 (01)

**数字**: RX 排空实测 1 字节/21-28 拍双峰, 全程平均 ~30 拍/字节 ≈ 33Mbps (1G 线速的 3-5%);
每 pass 固定开销 ~20 拍 (33 状态顺序遍历 + 每 pass 串行调 6+ 层函数 + 子模块握手);
帧完成 pass 叠加 600~3111 拍; **10G 需 10B/cyc@125MHz, 当前需提升 ~200-280 倍**。

**根因 = 架构形态, 不是协议逻辑**:
- ap_ctrl_none 单 FSM 串行 body — 调用间零重叠, 吞吐 = 1/body 总延迟, by construction 无并发
- 1 字节/pass RX 粒度 (layer_mac.cpp:67 每 pass 只 read 一次)
- RX/TX 同 FSM 互斥 — mac_tx 流式发送 600 拍期间 RX 完全停摆
- 帧内 3-4 遍重复拷贝 + 每帧 staging 375 拍固定开销
- 无 fast/slow path 划分, 所有帧全深度解析

**资产/负债**: 协议语义资产 (MAC 帧格式/CRC/FCS LSB-first、IP 解析校验和、ARP 表、TCP 状态机
+Reno+RTO、ICMP/IGMP/DHCP 构建) 全部板级 7/7 验证, **可移植复用**; 单 FSM 串行 body、1 字节
粒度、RX/TX 互斥、共享 buffer 多遍拷贝**必须整体废弃**。

**HLS 判决**: UDP 组播 fast path (无状态只读直通) 用 HLS DATAFLOW 加宽可达线速; **TCP 数据面
HLS 高风险** — 现状已有预兆: csynth 报告 `tcp_rx_process` slack -0.53ns 时序违例 (估算 171MHz)。

## 3. 行业调研结论 (02)

1. **资源完全可行**: 10G MAC+PCS (K7 用 PG157 + GTX, ~8-15K LUT) + 解析/查表/校验和流水
   (~10-20K LUT) + TCB/缓冲 (数十 BRAM36) 合计 <15% LUT, 16 个 GTX 只用 1-2 个。
2. **架构范式必须切换**: 开源标杆 (Corundum / verilog-ethernet / Limago) 全是 64bit@156.25MHz
   多级流水; Limago 连单周期校验和 (CSA 7-3 树) 都因 HLS 延迟不达标而手写 — 数据面建议纯 RTL。
3. **fast/slow path 是商业 TOE 核心结构**: 线速路径 = 解析→查表→增量校验和→TCB 推进; 握手/重传/
   RTO/ARP/ICMP/DHCP 全放慢时钟域经 BRAM mailbox 解耦 (Design Gateway TOE、VNP4 三时钟域同思路);
   RTO 毫秒级, 慢扫 16 槽完全可行。
4. **有限连接 TCB 开销可忽略**: 16×256bit 状态字寄存器化, 免查表免仲裁; 5-tuple 分流用微型 CAM。
5. **延迟目标有商业参照**: Silicom 实测 UDP→逻辑→TCP 转发 455ns wire-to-wire; 交易 TCP 用
   "预组装 + partial packet" 压小包固定延迟 — 亚微秒目标硬件上已有人做到。

## 4. 候选架构对比 (03)

| 维度 | A 全 HLS | **B RTL fast + HLS slow (主推)** | C 全 RTL | D MicroBlaze+RTL |
|---|---|---|---|---|
| 数据面线速达标 | 存疑 (TCP 156.25MHz 收敛风险) | ✓ 结构保证 | ✓ | ✓ |
| 延迟确定性 | 中 (DATAFLOW bubble) | 高 (固定流水) | 高 | 中 |
| 现有 HLS 层资产复用 | 需宽位重写 | **慢路径原样移植** | 弃 | 弃 |
| 开发量 (人天) | ~50-70 + 收敛风险 | **~40-60** | ~60-90 | ~60-90 |
| 主要风险 | 时序收敛/csim≠RTL | 物理层晶振 | 状态机验证成本 | 软硬契约/BRAM |

HLS vs RTL 模块裁决 (标准: 156.25MHz 时序 / 延迟可预测 / 开发速度 / 资产复用):
**RTL** = MAC 帧格式 (64bit)、头解析/分类/5-tuple 分流、校验和 (CSA 树单周期)、UDP 组播旁路、
TCB/seq-ack/重传缓冲、TSO/增量校验和、app 接口、CDC 原语;
**HLS 移植** = TCP 慢路径 (握手/重传策略/RTO)、ARP/ICMP/IGMP/DHCP (现有代码板级已验证, 125MHz 域 HLS 天然胜任)。

## 5. 选定架构: B — RTL fast path + HLS 慢路径混合

```
         GTX X0Y0 @10.3125G ── 10G PCS/PMA (BASE-R) ── 10G MAC (PG157, 64b AXIS)
                                  │
         RX 数据面 (156.25MHz, 全 RTL, 5 级流水, 每级 II=1)
 MAC ─► ①解析+CRC校验 ─► ②头解析/校验和(CSA) ─► ③分流(5-tuple 微型CAM 16项)
         ├──► UDP 组播命中: app RX AXIS 直出 (零暂存, ≤3 级)
         ├──► TCP 命中 (已建连数据段): TCB 读改写(寄存器16×256b) ─► payload→app RX FIFO
         └──► 其余 (ARP/DHCP/ICMP/IGMP/握手/RST): AXIS CDC FIFO ─► 慢路径 (125MHz)
              现有 HLS 协议层移植 (ap_ctrl_hs), BRAM mailbox 交换帧+命令/事件 ◄────┐
 TX 方向: app TX ─► TSO/分段+增量校验和(CSA) ─► TX 仲裁 ─► MAC TX ─► PCS/PMA ◄────┘
```

**3 个关键设计决策**:
1. **数据面全 RTL、每级 II=1、帧内零整包暂存**: 64B 帧 10.5 拍预算, 分类/校验/TCB 全 O(1)
   常数级; TCP 数据段与 UDP 同速 (~12 拍/帧), wire-to-wire ≤300ns。
2. **慢路径 = 现有 HLS 层原样移植 + 显式 mailbox**: 快慢只交换"帧/命令/事件"三类消息;
   **TCB 是唯一状态源且归属 fast 数据面**; RTO/重传由慢路径事件化注入, 与线速零耦合。
3. **物理层后置 (2026-08-23 拍板: 1G 先行)**: 数据面先按 64bit 字流 @125MHz 在 1G RGMII 上
   建成并板级验证; 10G 升级 = 换 156.25MHz 晶振 + PG157 替换 1G 前端 + 提时钟 (P6, 流水线不改)。

**无瓶颈结构性证明**: MAC 每拍喂 1 字, ①-③级每级 1 拍/字, 常数级 ≤2 拍 → SOP-to-EOP 10-12 拍
(64-77ns); 级间 16 深 FIFO 吸收背压抖动; 唯一长 stall 源 = app 输出背压, 由接口合同约束
(行情 4KB×8 通道缓冲); 慢路径即使阻塞 100 拍也只影响被堵那 1 帧 (其自身就是慢帧, 可丢可缓),
数据面其余流量不受牵连。处理带宽不随帧长增长 — 只有重传/环形缓冲按 RTT×BW 线性增长 (那是内存)。

## 6. 前置决策 (阻塞项, 需用户拍板)

**板上 10G 物理层现状**: DEMO 内无现成 10GBASE-R 工程 (k724/k725/k727 是 125MHz×FB80=10.0Gbps
非标裸 GTX 回环, 与真实 10G 对端不互通); 两 SFP+ 笼在 GTX quad 116 (SFP1=X0Y0/G4, SFP2=X0Y1/E4);
唯一 GT 参考钟 MGTREFCLK0_116 (D6/D5) 出厂 125MHz, **125MHz 整数倍出不来 10.3125Gbps**。
原理图注释与《数据手册/关于光通信晶振说明.txt》明示: "光口万兆需将晶振更换为 **156.25MHz**,
推荐 **SIT9120AI-2B3-33E156.25**"。

**决策 (2026-08-23 用户拍板): 1G 先行、10G-ready** — 数据面统一 64bit 字流 @125MHz, 先在
1G RGMII 上建成并板级验证 (复用现有设施: py_net_test 回归 / ILA / pktmon / demo 对照);
晶振与 10G 物理层后置为可选 P6 (换 SIT9120AI-2B3-33E156.25 + PG157 后原位升级, 预计 8-15 人天)。

## 7. 分阶段施工计划 (~40-60 人天)

| 阶段 | 内容 | 验证手段 | 人天 | 里程碑意义 |
|---|---|---|---|---|
| **P0 数据面骨架 (1G)** | RGMII 1G 前端 (复用 wrapper_1g: MMCM 200M + util_gmii_to_rgmii) + 64bit 左对齐字流 MAC RX/TX (CRC 校验/剥离, 弹性 FIFO 背压, 帧边界丢帧) | xsim 逐字节比对 (多帧用例 × 3 背压模式) + 板上环回计数 | 5-8 | 10G-ready 字流接口与骨架成立 |
| **P1 MAC/PCS bring-up** | 光纤环回; RX CRC 校验 + 帧计数/误码统计 | xsim + 板上 ILA + 环回计数 | 3-5 | MAC 层线速成立 |
| **P2 UDP fast path** | RX: 解析→组播过滤→AXIS 直出; TX: app 帧→校验和/组帧→MAC; 背压与丢帧计数 | xsim; 对端 PC 压测 (10G 网卡 iperf3-U 或 Python 大突发); ILA 抓帧首延迟 | 5-10 | **行情 UDP 线速不丢包 (可独立交付)** |
| **P3 TCP fast path 数据段** | 微型 CAM + 寄存器 TCB (seq/ack/窗口) + payload FIFO + ACK 生成; RX/TX 双向 | xsim 5-tuple 脚本用例; 对端 TCP 吞吐+延迟测量 | 8-12 | **TCP 数据面亚微秒** |
| **P4 slow path 补齐** | 现有 HLS 层移植为独立 ap_ctrl_hs IP + mailbox/CDC FIFO; 握手/ARP/ICMP/DHCP | xsim 全流程; 板上 ping/TCP 建连回归 (py_net_test.py 模式) | 10-15 | 功能全通 (10G 版 7/7) |
| **P5 app 接口集成** | 行情 AXIS 组播分发 + 环形缓冲/doorbell + 事件; TSO/增量校验和; 全链路压测 | xsim + 板上 ILA + 对端 64B 14.88Mpps 压测; 延迟计数器 (SOP-to-SOP) | 5-10 | 终态交付 |
| **P6 10G 升级 (可选, 后置)** | 换 156.25MHz 晶振 + PG157 10G MAC/PCS 替换 1G 前端, 数据面时钟 125→156.25MHz | 板上 ILA + 对端 10G 压测 | 8-15 | 终局 10G |

**执行原则**: 每阶段独立可验证、可回退; 慢路径移植期间 1G 工程保持可用作为回归基线;
新工程建独立目录 (建议 `udp_hls_10g/`), 不动现有 `wrapper_1g.v` 生产位流。

## 8. 风险清单

| 风险 | 规避 |
|---|---|
| 晶振更换焊接失败 / 无 156.25MHz 源 | 决策 (b) 降级 1G+新架构, 收益保留; P0 最先验证 |
| fast/slow 接口死锁 (mailbox/慢帧 FIFO 满) | 满则丢整帧+计数, 控制面丢帧协议自愈 (TCP 重传/ARP 重试) |
| TCP 重传语义 fast/slow 分工错位 | 重传缓冲归属 fast 数据面, slow 只发事件命令; TCB 唯一状态源 |
| 156.25MHz 时序收敛 (CSA 树/宽位选) | CSA 树 3 级寄存打拍; TCB 寄存器化免 BRAM 仲裁; 每级 ≤2-3 级 LUT 深 |
| 验证盲区 (csim≠RTL 历史教训) | 数据面纯 RTL → xsim 全覆盖 + 板上 ILA 金标准, 不依赖 csim |

## 9. 现状工程处置

1G 工程 (`wrapper_1g.v` + HLS 栈, py_net_test 7/7 PASS) **冻结为回归基线**: 协议语义参照 +
板级对照实验工具; 不再投入新功能。10G 开发在新目录进行, 按 §7 阶段推进。

## 相关文件

- `01_current_analysis.md` — 现状周期账本与瓶颈定位 (每字节 ~30 拍的归因)
- `02_industry_survey.md` — 行业调研 (开源/商业方案、TOE 机制、资源量级, 附来源)
- `03_candidate_architectures.md` — 候选架构 A-D 详情、板上 10G 可行性核查、模块级 HLS/RTL 裁决

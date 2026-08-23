# 01 现状架构分析与周期账本（只读审查，2026-08-23）

> 依据：`src/*.cpp` 全部源码、`udp_echo_prj/solution1/syn/report/csynth.rpt`（2026-08-23 综合）、
> 生成的 RTL（`udp_echo_prj/solution1/syn/verilog/udp_echo.v`）、板级 ILA 捕获 `cap_fixed.csv`、
> ARCHITECTURE.md / RX_FIFO_OVERFLOW_ANALYSIS.md / PORT_NOTES.md。
> 本阶段未修改任何代码文件。

---

## 1. 现状架构速写

顶层 `udp_echo`（udp_echo.cpp:29）是 **ap_ctrl_none 自由运行的单体 FSM**：全部层函数经 `#include`
内联进一个翻译单元，综合为 **33 状态的顺序状态机**（RTL 中 `ap_CS_fsm_state1..33`），每 pass =
一次完整函数体顺序遍历，遍历完立即重启（无 start/done、无 idle）。csynth 报告顶层 `Pipelined: no`。

**每 pass 只能消费 1 个 RX 字节**：`mac_rx_process` 每 pass 只执行一次 `rx_stream.read()`
（layer_mac.cpp:67），该字节推进 MAC RX 状态机（IDLE→PREAMBLE→HEADER→[VLAN]→PAYLOAD）。
每 4 字节打包 1 个 32-bit 字推入 `frame_fifo`（512 深，udp_echo.cpp:55）。帧完成（`last` 标志）当拍
`mac_rx.valid` 置位，同 pass 内顶层把帧字 pop 到 `frame_buf[400]`（udp_echo.cpp:145 流水子模块，
II=1），随后按 ethertype→protocol 顺序调用各层解析函数，应答帧组进共享 `buffer[768]`（TX 专用），
`tx_req.request` 交给 MAC TX 状态机流式发送。所有层函数、所有流水子模块（staging、校验和、
拷贝循环）在同一 body 内**串行执行，调用间零重叠**。

---

## 2. 周期账本

### 2.1 基频：轮询 pass 长度（ILA 实测，cap_fixed.csv）

| 项目 | 拍数 | 证据 |
|---|---|---|
| 连续 2 次 RX pop 间隔 | **21 / 28 拍双峰**（492 次/576 次） | cap_fixed.csv 实测 rx_occ 下降沿 |
| 全程平均排空 | 1097 pop / 32768 拍 ≈ **30 拍/字节 ≈ 4.2MB/s ≈ 33Mbps** | cap_fixed.csv |
| 帧完成 pass 额外耗时 | +609 / +1092 / +3111 拍（3 个长间隔） | cap_fixed.csv |
| 文档口径 | ~1 字节/20 周期 ≈ 50Mbps | RX_FIFO_OVERFLOW_ANALYSIS.md:19 |

**轮询 pass 的 ~21-28 拍构成（全部为与数据量无关的固定开销）**：

| 组成部分 | 拍数 | 文件:行号 |
|---|---|---|
| mac_rx 读 1 字节（empty 检查 + 状态推进） | 2-3 | layer_mac.cpp:65-70 |
| mac_tx 每 pass 固定调用（空闲也走完 tx_busy/状态检查） | 3-5 | layer_mac.cpp:198-225（函数 latency 14） |
| dhcp_tx_process 每 pass 调用（timer++ 等） | 3-4 | layer_dhcp.cpp:205-209 |
| udp_tx_process 每 pass 调用（time_cnt++，几乎总早退） | 3-5 | layer_udp.cpp:125-134 |
| tcp_maintenance 每 pass 调用（检查队列/RTO） | 2-4 | layer_tcp.cpp:264-281 |
| stats_report 每 pass 调用 | 2-4 | layer_stats.cpp:25-27 |
| 顶层 FSM 顺序遍历 + 子模块 ap_start/ap_done 握手 | ~4-8 | udp_echo.v 状态链 1→…→33 |

### 2.2 帧处理（帧完成 pass 的增量，csynth 循环账目）

| 路径 | 子项 | 拍数 | 文件:行号 |
|---|---|---|---|
| 通用 | staging：frame_fifo→frame_buf | nwords×1（1500B 帧=375 拍） | udp_echo.cpp:145（LOOP_145，II=1） |
| 通用 | 超限 drain | ≤1023 | udp_echo.cpp:146 |
| IP 解析 | 20B 头读 5 words + 校验和 10 words ×2 循环 | ~25-30 | layer_ip.cpp:43-73（LOOP 43/54/58/69） |
| **ARP 应答** | 7 words 解析 + arp_update + 7 words 组帧 | L1 命中 ~20；L1 miss +L2 扫描 ≤513（II=2） | layer_arp.cpp:165,179,192；l1_insert LOOP_76 |
| **ICMP echo** | 8B 头解析 + 3 遍 payload 复制 + 2 遍校验和 + IP 头组帧 | 64B ping ≈ 100-120 | layer_icmp.cpp:62,86,105,125,152 |
| **UDP echo** | UDP 头解析（2 words）+ echo 拷贝 pw 拍 + 组帧 + arp_lookup | 64B 帧 ≈ 40 + TX 后述 | layer_udp.cpp:39；udp_echo.cpp:173（LOOP_173，II=1） |
| **TCP echo** | 20B 头读 + **payload 逐字节读 plen 拍** + **queue 逐字节 plen 拍** + tcp_send 3-4 遍复制 + 校验和 plen/2 | 536B 段 ≈ 3000+ | layer_tcp.cpp:324,336,254,187,207,213,99-104 |
| TX 流式 | preamble 8（LOOP_36，II=1）+ MAC 头 14 + SENDDATA **1 拍/字节** + CRC 4 | 536B 帧 ≈ 600 | layer_mac.cpp:227-312 |
| 动态循环最坏界 | LOOP_173/ICMP 86/105/125 trip=16384（调度保留上限） | 实际=实际长度 | udp_echo.cpp:173；layer_icmp.cpp:86,105,125 |

### 2.3 每字节 ~20-30 拍的归因

- **协议逻辑必需**：理论下限 = 1 拍/字节搬运 + 16 位/拍校验和 + 每帧常数。按此 64B UDP echo 帧
  只需 ~64+28 拍。
- **单 FSM 串行化的人为开销（占大头）**：
  1. 每 pass 固定 ~20 拍状态遍历/握手，与数据无关 → RX 有效利用率 **<5%**（1B/25 拍 vs 线速 1B/1 拍）；
  2. **RX 与 TX 在同一 FSM 中互斥**：mac_tx 流式发送期间 FSM 停留在 SENDDATA 自环（1 拍/字节），
     mac_rx 不被重新武装 → 536B 帧 ≈600 拍 RX 真空（layer_mac.cpp:273-292）；
  3. 每帧 staging 375 拍（1500B）+ 帧完成 pass 600-3000 拍，期间同样不排空 RX；
  4. TCP 数据 3-4 遍重复拷贝：frame_buf→payload[]→send_bufs→seg→buffer；
  5. 1 字节处理宽度：staging 已做到 4B/拍，但 payload 消费仍是逐字节循环。

---

## 3. 瓶颈定位（一句话）

**RX 吞吐 = 1 字节 / 轮询 pass 长度**，而 pass 长度被"33 状态顺序遍历 + 每 pass 固定调 6+ 个层
函数 + 子模块握手"锁死在 21-28 拍；帧处理与 TX 发送在 pass 内叠加（600-3000 拍/帧），使 FIFO
在突发下以 ~2.4GB/s 流入 vs ~50Mbps 流出的速率差被放大——2000B 溢出即由此产生。
瓶颈不在协议逻辑（校验和/解析每帧仅 30-120 拍），而在**架构形态**：无并发、无流水、1 字节粒度、
RX/TX 互斥。

---

## 4. 资产与负债清单

### 4.1 可复用资产（板级 7/7 验证，纯逻辑语义可移植）

| 资产 | 说明 | 10G 用途 |
|---|---|---|
| MAC 帧格式解析/组帧、VLAN 跳过、46B padding、CRC32 + FCS LSB-first 字节序 | layer_mac.cpp 全文件 | 流水级 1:1 复用 |
| IP 头解析、校验和、协议分发、目的 IP 过滤 | layer_ip.cpp:43-83 | fast path 旁路判据 |
| ARP 表（L1:8 LUT 全展开 + L2:256 BRAM LRU） | layer_arp.cpp:34-125 | 控制平面原样复用 |
| ICMP/IGMP/DHCP 帧构建与校验和 | layer_icmp/layer_igmp/layer_dhcp | slow path / 控制面 |
| TCP 状态机 + Reno 拥塞 + RTO/重传逻辑 | layer_tcp.cpp:123-171,286-383 | 控制面（每连接 N 级并行） |
| 32 位字打包/字节序工具 | eth_utils.h | 宽位宽下原样复用 |
| 字段偏移/协议常量知识 | eth_types.h | 全表复用 |

### 4.2 根本障碍（10G 必须废弃的结构）

| 障碍 | 为什么 |
|---|---|
| **ap_ctrl_none 单 FSM 串行 body** | 调用间零重叠，吞吐 = 1/body 总延迟；by construction 无并发 |
| **1 字节/pass RX 粒度** | 线速 1B/拍 @125MHz，现 1B/25 拍 → 差 25×；10G 还需再宽 10× |
| **RX/TX 同 FSM 互斥** | TX 600 拍期间 RX 完全停摆，回显负载下吞吐减半以上 |
| **共享 buffer[768] + 帧内 3-4 遍拷贝** | 每遍 = 全帧串行搬运，且 BRAM 双口成为跨进程共享瓶颈 |
| **每帧固定开销**（staging 375 拍 + 帧完成 pass 600-3000 拍） | 小包率低延时行情下全部浪费 |
| **无 fast/slow path 划分** | 所有帧（含非本机组播以外无关帧）全深度解析 |
| 动态边界循环的 16384 最坏界 | 调度悲观 + 硬件保留大计数器/多路选择器 |

---

## 5. HLS 演进上限评估

**目标数字**：10G 净荷 1.25GB/s = **10B/cyc @125MHz**（或 8B @156.25MHz）；每字节每级流水 II=1 即可。

**理论上可行**：改为标准 **ap_ctrl_hs + DATAFLOW** 后，结构变为多个并发进程（MAC RX 解析 8B/cyc
→ 流 → IP 解析/分发 → fast/slow 分流 → TX 仲裁），各级独立流水，吞吐 = 最慢级 II 而非级延迟之和。
关键分级可做到 II=1：MAC 头解析（8B/cyc，含 2-3 级寄存即可消解 VLAN 判断回边）、增量校验和
（宽加法树）、UDP 组播 fast path（无状态、无循环依赖：解析→头信息入元数据流、payload 直通 DMA），
这是 HLS 最擅长的形态。

**风险与边界**：
1. **TCP 数据平面是 HLS 高危险区**：逐字节语义（重传缓冲、序列号、窗口）需 8-16B 宽化重写；
   动态索引 BRAM + 宽位选逻辑在 156.25MHz 难收敛。现状已见预兆：csynth 报告
   `tcp_rx_process` slack **-0.53ns（Timing violation）**、全局估算仅 171MHz。
2. **ap_ctrl_none 单 FSM 与 DATAFLOW 的根本区别**：前者把整个协议栈编成一条顺序路径，进程天然互斥；
   后者靠流握手制造并行。但 DATAFLOW 的每级握手有 bubble，需 FIFO 深度 > 握手周期；共享数组跨进程
   即串行化（BRAM 端口冲突），必须私有化/分区。
3. **HLS 固有风险**：动态 trip 循环调度悲观、csim≠RTL（本工程已多次踩）、宽数据通路的 Fmax 抖动、
   流控反压逻辑（wrappers 层需同步改写）。
4. 结论倾向：**UDP 组播行情 fast path 用 HLS DATAFLOW 可达线速**（无状态、只读转发、每包常数）；
   TCP 引擎建议 HLS 只做控制面（状态机/表项），**数据面拷贝/校验和/组帧转 Verilog 流水**（或
   HLS 窄核 ×N 并行），纯 HLS 单核 10G TCP 全速风险过高。

---

## 6. 一句话结论

**当前单 FSM 架构是"正确但形态不可扩展"**：协议语义资产（解析/校验/ARP/TCP 状态机）全部板级验证
可复用，但 ap_ctrl_none 串行 body、1 字节粒度、RX/TX 互斥与重复拷贝必须整体废弃重写为
DATAFLOW 宽位流水；10G 下 UDP 组播旁路 HLS 可救，TCP 全速数据平面应转 Verilog。

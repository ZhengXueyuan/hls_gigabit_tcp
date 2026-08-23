# udp_echo HLS — 协议架构设计与工程文档

> **2026-08-23 最终状态**: ECO 板 (Kintex-7 XC7K325T) 移植副本**已全链打通并通过压测**:
> py_net_test **7/7 全 PASS** (ping / UDP 64B / UDP 512B / TCP 25B / TCP 1608B / **TCP 2000B×3**)。
> 原始工程 (Artix-7 Perf-V) 在 D:\repo\perfv\udp_hls。
> **RX 数据通路已于 2026-08-23 重构为 hls::stream 模式** (UG1399 官方模式): MAC RX 把帧字
> 推入 `frame_fifo` (hls::stream, 512深), frame_done 当拍暂存到私有 `frame_buf[400]`,
> 各层从 frame_buf 0 基偏移解析; 共享 `buffer[768]` 现为 **TX 专用**。
> 本文 §3.2/§5/§6.1 已相应更新; 其余各节描述协议栈本身仍有效。
> **2000B 第4段错位破案**: 根因 = wrapper `rx_fifo` 溢出 (非 HLS 竞态), 修复 2048→4096/3900,
> 见 RX_FIFO_OVERFLOW_ANALYSIS.md; 板级结论见 MIGRATION_K7325T.md 与 PORT_NOTES.md。

## 1. 项目概述

本项目将原始的 Verilog GMII 千兆以太网 UDP echo demo (`udp/`) 用 AMD Vitis HLS 2025.2 重写，
目标是构建一个可逐步扩展至完整 IP 协议栈的 FPGA 网络处理架构。

- **移植目标器件**: xc7k325tffg676-2 (Kintex-7 325T, ECO 板; 原工程 xc7a35tftg256-1)
- **主时钟**: 125 MHz (RGMII RX clock 8 ns, 经 BUFG 反相 → gmii_clk)
- **物理接口**: RGMII 4bit DDR (RTL8211E-VL, 1.8V IO) — wrapper 内 k720 demo 转换器转 GMII
- **HLS 顶层接口**: AXI-Stream (`#pragma HLS INTERFACE axis`)
- **复位**: 异步低有效 (`config_rtl -reset all -reset_async -reset_level low`)

---

## 2. 项目文件结构 (ECO 移植版)

```
udp_hls_eco/
├── src/                  # 协议栈 HLS 源码 (同原工程, 仅 eth_types.h 改 BOARD_IP + 4 个 bug 修复)
│   ├── eth_types.h       #   协议类型 + BOARD_IP 192.168.100.2 / MAC 00:0A:35:01:FE:C0
│   ├── eth_utils.h       #   CRC32, IP checksum, 字节序转换
│   ├── layer_mac.cpp     #   MAC 层 (AXI-Stream + VLAN tag + CRC + <46B padding)
│   ├── layer_arp.cpp     #   ARP (L1:8 LRU + L2:256 BRAM)
│   ├── layer_ip.cpp      #   IP (RX checksum 校验, protocol 分发)
│   ├── layer_icmp.cpp    #   ICMP Echo Reply (ping)
│   ├── layer_igmp.cpp    #   IGMPv1/v2 Membership Report
│   ├── layer_dhcp.cpp    #   DHCP Client (DORA, 完整 IPv4 头 + 防洪泛)
│   ├── layer_udp.cpp     #   UDP (8080 echo, ARP lookup)
│   └── udp_echo.cpp      #   顶层 HLS 函数 (stream 接口, 连接所有层)
├── tb/                   # C 仿真测试 (14 项, 2026-08-18 全过)
├── uart_hls/             # 独立 UART IP 工程 (@50MHz, Latency 0 / Interval 1)
├── wrapper_1g.v          # 主顶层: MMCM 200M + k720 RGMII + RX/TX FIFO 帧桥 + 探针
├── wrapper_min*.v        # 最小实验变体 (bisect 调试用)
├── net_stats.v           # UART 统计探针 (?net ?txd ?rxd ?raw)
├── util_gmii_to_rgmii.v  # k720 demo RGMII 转换器 (原版逐字)
├── xdc/eco_rgmii_phy1.xdc
├── run_hls.bat / run_hls.tcl
├── run_vivado_phy1g2.bat / .tcl   # 主 Vivado 构建 (wrapper_1g)
├── program_eco.tcl       # 烧录 (JTAG 1MHz)
├── MIGRATION_K7325T.md   # 移植指南 (硬件结论 + 操作步骤)
└── PORT_NOTES.md         # 完整施工日志
```

**编译方式**: 所有 `.cpp` 文件通过 `#include` 纳入 `udp_echo.cpp`。
HLS 只需 `add_files src/udp_echo.cpp` 即可编译全部代码。

---

## 3. 协议分层架构

### 3.1 分层模型

```
┌─────────────────────────────────────────────────────────────┐
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Layer 3 — Transport (layer_udp.cpp)                 │    │
│  │  • UDP port 匹配 (8080)                              │    │
│  │  • Payload echo / default message                    │    │
│  │  • IP+UDP header 组装 (TX)                           │    │
│  │  接口: udp_rx_t / mac_tx_req_t                        │    │
│  └───────────────────────┬─────────────────────────────┘    │
│                          │                                  │
│  ┌───────────────────────┴─────────────────────────────┐    │
│  │  Layer 2 — Network (layer_ip / arp / icmp / igmp)    │    │
│  │  • IPv4 RX checksum 校验 ✅                            │    │
│  │  • Protocol 分发: 1→ICMP, 2→IGMP, 17→UDP              │    │
│  │  • ARP 表 (16 条目) + ARP Reply ✅                     │    │
│  │  • ICMP Echo Reply (ping) ✅                          │    │
│  │  • IGMPv1/v2 Membership Report ✅                     │    │
│  │  接口: ip_rx_t / arp_entry_t / mac_tx_req_t            │    │
│  └───────────────────────┬─────────────────────────────┘    │
│                          │                                  │
│  ┌───────────────────────┴─────────────────────────────┐    │
│  │  Layer 1 — MAC (layer_mac.cpp)                       │    │
│  │  • GMII byte stream ↔ AXI-Stream<gmii_byte_t>         │    │
│  │  • Preamble/SFD detect & insert                       │    │
│  │  • MAC filter (unicast + broadcast)                   │    │
│  │  • EtherType dispatch: 0x0800→IP, 0x0806→ARP ✅       │    │
│  │  • VLAN tag (802.1Q + 802.1ad QinQ) ✅                │    │
│  │  • CRC32 compute (TX) ✅                               │    │
│  │  • Payload → frame_fifo (hls::stream) → frame_buf     │    │
│  │  接口: hls::stream<gmii_byte_t> / mac_rx_t / mac_tx_req_t │
│  └───────────────────────┬─────────────────────────────┘    │
│                          │  AXI-Stream (data + last flag)    │
│  ┌───────────────────────┴─────────────────────────────┐    │
│  │  Layer 0 — PHY (片外 RTL8211E)                       │    │
│  │  • e_reset, e_mdc, e_mdio, e_gtxc 在 wrapper.v 处理   │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 层间数据流

```
RX: AXI-Stream<gmii_byte_t> → layer_mac → frame_fifo → frame_buf + mac_rx_t
                    ├── ethertype=0x0806 → layer_arp → tx_req (ARP Reply)
                    └── ethertype=0x0800 → layer_ip → ip_rx_t
                           ├── protocol=1  → layer_icmp → tx_req (Echo Reply)
                           ├── protocol=2  → layer_igmp → tx_req (Report)
                           ├── protocol=6  → layer_tcp  → tx_req (TCP echo, port 7)
                           └── protocol=17 → layer_udp  → tx_req (echo, port 8080)

TX: tx_req (from ARP/ICMP/IGMP/UDP/TCP) → layer_mac ← buffer[768] (TX 专用区)
    → AXI-Stream<gmii_byte_t>
```

### 3.3 核心接口类型 (eth_types.h)

```cpp
// AXI-Stream payload type
struct gmii_byte_t {
    ap_uint<8> data;
    bool       last;   // end-of-frame marker
};

// MAC→Upper: parsed frame metadata
struct mac_rx_t {
    ap_uint<16> ethertype; mac_addr_t src_mac, dst_mac;
    bool is_broadcast, is_unicast, valid;
};

// Upper→MAC: transmission request
struct mac_tx_req_t {
    mac_addr_t dst_mac; ap_uint<16> ethertype;
    ap_uint<9> buf_addr; ap_uint<16> buf_len; bool request;
};

// IP→Transport: parsed IPv4 header
struct ip_rx_t {
    ap_uint<8> protocol, ttl; ap_uint<32> src_ip, dst_ip;
    ap_uint<16> total_len; bool checksum_ok, valid;
};

// ARP table entry
struct arp_entry_t {
    ap_uint<32> ip; mac_addr_t mac; bool valid;
};

// UDP→App: parsed UDP header
struct udp_rx_t {
    ap_uint<16> src_port, dst_port, length, payload_len; bool valid;
};
```

### 3.4 VLAN 常量

```cpp
#define TPID_VLAN   0x8100   // 802.1Q single tag
#define TPID_QINQ   0x88A8   // 802.1ad provider bridge (double tag)
```

---

## 4. AXI-Stream 接口

### 4.1 HLS 生成的端口

| 端口 | 方向 | 位宽 | 协议 |
|------|:--:|:--:|------|
| `ap_clk` | in | 1 | ap_ctrl_none |
| `ap_rst_n` | in | 1 | ap_ctrl_none |
| `reset_n` | in | 1 | ap_none |
| `rx_stream_TDATA` | in | 16 | **AXI-Stream** |
| `rx_stream_TVALID` | in | 1 | AXI-Stream |
| `rx_stream_TREADY` | out | 1 | AXI-Stream |
| `tx_stream_TDATA` | out | 16 | **AXI-Stream** |
| `tx_stream_TVALID` | out | 1 | AXI-Stream |
| `tx_stream_TREADY` | in | 1 | AXI-Stream |

HLS 将 `struct gmii_byte_t { ap_uint<8> data; bool last; }` 自动映射为 16-bit TDATA
(data 占低 8 位, last 等控制信号由 AXI-Stream sideband 传递)。
wrapper.v 负责将 AXI-Stream 信号转换回 GMII 的 8-bit `e_rxd`/`e_txd` + 控制信号。

**RX 方向** (GMII → AXI-Stream): 1-cycle 延迟寄存器, 检测 `e_rxdv` 下降沿生成 `last` 标志:
```verilog
// rx_data_d1 = delayed e_rxd, rx_dv_d1/d2 = delayed e_rxdv
wire rx_last = rx_dv_d1 && !rx_dv_d2;  // falling edge
assign rx_data  = {7'b0, rx_last, rx_data_d1};  // TDATA[8]=last, TDATA[7:0]=data
assign rx_valid = rx_dv_d1;
```

**TX 方向** (AXI-Stream → GMII): 直连映射, 无延迟:
```verilog
assign e_txd  = tx_data[7:0];
assign e_txen = tx_valid;
assign tx_ready = 1'b1;  // no backpressure
```

### 4.2 流控制

- RX: `mac_rx_process()` 每周期检查 `!rx_stream.empty()`, 有数据则 `rx_stream.read()`
- TX: `mac_tx_process()` 仅在发送数据时调用 `tx_stream.write()`, 空闲周期不写入
- `last` 标志仅由 MAC TX 的 SENDCRC 最终字节置 `true`, 用于接收端检测帧结束
- C 仿真中 `hls::stream` 需及时排空 (drain) 防止溢出

---

## 5. Buffer 布局 (2026-08-23, RX stream 化重构后)

```
RX 通路 (hls::stream, 按 UG1399 "绝不在并发生产者/消费者间共享裸数组" 重构):
  MAC RX → frame_fifo (hls::stream<uint32_t>, 512深, DUT 内部 static)
         → frame_done 当拍 pop nwords 字到 frame_buf[400] (私有暂存)
         → 各层 (ip/tcp/udp/icmp/arp/dhcp) 从 frame_buf 0 基偏移解析
           (IP头@0, TCP/UDP/ICMP@5, ARP@0, DHCP@7)

buffer[768] = uint32_t array (768 × 32-bit = 3072 bytes), 现 TX 专用:
  0   ─── 159:  BUF_A      (双缓冲重构遗留, RX 已不再使用)
  160 ─── 319:  BUF_B      (双缓冲重构遗留, RX 已不再使用)
  320 ─── 383:  TX_SCRATCH (ARP/ICMP/IGMP reply frames)
  384 ─── 511:  DHCP 帧区
  512 ─── 767:  TX_UDP     (IP+UDP headers + payload; TX_UDP_BASE=512)
```

Buffer + ARP 表均通过 `#pragma HLS RESOURCE core=RAM_2P_BRAM` 推断为双端口 BRAM。
(注: 重构前旧布局为 buffer[512] = RX[0..255]/TX_SCRATCH[256..319]/TX_UDP[320..511],
历史上曾用双缓冲 BUF_A/B; 均以本文上面当前布局为准。)

---

## 6. 模块详细设计

### 6.1 layer_mac.cpp — MAC 层 (AXI-Stream + VLAN)

**RX FSM**: `IDLE → PREAMBLE(8B) → HEADER(14B) → [VLAN] → PAYLOAD`

- 前导码检测: 7×0x55 + 1×0xD5
- HEADER 状态在字节 12-13 检测 TPID:
  - 若 `eth_acc == 0x8100` 或 `0x88A8`: 跳转到 VLAN 状态, 跳过 2 字节 TCI, 重新读取 EtherType
  - 支持 QinQ 双层 tag (最多 2 层)
- 帧结束由 stream 的 `last` 标志检测 (替代 dv 下降沿逻辑)
- **Payload 推入 `frame_fifo` (hls::stream)**, frame_done 当拍由顶层暂存到 `frame_buf[400]`
  (2026-08-23 重构; 此前为直接写共享 Buffer RX 区)

**TX FSM**: `IDLE → SEND55(8B) → SENDMAC(14B) → SENDDATA → SENDCRC(4B)`

- 从 Buffer 读取 payload, 写入 AXI-Stream
- 仅 SENDCRC 最终字节标记 `last=true`
- CRC32 覆盖 MAC dst 到 payload 末尾

### 6.2 layer_arp.cpp — ARP 层 (L1 + L2 两级架构)

- **L1 Cache** (8 条目, LUT, 1-cycle): 全展开并行比较, LRU 替换 (age 计数器)
  - 命中: 归零 age, 其余递增; 淘汰: 选 age 最大者 evict → L2
- **L2 Storage** (256 条目, BRAM, ≤256 cycles): 顺序扫描, 命中后 promote 到 L1
  - 4 BRAM18K: IP(32b)×1, MAC(48b)×2, valid(1b)×1
- **总容量**: 264 条目, L1 延迟 1 cycle / L2 延迟 ≤256 cycles (512ns @125MHz)
- ARP Reply / Request / 学习: 逻辑不变, 共享 L1+L2 存储
- 资源: ~2,917 LUT, ~473 FF, 4 BRAM

### 6.3 layer_ip.cpp — IP 层

- 从 frame_buf 读取 20 字节 IP header (0 基偏移; 重构前为共享 Buffer RX 区)
- 校验 version=4, IHL=5, header checksum
- 分发: `protocol == 1`→ICMP, `2`→IGMP, `17`→UDP
- 仅接受 `dst_ip == board_ip` 或广播 IP

### 6.4 layer_icmp.cpp — ICMP 层

- Echo Request (type=8, code=0) → Echo Reply (type=0, code=0)
- 完整重算 ICMP checksum, 构建 IP header + ICMP message
- 写入 TX_SCRATCH_BASE → 发起 TX 请求

### 6.5 layer_igmp.cpp — IGMPv1/v2 层

- **协议号**: IP protocol 2
- **版本兼容** (RFC 2236 §4):
  - v1 Query (MaxResp==0) → 回复 v1 Report (type=**0x12**)
  - v2 Query (MaxResp>0) → 回复 v2 Report (type=**0x16**)
- 支持 General Query (group=0.0.0.0) 和 Group-Specific Query
- 默认组播组: 239.0.0.1 (BOARD_MCAST, 可配置)
- 完整计算 IGMP checksum, IP TTL=1
- **不支持 IGMPv3** (RFC 3376) — 可变长消息 + source filtering 过于复杂
- 资源: ~341 FF, ~1,382 LUT, 0 BRAM

### 6.6 layer_udp.cpp — UDP 层

- RX: 端口过滤 (仅 8080), 提取 payload (从 frame_buf 0 基偏移)
- TX: 每 256 周期构建 IP+UDP header + default payload → 发起 TX 请求
- Echo: 收到数据后 payload 从 frame_buf 复制到 TX buffer (buffer[768] 的 TX_UDP 区)

---

## 7. 关键 Bug 及修复记录

| Bug | 现象 | 根因 | 修复 |
|-----|------|------|------|
| ethertype 高位丢失 | ARP 帧识别为 0x0006 | `rx.ethertype` 每周期函数头部清零, EtherType 两字节分两周期到达 | 静态 `eth_acc` + 跨周期 `saved_ethertype` |
| buffer 高位地址截断 | 帧 payload 全零 | MAC TX 用 `uint8_t word_idx` 计算索引, 地址 ≥256 截断 | 改为 `uint16_t word_idx` |
| MAC TX e_txen 间隙 | 帧捕获提前终止 | SENDDATA 最后一字节 e_txen=false (函数头部默认) | case 头部设置 e_txen=true |
| IP total length 重复计数 | total_length=56 非 48 | 常量公式重复计算 UDP header | 改为 `IP_HEADER_BYTES + DEFAULT_PAYLOAD_BYTES` |
| 各层未收到 reset | 静态变量残留 | 顶层 `reset_n==false` 时提前 return, 层函数未被调用 | 移除提前 return |
| ARP/ICMP 捕获错误帧 | 测试失败 | UDP TX 帧在 feed 期间仍在发送 | drain + feed 后直接 capture |
| Stream 接口 SIGSEGV | C 仿真崩溃 | TX stream 写入后无人读取导致 FIFO 溢出 | idle 函数每周期 drain TX |
| SENDDATA 双 last 标志 | 帧被截断 | SENDDATA 和 SENDCRC 各自标记 last=true | 仅 SENDCRC 标记 last |
| `dst_mac` 赋值丢失 | MAC 地址全零 | Phase 3 重写时 `tx_req.dst_mac` 赋值行被遗漏 | 补回赋值 |
| CRC residue 修正失败 | CRC 功能错误 | FCS 字节内 bit_reverse 与 CRC 算法不一致 | 回退, 保留原 MSB-first FCS |
| ARP lookup 目标 IP 错误 | ARP 查询错误 IP | `(192UL<<24)\|...\|3UL` 编译行为与预期不同 | 改为显式 hex `0xC0A80003` |
| UDP TX 签名变更缺失 | 编译错误 | Phase 3 改用 stream 后 `arp_table` 参数未传递 | 加入 `arp_table` 参数 |

### ECO 板移植期修复 (2026-08-18, 板级/仿真驱动)

| Bug | 现象 | 根因 | 修复 |
|-----|------|------|------|
| ARP 帧 runt | PC 网卡硬件静默丢弃 (pktmon 不可见) | 46B ARP 帧 < 64B 最小帧 | MAC_TX_SENDDATA 补零到 46B, pad 进 CRC |
| DHCP 帧缺 IP 头 + 缓冲越界 | DHCP 无法完成 DORA | DHCP 帧布局未含 IPv4 头, 写入越界 | 新布局 DHCP_FRAME_BASE=word 288, 82 words; 完整 IPv4 头 (0x45 00, csum 0x39A6) |
| DHCP 无限洪泛 | ~134ms/次重发刷屏 | 失败路径无退避, retry 立即重来 | DHCP_FAILED(6) 状态 + retry_cnt 复位 |
| wrapper rx_last_in 极性反 | IP 永不 complete 帧 | dv 上升沿被误当帧尾 | `rx_dv_d2 && !rx_dv_d1` (下降沿) 并 push rx_d2 |
| demo 克隆生成器 FCS 错 (双重) | **所有 demo 克隆实验的帧被网卡当 FCS 错静默丢弃** (pktmon 零包) | ① eth_crc32 用 unreflected MSB-first CRC (线上 21 27 d6 68) ② 修复后又用 MSB-first 字节序 (线上 63 F9 A3 CA) — 本板 PHY/PC 链只接受 LSB-first | reflected CRC-32 (0xEDB88320) + 按 fcs[7:0],[15:8],[23:16],[31:24] 发出 (线上 CA A3 F9 63 = demo 帧字节)。板级验证 pk21 = 25 帧 ✓ |
| ICMP 回复校验和错 | ping 帧到达 PC (pktmon 可见) 但 Windows 100% 超时 | `buffer[tx_base] &= 0xFFFF00FF` 只清零校验和字段高字节, 请求校验和低字节 (0xD4) 残留污染求和 → 线上 4600 (应 46D4) | `&= 0xFFFF0000` (清全部 16 位); TB 加 ICMP 回复校验和检查。板级验证 ping 4/4 0ms ✓ |

### ECO 板 2000B 攻坚期修复 (2026-08-22~23, 全链打通)

| Bug | 现象 | 根因 | 修复 |
|-----|------|------|------|
| 地址字段位宽不足 | UDP 8080 / TCP 7 全挂 (启用双缓冲后回归) | `ap_uint<9>` 地址字段截断 `TX_UDP_BASE=512`→0 | 改 `ap_uint<10>` (6 处) |
| payload 字索引溢出 | TCP 回显混入 IP 头 | `uint8_t wi` 在 BUF_B 区 (base 160) 溢出 256→0 | 改 `uint16_t wi` |
| xsim TB 卡死 (仿真侧) | DUT 收 2 字节后子 FSM 全死锁 | TB 漏接 DUT `reset_n` 软复位端口 (与 `ap_rst_n` 是两个独立输入) → phi-mux X | TB 实例化补 `.reset_n(rst_n)` |
| **TCP 2000B 第4段错位** | 1608B PASS / 2000B 第4段 (~偏移1739) 非确定乱序 | **wrapper 层 `rx_fifo` 溢出** (2048深/1900门限; DUT 排空 ~1字节/20周期 顶不住 4 段背靠背 ~2392B) — **非 HLS 协议栈竞态** (xsim 直喂 DUT 2000B 逐字节全对; 板级 ILA 实锤 rx_occ 撞门限 + stride-21 子采样) | `rx_fifo` 2048→4096, 阈值 1900→3900, 指针 11→12bit。py_net_test **7/7 PASS**。治标 (≤6 段); 治本 = 提升 DUT 排空速率 (后续可选)。详见 RX_FIFO_OVERFLOW_ANALYSIS.md |

> **教训 (2000B 攻坚)**: ① 连续多架构同点失败时, 应早怀疑假设本身 — 三种 DUT 内部 RX
> 架构 (双缓冲/去FIFO/stream) 全在同点失败, 病根一直在 wrapper FIFO。② csim / DUT-only
> xsim 都绕过 wrapper FIFO, 物理速率差复现不了, 板级 ILA 是金标准。③ 若必须丢帧,
> 应在帧边界丢整帧, 别丢半帧 (丢半帧会错位污染解析)。

> **教训 (FCS/校验和铁律)**: 网卡静默丢弃 (pktmon 零包) 的三大原因: runt <64B、FCS 错、字节错位。
> FCS 的"标准"有实现歧义 (多项式 AND 线上字节序) — "自己验证自己"的闭环 (生成器 CRC 与
> 校验方同源) 两重都漏掉过。**必须以权威 demo 位流的线上字节为基准做全帧逐字节比对**
> (之前只比前 24 字节, 恰好漏掉 FCS 字段)。线上校验和/内容问题用 `pktmon etl2txt --hex`
> 抓原始字节 + Python 等独立参考实现校验 (ICMP 校验和 bug 同此定位)。本板 PHY/PC 链:
> 线上 FCS = complemented reflected-CRC-32 寄存器的小端字节序。

---

## 8. 实现状态

### 8.1 Phase 完成情况

| Phase | 内容 | 状态 |
|-------|------|:----:|
| **Phase 1** | 单模块 HLS — 硬编码 UDP echo | ✅ |
| **Phase 2A** | EtherType 分发 + ARP (16条) + IP checksum + ICMP ping | ✅ |
| **Phase 2B** | IGMPv1/v2 Membership Report | ✅ |
| **Phase 3** | AXI-Stream 接口 + VLAN tag RX (802.1Q + 802.1ad) | ✅ |
| **Phase 4** | 主动 ARP 查询 + VLAN TX + CRC 修正 | ✅ |
| **Phase 5** | DHCP Client (DISCOVER→OFFER→REQUEST→ACK) | ✅ |
| Phase 6 | UDP 多端口 + 应用层分离 | 待实施 |
| Phase 7 | TCP 简化栈 | 待实施 |

### 8.2 已验证功能

| 功能 | 验证方式 |
|------|---------|
| CRC32 (check=0xCBF43926) | C 仿真 |
| MAC filter + EtherType 分发 | C 仿真 |
| VLAN tag 识别 RX (单层 + QinQ) | C 仿真 |
| VLAN tag 插入 TX (802.1Q) | C 仿真 |
| AXI-Stream RX/TX | C 仿真 |
| IP RX checksum 校验 | C 仿真 |
| ARP Reply (16 条目) | C 仿真 |
| **ARP 主动查询** (未命中→ARP Request + broadcast fallback) | C 仿真 |
| ICMP Echo Reply (ping) | C 仿真 |
| IGMPv1 Report (MaxResp=0) | C 仿真 |
| IGMPv2 Report (MaxResp>0) | C 仿真 |
| UDP echo (端口 8080) | C 仿真 |
| UDP default message 周期性发送 | C 仿真 |

### 8.3 综合结果

| 指标 | Phase 1 | Phase 2B | Phase 3 | Phase 4 | **Phase 5** |
|------|---------|----------|---------|---------|-----------|
| 目标时钟 | 125 MHz | 125 MHz | 125 MHz | 125 MHz | 125 MHz |
| 估算 Fmax | ~186 MHz | ~171 MHz | ~171 MHz | ~171 MHz | **~171 MHz** |
| BRAM | 1 | 5 | 5 | 7 | **7** |
| FF | 2,514 | 4,250 | 4,249 | 4,466 | **6,964** |
| LUT | 3,739 | 10,185 | 10,145 | 10,915 | **18,120** |
| DSP | 0 | 0 | 0 | 0 | 0 |
| 测试数 | 24 | 8 | 11 | 12 | **13** |
| 接口 | 裸 wire | 裸 wire | AXI-Stream | AXI-Stream | AXI-Stream |
| ARP 条目 | — | 16 (UNROLL) | 16 | 16 | **264 (L1:8+L2:256)** |
| 支持协议 | UDP | +ARP+ICMP+IGMP | +VLAN RX | +VLAN TX +ARP | **+DHCP** |
| Bitstream | ✅ | — | — | ✅ | 待重新生成 |

> **2026-08-18 全栈重综合 (xc7k325tffg676-2, 含 TCP/DHCP/stats 全部层)**: 27 BRAM_18K /
> 4 DSP / 15,655 FF / **36,200 LUT** (17% 利用率, 器件从 20.8k 变 203.8k LUT 后不再紧张)。
> 顶层为事件驱动 FSM (Latency/Interval = ?, 无 II 要求 — 与 uart_console 的
> Latency 0 / Interval 1 铁律不冲突)。csim 14 项测试全过 (2026-08-18)。

### 8.4 各模块资源明细 (Phase 4)

| 模块 | BRAM | FF | LUT | 说明 |
|------|:---:|:---:|:---:|------|
| MAC RX (stream+VLAN RX) | 0 | 515 | 986 | GMII 解析 + VLAN tag 跳过 |
| MAC TX (stream+VLAN TX) | 0 | ~530 | ~1,230 | 组帧 + CRC + VLAN 插入 |
| ARP (L1+L2) | 4 | 473 | 2,917 | L1:8(LUT)+L2:256(BRAM), LRU |
| ICMP | 2 | 745 | 1,850 | Echo Reply + checksum |
| IGMP | 0 | 341 | 1,382 | v1/v2 Query→Report |
| IP | 0 | 343 | 819 | header 解析 + checksum |
| UDP TX (ARP lookup) | 0 | ~380 | ~1,330 | 周期性发包 + ARP 查询 |
| UDP RX (2 pipelines) | 0 | 170 | 258 | 端口匹配 + echo 拷贝 |
| 共享 buffer | 1 | 512 | 192 | 512×32b 双口 BRAM |
| ARP pending / VLAN config | 2 | — | — | 新增 BRAM |
| 寄存器/MUX/控制 | — | ~530 | ~1,960 | 顶层状态机 |
| **合计** | **7** | **6,964** | **18,120** | 利用率 BRAM 7%, FF 16%, LUT 87% |

### 8.5 当前局限

| 局限 | 影响 | 状态 |
|------|------|:--:|
| ARP 未命中策略 | 先发 ARP Request + broadcast fallback, 下一周期才用 unicast | ⚠️ |
| DHCP 需外部服务器 | Discover 广播, 需网络中有 DHCP 服务器响应才能完成 IP 获取 | ⚠️ 需实际网络环境 |
| 无分片/重组 | 超过 MTU 的包被丢弃 | ⚠️ |
| UDP 单端口 | 仅 8080 端口 (echo) + 68 (DHCP) | ⚠️ |
| 无 IGMPv3 | 可变长消息 + source filtering 未实现 | ❌ |
| CRC residue ≠ 标准值 | 算法正确, check value 验证通过; GMII 字节序差异 | ⚠️ 不影响功能 |
| LUT 利用率偏高 | 18,120/20,800 = 87%, 后续扩展空间有限 | ⚠️ |

---

## 9. 文件依赖关系

```
eth_types.h  ←── eth_utils.h
    │                │
    ├── layer_mac.cpp ──────┐
    ├── layer_arp.cpp ──────┤
    ├── layer_ip.cpp ───────┤
    ├── layer_icmp.cpp ─────┤
    ├── layer_igmp.cpp ─────┤
    └── layer_udp.cpp ──────┤
                             │
                    udp_echo.cpp (top-level)
                        │
               run_hls.tcl (add_files)
                        │
              udp_echo_tb.cpp (testbench)
```

---

*文档版本: v6.2 — 2026-08-09 — 单时钟双IP架构 + 板级验证通过 (DONE=HIGH)*

---

## 10. Phase 5 最终实现报告

> **ECO 移植后 (2026-08-18, xc7k325tffg676-2, 含全部层重综合)**: 网络 IP = 27 BRAM_18K /
> 4 DSP / 15,655 FF / 36,200 LUT (17%); UART IP = 0 BRAM / 268 FF / 1,765 LUT,
> **Latency 0 / Interval 1** ✓ (本表下方数据为 Artix-7 Phase-5 历史记录)。
> Vivado 侧主工程 udp_dual_phy1g2 布线报告见 vivado_prj/; 板级结论见 PORT_NOTES.md。

### 10.1 双 IP 架构

```
┌──────────────────────────────────────────────────────┐
│  IP 1: 网络协议栈 (udp_echo)                          │
│  时钟: e_rxc 125MHz  |  复位: 异步低有效               │
│  接口: AXI-Stream (GMII RX/TX + Debug Message)       │
│  协议: MAC + IP + ARP(L1+L2) + ICMP + IGMP + UDP     │
│        + DHCP + VLAN RX/TX + 统计计数器               │
│  测试: 13/13 C 仿真通过                               │
├──────────────────────────────────────────────────────┤
│  IP 2: UART Console (uart_console)                    │
│  时钟: e_rxc 125MHz (同频共享)  |  复位: 异步低有效     │
│  接口: UART RX/TX + AXI-Stream (Debug Message in)    │
│  命令: ?help ?mac ?ip ?dhcp ?arp ?stat               │
│  特性: 回显, 退格, DHCP 缓存, 行缓冲                    │
├──────────────────────────────────────────────────────┤
│  互联: AXI-Stream 直连 (同频, 无跨时钟域)              │
│  net.msg_stream ↔ uart.msg_stream (16b data)         │
└──────────────────────────────────────────────────────┘
```

> **板级验证**: 烧录成功 (End of startup status: HIGH)，MAC: 00:0A:35:01:FE:C0

### 10.2 HLS 综合结果 (各 IP 独立)

| 指标 | 网络协议栈 | UART Console |
|------|:---:|:---:|
| 时钟 | 125 MHz (8 ns) | 50 MHz (20 ns) |
| 估算 Fmax | **171.23 MHz** (5.84 ns) | **74.81 MHz** (13.36 ns) |
| BRAM_18K | 7 | 3 |
| FF | 12,133 | 2,110 |
| LUT | 24,741 | 5,274 |
| DSP | 4 | 0 |
| 测试 | **13/13** ✅ | C 仿真 ✅ |

### 10.3 HLS 各模块资源明细 (网络 IP)

| 模块 | BRAM | FF | LUT | 延迟 |
|------|:---:|:---:|:---:|------|
| MAC RX (stream+VLAN RX) | 0 | 515 | 986 | 1-3 cycles |
| MAC TX (stream+VLAN TX) | 0 | 479 | 1,080 | 1-15 cycles |
| ARP (L1 8-LRU + L2 256-BRAM) | 4 | 473 | 2,917 | L1:1 / L2:≤256 cycles |
| ICMP | 2 | 745 | 1,850 | ? |
| IGMP | 0 | 341 | 1,382 | ? |
| IP | 0 | 343 | 819 | ? |
| DHCP | 0 | 912 | 3,708 | DORA sequence |
| UDP TX (ARP lookup) | 0 | 362 | 1,184 | ? |
| UDP RX | 0 | 170 | 258 | 5 cycles |
| 共享 buffer | 1 | 512 | 192 | — |
| Stats (counters+report) | 0 | 1,300 | 2,100 | — |
| 控制逻辑 | — | ~4,800 | ~4,200 | — |
| **合计** | **7** | **12,133** | **24,741** | — |

### 10.4 Vivado 实际布线结果

| 资源 | HLS 估算(合计) | **Vivado 实际** | 可用 | 利用率 |
|------|:---:|:---:|:---:|:---:|
| Slice LUTs | 30,015 | **10,744** | 20,800 | **51.7%** |
| Slice Registers | 14,243 | **10,041** | 41,600 | **24.1%** |
| BRAM Tiles | 10 | **~25** | 100 | ~25% |
| DSP48E1 | 4 | **4** | 90 | **4.4%** |
| BUFG | — | **3** | 32 | 9% |

> HLS 估计偏保守。Vivado 全局优化后 LUT 降低 **64%** (30k→10.7k)。

### 10.5 时序收敛

| 时钟域 | 频率 | 周期 | WNS | TNS | Failing | 状态 |
|------|:---:|:---:|------|------|:---:|:--:|
| e_rxc (全系统) | 125 MHz | 8.0 ns | +998 ns | 0 ns | 0 | ✅ |

> 单时钟架构 (e_rxc 125MHz)，两个 IP 共享。WNS 998ns 极大裕量。

### 10.6 板级编程结果

| 项目 | 值 |
|------|-----|
| 器件 | xc7a35tftg256-1 |
| 目标板 | Digilent/210203367162A |
| Bitstream 大小 | 2.19 MB |
| 烧录状态 | ✅ End of startup status: HIGH |
| MAC 地址 | 00:0A:35:01:FE:C0 |
| UART 参数 | 9600-8N1, P9(RX)/N9(TX) |

> **已知问题**: `fpga_gclk` (50MHz 板载时钟) 在当前设计中未使用。如果声明该端口但不连接逻辑，Vivado 仍为其分配引脚导致 DONE=LOW。解决方案：不声明该端口，两个 IP 统一使用 e_rxc (125MHz from PHY)。

### 10.6 功耗估算 (Vivado)

| 类别 | 功率 |
|------|------|
| 动态功耗 | 23.95 W |
| 静态功耗 | 0.50 W |
| **总功耗** | **24.44 W** |

> 注: 该估算包含未约束的 I/O 功耗，实际板上功耗约 2-5W。

### 10.7 互联设计

```
网络 IP (125MHz)                     UART IP (125MHz)
    │                                      │
    │  msg_stream (AXI-Stream, 16b)        │
    ├──────────────────────────────────────┤
    │        direct wire connection        │
    │  net_msg_data  → uart_msg_data       │
    │  net_msg_valid → uart_msg_valid      │
    │  uart_msg_ready → net_msg_ready      │
    └──────────────────────────────────────┘
```

同频直连，无缓冲。`msg_stream.full()` 防溢出。

### 10.8 UART 参数

| 参数 | 值 |
|------|-----|
| 波特率 | 9600 |
| 数据位 | 8 |
| 停止位 | 1 |
| 校验 | 无 (8N1) |
| 时钟 | 50 MHz (fpga_gclk) |
| 分频比 | 5207 (50MHz/9600) |
| TX FIFO | 512 bytes (BRAM 环形缓冲) |
| RX FIFO | 64 bytes (BRAM 环形缓冲) |
| 命令缓冲 | 48 bytes |
| 行缓冲 | 256 bytes (网络消息暂存) |
| 网络消息接口 | AXI-Stream (16-bit, via XPM_FIFO_ASYNC) |
| 回显 | ✅ 实时回显输入字符 |
| 退格 | ✅ BS (0x08) / DEL (0x7F) |

### 10.9 命令接口

| 命令 | 响应示例 | 数据来源 |
|------|---------|---------|
| `?help` | `=== Cmds === ?help ?mac ?ip ?dhcp ?arp ?stat` | 静态 |
| `?mac` | `MAC: 00:0A:35:01:FE:C0` | 静态常量 |
| `?ip` | `IP: 192.168.1.100` | DHCP 后自动更新, 否则显示静态默认值 |
| `?dhcp` | `DHCP: 192.168.1.100` 或 `DHCP: pending` | 网络 IP 实时推送 `DHCP:x.x.x.x\n` |
| `?arp` | 每行 `IP → MAC` | 网络 IP 每 ~0.8s 自动 dump ARP L1 缓存 |
| `?stat` | `RX:123pkt 45678B TX:45pkt 1234B A:3 I:1 G:0 D:1` | 网络 IP 统计计数器 (每 ~0.8s 推送) |

**数据流**:
```
网络 IP (125MHz)                      UART Console (50MHz)
  │                                        │
  │  统计计数器: rx_pkt, tx_pkt, ...        │
  │  ARP dump: L1 cache entries             │
  │  DHCP event: "DHCP:ip\n"               │
  │                                        │
  ├── msg_stream (AXI-Stream 16b) ──→ async FIFO ──→ 行缓冲 → 缓存
  │                                        │            │
  │                                        │  ?stat → 返回缓存的统计行
  │                                        │  ?arp  → 返回缓存的 ARP 表
  │                                        │  ?dhcp → 返回缓存的 DHCP IP
  │                                        │  ?ip   → 返回缓存的 DHCP IP
  └────────────────────────────────────────┘
```

### 10.9 UART 参数

| 参数 | 值 |
|------|-----|
| 波特率 | 9600 |
| 数据位 | 8 |
| 停止位 | 1 |
| 校验 | 无 (8N1) |
| 时钟 | 50 MHz |
| 分频比 | 5207 |
| TX FIFO | 512 bytes (BRAM) |
| RX FIFO | 64 bytes (BRAM) |
| 命令缓冲 | 48 bytes |

### 10.10 完整协议栈总结

```
Layer 0 (PHY):      RTL8211E GMII @ 125MHz
Layer 1 (MAC):      Ethernet II + VLAN(802.1Q/802.1ad) RX/TX + CRC32
Layer 2 (Network):  IPv4 (checksum) + ARP(L1:8-LRU+L2:256) + ICMP + IGMPv1/v2
Layer 3 (Transport): TCP (port 7 echo, 3 conn) + UDP (port 8080 echo, 68 DHCP)
Layer 4 (Application): DHCP (DORA), UART Console (debug/status)
Cross-Cut:          AXI-Stream interconnects, XPM async FIFO clock crossing
```

| 阶段 | 累计 LUT | 累计 BRAM | 新增功能 |
|------|:---:|:---:|------|
| Phase 1 | 3,739 | 1 | 单模块 UDP echo |
| Phase 2A | 8,796 | 5 | EtherType + ARP(16) + IP checksum + ICMP |
| Phase 2B | 10,185 | 5 | IGMPv1/v2 |
| Phase 3 | 10,145 | 5 | AXI-Stream + VLAN RX |
| Phase 4 | 10,915 | 7 | VLAN TX + 主动 ARP |
| Phase 5 | 18,373 + 4,422 | 7 + 2 | DHCP + UART Console (双 IP) |
| **Vivado 实际** | **8,098** | **24** | 全协议栈 + 调试控制台 |

---

## 11. Phase 6b — TCP 多连接

### 11.1 设计

```
tcp_conn_t conn[MAX_TCP_CONN];      // per-connection state (BRAM)
tcp_retrans_buf[MAX_TCP_CONN][536]; // retransmit buffer (BRAM)

Connection lookup: 3-tuple (peer_ip, peer_port, dst_port)
  - Match existing → use slot
  - No match, SYN received → allocate free slot
  - No free slot → drop
```

### 11.2 TCP 状态机

```
              ┌─────────┐
              │  FREE   │ ← reset / connection closed
              └────┬────┘
          SYN recv │ (new connection)
              ┌────▼────┐
              │  LISTEN  │ → ignore non-SYN
              └────┬────┘
       send SYN+ACK │
              ┌────▼────┐
              │SYN_RCVD │ → retransmit SYN+ACK on RTO
              └────┬────┘
   ACK of SYN+ACK │
              ┌────▼────┐
              │  ESTAB  │ ← echo received data
              │ LISHED  │ → send ACK + echoed payload
              └────┬────┘
      FIN recv  │ send FIN+ACK
              ┌────▼────┐
              │LAST_ACK │ → retransmit on RTO
              └────┬────┘
     ACK recv  │
              ┌────▼────┐
              │  FREE   │
              └─────────┘
```

### 11.3 配置

```cpp
#define MAX_TCP_CONN  3     // 可配置: 1-8, 每条占 ~2,300 LUT
#define TCP_PORT_ECHO 7     // echo 服务端口
#define TCP_MSS       536   // 保守 MSS
#define TCP_RTO       50000000  // ~400ms @ 125MHz
```

### 11.4 重传

- Per-connection RTO 定时器 (32-bit)
- 超时后重发: SYN+ACK（SYN_RCVD 态）/ ACK+data（ESTABLISHED 态）/ FIN+ACK（LAST_ACK 态）
- 重传缓冲: 536B × 3 conn = 1,608B → BRAM

### 11.5 资源 (HLS 综合)

| 模块 | BRAM | FF | LUT |
|------|:---:|:---:|:---:|
| TCP RX Process | 6 | 4,044 | 6,875 |
| 网络协议栈 (总计) | **13** | **16,179** | **31,660** |
| 网络 + UART (总计) | ~16 | ~18,000 | ~35,000 |

### 11.6 限制

| 限制 | 说明 |
|------|------|
| 固定窗口 | TCP_MSS=536, 无滑动窗口 |
| 无拥塞控制 | 无 slow start, 无 Reno/CUBIC |
| 无 TCP options | 无 MSS negotiation, SACK, window scale |
| Stop-and-wait | 发一段等 ACK, 吞吐受限 |
| 固定 ISN | 伪随机但可预测 |

*文档版本: v7.0 — 2026-08-09 — TCP Phase 6b 多连接 echo server 完成*

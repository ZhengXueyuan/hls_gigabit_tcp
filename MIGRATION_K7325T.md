# 移植指南：udp_hls 网络协议栈 → Kintex-7 325T 新板

> 状态: 2026-08-16 启动, 2026-08-18 更新。旧板 (Perf-V xc7a35tftg256-1) 以太网 PHY↔FPGA
> 物理通路经对照实验判定损坏, 已停止在该板上的网络调试, 移植到 ECO 板
> (XC7K325T-2FFG676C, 副本 D:\repo\ECO\udp_hls_eco)。
> **当前进度**: UART console + RX 通路板级验证 ✅; 协议栈 4 个 bug 已修并重综合 ✅;
> TX 零帧问题已破案 (FCS 位序错), 修复版板级复核中 — 细节全部在 PORT_NOTES.md。
> 本文档汇总工程盘点、已验证结论、移植操作步骤; 板级施工日志以 PORT_NOTES.md 为准。

---

## 1. 工程盘点

| 目录 | 内容 | 状态 |
|------|------|:----:|
| `udp/` | 原始 Verilog UDP demo (Vivado 2018.1, 用于 Perf-V 板) | 参考 |
| `stream_light/`, `stream_light_hls/` | 流水灯 Verilog + HLS 重写 | ✅ |
| `uart_test/`, `uart_test_hls/` | UART 参考 + HLS 重写 | ✅ 板级验证 |
| **`udp_hls/`** | **主工程: HLS 网络协议栈 (双 IP)** | ✅ 待新板验证 |
| `udp_hls/uart_hls/` | UART console IP | ✅ 板级验证 |
| `gmii_probe/` | 以太网物理层诊断探针 (环回+频率计+MDIO+UART报告) | ✅ 板级验证 |
| `DDR3/`, `USB2.0/` | 板载 DDR3/USB 参考工程 | 参考 |

### udp_hls 双 IP 架构

```
IP1: udp_echo 网络协议栈 @ e_rxc (125MHz GMII 假设)
  MAC + VLAN(802.1Q/802.1ad) + CRC32
  ARP: L1(8条目LRU, LUT) + L2(256条目, BRAM), Reply + Request
  IP: checksum 校验 + protocol 分发
  ICMP echo (ping), IGMPv1/v2, DHCP client, UDP:8080 echo, TCP:7 echo
  Stats 计数器 + ARP dump → msg_stream (wrapper 中禁用, CDC 未做)
  HLS: ~34k LUT / 27 BRAM

IP2: uart_console @ fpga_gclk (50MHz)
  9600-8N1, 固定分频 BPS_DIV=5207, II=1 自由运行
  命令: ?help ?mac ?ip ?stat (增量状态机 + 192-bit 移位寄存器响应)
  HLS: ~5k LUT
```

### 构建流程 (旧板, 新板同样适用)

1. `udp_hls/run_hls.bat` → 网络 IP (csim + csynth, 输出 `udp_echo_prj/solution1/syn/verilog/*.v`)
2. `udp_hls/uart_hls/run_hls.bat` → UART IP (输出 `uart_hls/uart_prj/solution1/syn/verilog/*.v`)
3. `udp_hls/run_vivado_wrapper.tcl` → Vivado 综合+实现+bitstream
4. `program_indep.tcl` → JTAG 烧录

---

## 2. 已固化的经验 (铁律)

### 2.1 HLS / 时序

1. **ap_ctrl_none 自由运行 body 必须 II=1** (csynth 报 Latency 0 / Interval 1)。
   II>1 时所有按 body-pass 计数的时序 (UART 波特率、网络定时器) 全错, csim 察觉不到。
2. **UART 用固定分频, 不要 auto-baud** — 曾陷在 auto-baud 校准死循环, 根因根本不是频率。
3. **异步外部引脚同步器必须写在 wrapper.v 里** (HLS 会把 C++ 里的同步器塌缩成组合逻辑)。
4. **pragma 必须在函数内**, `uint8_t` 不能做 ≥256 的索引, 跨周期状态用 `static`。
5. **括号错位排查**: 独立 clang 编译通过 ≠ HLS 通过; 用 brace-depth 脚本逐行查。
   (曾发生 TX 段整个嵌套进 RX else 分支 — 缺一个 `}`, csim 报错但独立编译不报。)
6. 声明但未连接的端口会导致 DONE=LOW。
7. 层间通信用 struct 引用 (非 stream), 避免 FIFO 开销; 共享 `static buffer[512]` → BRAM。

### 2.2 板级调试方法论 (按优先级)

1. **对照实验**: 已知可用的原始 bitstream 烧同板同线 → 秒判设计问题 vs 物理问题。
   本次以太网故障就是靠这招收敛: 原始 demo 同样 0 帧 → 物理层坏, 不再折腾板子。
2. **UART ASCII 报告 > LED**: LED 在 FPGA 配置丢失时引脚悬空显示随机亮, 不可信。
   UART 报告带版本号 (如 `probe3 rxc=...`), 一条线证明配置存活+时钟频率+帧计数。
3. **csynth Latency/Interval** → 秒判 II 问题。
4. **pktmon** (Windows 内置, 管理员): `pktmon start --capture --comp nic` →
   `pktmon etl2txt` — 无 Wireshark 时的抓包方案。已证明 PC 1G 线上 ARP 正常发出。
5. **MDIO 读 PHY 寄存器**: clause-22, MDC≈1.5MHz; 无设备时线上拉应读 0xFFFF,
   读全 0 = 线悬空/无上拉 = 物理断。gmii_probe 已实现 32-PHYAD 扫描。
6. **GMII 环回必须寄存器化**: 组合环回 e_txd=e_rxd 在 e_gtxc=e_rxc 同沿采样 →
   建立时间违例, 环回"看起来死"但物理通路可能是好的。
7. **2.54mm 排针 = 高速信号杀手**: 125MHz GMII 过排针极脆弱; 链路降速/0包先清理重插。
   排针错位一行时电源脚仍可能对上电源脚 (PHY 照常协商链路) 而信号全错位。

### 2.3 UART 经验 (uart_test_hls / udp_hls 板级验证)

- 9600-8N1 @ 50MHz: BPS_DIV=5207, BPS_HALF=2603; 中点采样即可, 不要校验/表决。
- 下降沿起始检测 (prev2==1 && prev1==0), RX/TX 双 FSM 全双工。
- TX 在停止位驱动后即结束 (线保持高), 支持零间隔突发回显。
- **CRLF 陷阱**: 真实终端 Enter 发 `\r\n` 两字节; 第二个 `\n` 会重入命令分支。
  响应加载必须用 `if (resp_remain == 0)` 守卫 (1-deep 语义)。测试脚本必须用 CRLF。
- 响应经 192-bit 移位寄存器, **左对齐** (首字符在 bits 191:184)。
- 回显测试模板不能含 0x0D/0x0A (会触发 "?\r\n" 响应注入, 正确行为)。

---

## 3. 已知未修 bug (移植后第一个修复清单)

来自 TCP 代码审查, **全部在 `udp_hls/src/`**:

| # | 严重度 | 位置 | 问题 |
|---|:---:|------|------|
| 1 | 🔴 | layer_tcp.cpp:211-237 + udp_echo.cpp:121 | **TCP 重传是死代码**: timer 扫描只在 `!ip_rx.valid\|\|protocol!=6` 分支执行, 但 udp_echo 只在 valid&&==6 时才调用 tcp_rx_process → 永不执行。丢一个包连接永久卡死 |
| 2 | 🔴 | layer_tcp.cpp:163/168 | 重传段 SEQ 错误 (每次 tcp_send 都推进 c.seq, 包括重传) |
| 3 | 🟠 | layer_icmp.cpp:162 | ICMP 回复 dst_mac=0 → **ping 在板上必死** (TB 没检查 dst MAC 所以 csim 过了) |
| 4 | 🟠 | layer_udp.cpp:109-115 | **UDP 广播洪泛**: 每 256 周期发一帧广播 (~500k 帧/s @125M) — 会触发防火墙/杀软, 干扰 TCP |
| 5 | 🟠 | layer_tcp.cpp | RST 完全不处理 → 客户端 abort 后槽位永久泄漏 (3 连接池耗尽) |
| 6 | 🟠 | layer_tcp.cpp:279 | send_buf 追加无边界检查, flush 被阻塞时溢出到相邻 BRAM 状态 |
| 7 | 🟡 | layer_tcp.cpp:170/178 | payload > ~472B 时 TX 帧缓冲 (512 word) 回绕损坏帧; 全 MSS(536) echo 是坏的 |
| 8 | 🟡 | layer_tcp.cpp:276 | peer_seq 无条件推进, 乱序/重复段导致重复 echo |
| 9 | 🟡 | layer_tcp.cpp:137-151 | RTO 估计器从未被调用 (rtt_seq/rtt_start 设置了但没人消费) |
| 10 | 🟡 | layer_tcp.cpp:257-266 | MSS/WS 选项解析读 th[20+o] 越界 (本地 20 字节数组), peer_mss/peer_wscale 恒为默认; SYN|ACK 实际从不带选项 (doff 恒 5) |
| 11 | 🟡 | layer_tcp.cpp:163 | 通告窗口硬编码 0xFFFF, peer_window 算了不用 |
| 12 | 🟡 | layer_arp.cpp:201 | arp_dump 只 dump 8 条 L1, 不含 256 条 L2 |
| 13 | 🟡 | tb/ | TCP 零测试覆盖 (#47 任务未做); msg_stream CDC FIFO 未实现 (wrapper 禁用) |

**修复建议顺序**: #3 (ping 通是后续一切调试的前提) → #4 (洪泛干扰) → #1+#2+#5 (TCP 正确性) → 其余。

---

## 4. 移植到 K7325T 的操作步骤

### 4.0 拿到新板后先确认三件事 (决定改动量)

1. **PHY 芯片和接口模式**: 若是 RTL8211E/KTZ9031 且为 **GMII 8-bit** → 改动最小。
   若是 **RGMII** (4-bit DDR) → 需要在 wrapper 层加 RGMII↔GMII 适配
   (IDDR/ODDR 原语, 或 Vivado IP: gmii_to_rgmii / rgmii_to_gmii)。
   板上若有 **SGMII** PHY 则改动最大 (需要 PCS/PMA IP), 慎重。
2. **以太网时钟**: GMII 时 e_rxc 由 PHY 提供 (1G=125MHz / 100M=25MHz / 10M=2.5MHz)。
   设计的 MAC 逻辑本身与频率无关 (自由运行, 每周期处理一字节),
   但 TCP/DHCP/stats 的**周期计数定时器按 125MHz 假设** — 若实际时钟不同需按比例改常量
   (layer_tcp.cpp: RTO_MIN/RTO_MAX, udp_echo.cpp: DHCP 定时, layer_stats.cpp: 0.8s)。
3. **器件封装**: `set_part` 改成新板实际型号 (如 xc7k325tffg900-2), 两个 run_hls.tcl 都要改。
   Kintex-7 是 7 系列, Vitis HLS 2025.2 / Vivado 2025.2 完全支持, 无需升级工具。

### 4.1 HLS 侧改动 (最小集)

```
udp_hls/run_hls.tcl        : set_part {xc7k325tffg900-2}   (按实际封装改)
                             create_clock -period 8   (e_rxc 125MHz, 不变)
udp_hls/uart_hls/run_hls.tcl: set_part 同上; create_clock -period 20 (50MHz)
```

重跑两个 HLS 工程 (csim 回归 + csynth)。**查 csynth: 网络 IP 顶层不是 II=1 body
(多状态 FSM, mac_rx_process interval 1-3 正常); UART IP 必须 Latency 0/Interval 1。**

### 4.2 Vivado 侧改动

- `wrapper.v`: 端口映射基本不变 (HLS 生成端口名稳定); 若新板是 RGMII, 加适配逻辑。
  - 2 级同步器保持在 wrapper (UART RX)。
  - `e_gtxc = e_rxc` 只对 GMII 成立; RGMII 时 TXC 由 FPGA 提供 (125MHz 常开)。
  - `e_reset=1'b1` (PHY 复位极性与新板核对!), e_mdc/e_mdio 若不需要可保持。
  - **注意**: 旧设计 MDIO 完全没驱动 (e_mdc=0, e_mdio=z) — PHY 靠 strap 配置。
    新板若 PHY 默认不启用 GMII 模式, 需要加 MDIO 初始化序列 (参考 gmii_probe 的 reader)。
- `xdc/`: 全部重写 — 新板的引脚表。**先拿新板原理图/手册**, 对照信号名逐脚映射:
  - GMII: e_rxd[7:0], e_rxdv, e_rxer, e_txd[7:0], e_txen, e_gtxc, e_rxc
  - UART: rs232_rx/rs232_tx (新板的串口引脚/电平 — 若是 RS232 电平需要 MAX3232, 若是 TTL 直连)
  - 时钟: fpga_gclk (50MHz 或新板的系统时钟)
  - LED: 4 个调试灯 (非必需, 但强烈建议保留 — 有 gmii_probe 后其实可省)
  - IOSTANDARD 按新板 bank 电压设置 (Kintex-7 常见 LVCMOS33/25, 高速 bank 可能 1.8V!)
- `run_vivado_wrapper.tcl`: 器件号改掉; XDC 路径改掉。

### 4.3 烧录

- `program_indep.tcl` 逻辑复用: hw_server 枚举目标, 按序列号选 target,
  **PARAM.FREQUENCY 1000000** (1MHz JTAG, 防 DONE=LOW), DONE 必须 HIGH。
- 新板 JTAG 若与 UART 共用线缆, 两条线缆同时插的方案见旧板经验。

### 4.4 新板启动验证顺序 (每步有明确的通过判据)

1. **UART console 先通** (不依赖网络): 烧录 → COM 口发 `?mac` 收到
   `MAC: 00:0A:35:01:FE:C0` → UART IP、时钟、烧录链路全部验证。
   这是移植的第一块试金石。
2. **物理层探针**: 把 `gmii_probe/` 移植过去 (改 XDC + 器件号, 半小时工作量),
   验证 `rxc=125M` + MDIO 读到 PHY ID (RTL8211E = 0x001C/0xC915)。
   新板 PHY 没通之前不要碰协议栈 — 这是旧板最大的教训。
3. **修 bug #3 (ICMP dst MAC) 后 ping 通** — 网络协议栈的第一个端到端信号。
4. **修 bug #4 (UDP 洪泛)**, 然后 TCP echo: 小 payload (≤400B) 先试,
   确认握手+echo 后逐步加压。
5. TCP 加压前必须修 #1/#2/#5 (丢包重传路径)。

### 4.5 新板 IP 地址

- `eth_types.h` 里 BOARD_IP_BYTE* 是编译期常量 (旧值 192.168.0.2),
  UART `?ip` 响应字符串里也硬编码了一份 — 新板按新网络环境改。
- 旧板教训: 直连调试时 PC 网卡 IP 要与 FPGA 同网段且避开 WLAN 网段冲突
  (旧板用 192.168.100.1/24, WLAN 占 192.168.0.x)。

---

## 5. gmii_probe 复用说明 (强烈建议保留)

`gmii_probe/` 是这次调试沉淀的最有价值工具, 移植只需:
1. `top.v` 端口名不变 (GMII + UART TX + LED + 时钟/复位)
2. `probe.xdc` 按新板引脚重写
3. `build_probe.tcl` 器件号改掉

功能: 每 1s UART 报告 `probe3 rxc=<125M|25M|2.5M|0> rxdv_hi=<n> frm_edges=<n>`
+ MDIO 32-PHYAD 扫描。移植后第一次上电运行它, 一条线判定 PHY 是否工作。

---

## 6. 工具链速查 (Windows, 已验证)

| 工具 | 路径 |
|------|------|
| Vitis HLS 2025.2 | `C:\AMDDesignTools\2025.2\Vitis\bin\vitis-run.bat --mode hls --tcl` |
| Vivado 2025.2 | `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source x.tcl` |
| Git Bash 调用 | 写 .bat, `cmd //c "D:\path\x.bat"` (直接引号会失败) |
| hw_server | 后台 `hw_server.bat` (TCP:3121); Vivado 进程内枚举不到目标时必须用它 |
| 抓包 | `pktmon` (内置, 管理员) |
| 串口测试 | PowerShell + System.IO.Ports (9600-8N1) |
| clang 独立编译 | `C:\AMDDesignTools\2025.2\Vitis\win64\tools\clang-16\bin\clang++.exe` + mingw sysroot flags |

## 7. 文档索引

- 旧板原理图/手册: `docs/Perf-V原理图.pdf`, `docs/perfv_artix7开发板手册 - 0330.pdf`
- 旧板以太网模块连接 (Lab 10): `docs/perf_v学习资料.pdf` p43-44
- 工程架构: `udp_hls/ARCHITECTURE.md`
- UART 经验: `uart_test_hls/` (板级验证参考)
- **ECO 板施工日志 (板级实验/破案记录, 最新状态以它为准)**: `D:\repo\ECO\udp_hls_eco\PORT_NOTES.md`
- ECO 板网络验证步骤: `D:\repo\ECO\udp_hls_eco\网络验证指南.md`
- ECO 板 README (构建/引脚/脚本速查): `D:\repo\ECO\udp_hls_eco\README.md`

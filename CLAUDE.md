# udp_hls_eco — Kintex-7 ECO 板网络协议栈 (全链打通)

perfv `udp_hls` HLS 网络协议栈移植到 ECO 板 (XC7K325T-2FFG676C) 的副本工程。
原始工程 (D:\repo\perfv) 不改。移植总纲: `MIGRATION_K7325T.md`; 施工日志: `PORT_NOTES.md`
(**每次实验先追加记录再动手**); 全局 HLS 铁律在用户 CLAUDE.md (ap_ctrl_none body II=1 /
异步引脚同步器写在 wrapper / csim≠板级 等)。

## 当前状态 (2026-08-23, 最终)

- ✅ **全链打通并通过压测**: `py_net_test.py` (anaconda python `/c/Users/zhxue/anaconda3/python.exe`)
  **7/7 全 PASS** = ping / UDP 64B / UDP 512B / TCP 25B / TCP 1608B / **TCP 2000B×3**。
  可用: UART console (`?mac ?ip ?stat ?net`)、ARP、ICMP ping、UDP 8080 echo、TCP 端口 7 echo。
- ✅ **2000B 第4段错位已破案修复**: 根因 = **wrapper `rx_fifo` 溢出** (原 2048深/1900门限;
  4段背靠背 ~2392B 顶满, DUT 排空仅 ~1字节/20周期) — **不是 HLS 协议栈竞态** (xsim 直喂
  DUT 2000B 逐字节全对)。修复: `rx_fifo` 2048→4096 / 门限 1900→3900 / 指针 11→12bit,
  生产位流 7/7 PASS。权威分析: `RX_FIFO_OVERFLOW_ANALYSIS.md`。
  治标 (4096 ≈ ≤6 段); 治本 = 提升 DUT 排空速率 (后续可选优化)。
- ✅ RX 通路已重构为 hls::stream 模式 (UG1399 官方模式): MAC RX → `frame_fifo` (512深)
  → frame_done 当拍暂存 `frame_buf[400]` → 各层 0 基偏移解析; 共享 `buffer[768]` 现为
  **TX 专用** (BUF_A/B[0..319] 为重构遗留; TX_SCRATCH[320..383]/DHCP[384..511]/TX_UDP[512..767])。
- ✅ 过程中顺带修的真 bug: `ap_uint<9>` 地址截断 TX_UDP_BASE=512→0 (改 `ap_uint<10>`,
  曾致 UDP/TCP 全挂); `uint8_t wi` payload 索引溢出 256→0 (改 `uint16_t`, 曾致回显混 IP 头);
  xsim TB 漏接 DUT `reset_n` 软复位 (与 `ap_rst_n` 是两个端口) → phi-mux X 死锁。
- 历史破案链 (全部已修): MAC padding (runt) / DHCP 帧结构 / DHCP 洪泛 / wrapper rx_last
  极性 / **FCS 字节序 LSB-first** (demo 帧线上 = CA A3 F9 63) / **ICMP 校验和字段只清 1 字节**
  (`&= 0xFFFF0000`)。ping 192.168.100.2 = 4/4 0ms。

## 工程结构

| 文件 | 内容 |
|------|------|
| `src/*.cpp` | HLS 协议栈源码 (MAC/ARP/IP/ICMP/IGMP/TCP/UDP/DHCP/stats; RX=hls::stream) |
| `udp_echo_prj/solution1/syn/verilog/` | 网络 IP 综合产物 (36,200 LUT, 事件驱动 FSM 无 II 要求) |
| `uart_hls/uart_prj/solution1/syn/verilog/` | UART IP (1,765 LUT, **必须 Latency 0 / Interval 1**) |
| `wrapper_1g.v` | 主顶层: MMCM 200M + util_gmii_to_rgmii (k720 逐字) + RX(4096×9/3900)/TX(2048×9) FIFO 帧桥 + demo 克隆生成器 + net_stats |
| `wrapper_1g_ila.v` + `vivado_ila_prj/` | ILA 调试变体 (ila_0 探针, 2000B 破案用) |
| `tb_udp_echo.v` / `tb_wrapper_rx.v` | xsim RTL TB: DUT-only (证 DUT 无错) / rx_fifo+DUT (复现溢出) |
| `gen_stim.py` / `parse_resp.py` | xsim 刺激生成 / 回显逐字节校验 |
| `py_net_test.py` | 板级一键回归 (7/7 PASS) |
| `net_stats.v` | UART 探针: `?net ?txd ?rxd ?raw` (计数+帧捕获, 50MHz 独立) |
| `xdc/eco_rgmii_phy1.xdc` | 引脚 + 时钟约束 (phy1_rxc 8ns master + BUFG 反相 generated) |
| `wrapper_min*.v` + `eth_rebuild_*.v` + `eth_test_gen.v` | 调试变体 (demo 重建 bisect 用) |

## 构建

```bash
cmd //c run_hls.bat                       # 网络 IP (csim+csynth)
cd uart_hls && cmd //c run_hls.bat        # UART IP
#   变体: _run_csynth_only.bat (跳过csim) / _run_csim_only.bat / _run_cosim.bat
cmd //c _run_vivado_caller.bat            # 主工程 → vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit
cmd //c _run_prog_caller.bat              # 烧录 JTAG 1MHz
# ILA 变体: run_vivado_ila.bat → ila_capture.bat → ila_analyze2.py
```

## 板级调试工具

- 一键回归: `py_net_test.py` (anaconda python) — ping/UDP/TCP 7 项
- UART COM8 9600-8N1 (PowerShell + System.IO.Ports); `udp_console_test.ps1` / `net_test.ps1`
- PC 抓包: pktmon comp 117 (Killer E5000B) 混杂模式; demo bitstream 对照实验同板同线
- 板级 ILA: `wrapper_1g_ila.v` + `vivado_ila_prj/` (金标准 — csim/cosim/xsim 都复现不了
  线速 vs 慢排空的速率差, 只有 ILA 抓到 rx_occ 撞门限)
- 验证 ping 必须确认走有线网卡 (WLAN 假阳性, 用户纠正过)

## 本工程特有坑 (教训)

1. **网卡静默丢弃三原因**: runt <64B / FCS 错 / 字节错位 — FCS 错最容易在"自己验证自己"
   的闭环里漏掉 (生成器 CRC 与校验方同源)。对照实验的"同一帧"必须**全帧逐字节**比对 FCS
   (之前只比前 24 字节, 漏掉了 FCS 字节序)。
2. **FCS 字节序铁律**: 本板 PHY/PC 链只接受 LSB-first 线上字节序 (demo 帧 = CA A3 F9 63)。
   FCS 的"标准"有实现歧义 — 以权威 demo 位流的线上字节为基准, 不要自证。
3. HLS IP 是 call-based: TVALID 帧内空洞、TREADY 仅外层 FSM 拉高 → wrapper 必须用
   FIFO 整帧缓冲桥 (TX 2048×9, TLAST=TDATA[8], ≥12 周期 IFG)。
4. **wrapper RX FIFO 必须按"线速填入 vs DUT 慢排空"的速率差定容** (2000B 破案教训):
   DUT 排空 ~1字节/20周期 ≈ 50Mbps, 远低于 1Gbps 线速; 2048深/1900门限 顶不住 4段背靠背
   (~2392B)。已加深到 4096/3900 (治标, ≤6 段); 若必须丢帧应在帧边界丢整帧, 别丢半帧。
   **csim / DUT-only xsim 都绕过 wrapper FIFO, 物理上复现不了 — 连续多架构同点失败时,
   应早怀疑假设本身 (病根可能不在 DUT 内)。**
5. k720 工程的"实际" ethernet_test ≠ src/ 树 (工程版带 gmii_arbi+mac_test+6 个 Xilinx IP),
   对照位流按工程版还原。
6. ODDR 的 Q 只能接 OBUF/port — 想在 ODDR 输出采样 pad 电平要用 IOBUF (T=0)。
7. 功率门控实验若把 IP 复位 (ip_enable=0), 其 TX regslice 会打垃圾帧污染线上 TXEN —
   必须同时门控 tx_push; 且 Vivado 会把常复位 IP 优化掉 (利用率失真)。
8. HLS ap_ctrl_none 设计的所有 ap_none 标量输入 (如 `reset_n`, 与 `ap_rst_n` 是两个端口)
   在 TB/wrapper 里必须显式连接, 悬空 = Z → 子 FSM phi-mux X 死锁 (xsim TB 踩过)。
9. 窄类型索引陷阱: `ap_uint<9>` 装不下 TX_UDP_BASE=512; `uint8_t` 索引在跨 256 边界时
   溢出回绕 — 地址/索引位宽按最大 BASE+长度 核算。

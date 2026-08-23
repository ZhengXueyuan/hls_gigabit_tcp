# 2000B TCP echo 第4段错位 — 根因分析 (2026-08-23, 已破案)

> **已破案并修复验证 (板上 7/7 PASS)。** 根因 = **wrapper RX FIFO 溢出**: HLS DUT 排空慢
> (~1字节/20周期), 4 段背靠背 (~2392B) 顶满 2048深/1900门限 的 rx_fifo → 丢第4段中段字节 +
> 丢 last 标志 → 融合下一帧 → 回显错位。**修复: rx_fifo 2048→4096, 门限 1900→3900**,
> 板上 py_net_test 7/7 全过 (含 2000B×3)。本文档记录完整调查链。

## 症状

PC 发 2000B 到 TCP 端口 7 (echo)。Windows 忽略 MSS=460, 拆成 **536×3 + 392 四段背靠背**。
- ping / UDP 64·512B / TCP 25B / **1608B (3段)** 全部 PASS
- **2000B (4段) FAIL**: 回显第4段内 (~偏移1739) 乱序字节, **每次错误字节不同 (非确定)**

## 最终根因 (板级 ILA 实锤)

板上数据路径: `PHY → RGMII→GMII → rx_d1/rx_d2 同步 → rx_fifo[2048, 阈值1900] → DUT(udp_echo)`

- **HLS DUT 是慢速串行处理器**: 整个协议栈在一个 ap_ctrl_none 自由运行 FSM 里, 每次外层迭代
  处理约1字节 → 实测排空 ~1字节/20周期 (~50Mbps), 远低于 125MHz 线速 (1Gbps)。
- wrapper rx_fifo 吸收"线速填入 vs DUT 慢排"的速率差。ILA 捕获 C 实测: 4 段在线上全部完整
  (602/602/602/458 周期), 但 **rx_occ 爬升 569→1142→1714→第4段撞 1900 门限**, 随后以
  ~21 周期在 1899↔1900 振荡 (门限附近反复得失)。
- 第4段交付给 DUT 时只剩 277 拍 (应 458), payload 偏移131 处拼接进**下一帧的前导码+MAC/IP头**;
  中间垃圾字节呈 **stride-21 子采样** (门限振荡时每21线网字节只存1个) — 仿真按 stride-21
  从 payload[113] 抽样与观测垃圾字节 8/11 精确吻合, 机制实锤。
- DUT 不校验 RX TCP checksum → 照收照回显 → PC 看到第4段错位。

## 为什么之前一直没抓到 (关键教训)

1. **一直在 DUT(HLS) 里找竞态, 但 DUT 是对的** (xsim 逐字节证明) — 瓶颈在 wrapper 的 Verilog FIFO。
2. **csim / DUT-only xsim 都绕过了 wrapper FIFO**, 物理上复现不了 — 必须连 wrapper 一起仿真或上板 ILA。
3. **三种 RX 重构 (双缓冲/去FIFO/stream) 全失败**, 因为它们只改 DUT 内部, 没动 wrapper FIFO。
4. **"连续多架构同点失败时, 应早怀疑假设本身"。**
5. **板级 ILA 是金标准**: csim/cosim/xsim 都没能在正确的工作区间复现, 只有 ILA 在真实 PHY 时序下
   抓到 rx_occ 撞门限的瞬间。

## 调查链 (假设 → 实验 → 结论)

| # | 假设 | 实验/改动 | 结果 |
|---|------|-----------|------|
| 1 | RX 共享 buffer 竞态 | 双缓冲 BUF_A/B | 部分作用, 2000B 仍 FAIL |
| 2 | `ap_uint<9>` 地址截断 TX_UDP_BASE=512→0 | 改 `ap_uint<10>` (6处) | **修复 UDP/TCP 全挂回归** (真 bug) |
| 3 | `uint8_t wi` 索引溢出 256→0 | 改 `uint16_t` | **修复"回显混入IP头"** (真 bug), 1608B 恢复 |
| 4 | 4-FIFO 只存元数据 | 移除 FIFO, 当拍处理 | 错误位置移动仍 FAIL |
| 5 | RX hls::stream 重构 (UG1399) | frame_fifo+frame_buf | csim 全过, 板上仍 FAIL (架构更干净但未根治) |
| 6 | DUT 逻辑错 | xsim 直接喂 DUT 2000B | **逐字节全对 → DUT 无错** |
| 7 | **wrapper rx_fifo 溢出** | 复刻 rx_fifo+DUT 线速喂 + 板级 ILA | **实锤! 修复 2048→4096 后 7/7 PASS** |

## 修复 (已板上验证 7/7 PASS)

`wrapper_1g.v` rx_fifo: `2048→4096` 深, 门限 `1900→3900`, 指针/occ 11→12 bit。
- 验证: py_net_test **7/7** (ping/UDP64/UDP512/TCP25/1608/**2000B×3** 全过)。
- 标度预测吻合: 2500/3000B PASS, 4096B 在预测点 (~3642) FAIL。
- 修复位流 occ 峰值 2153 (超旧门限但新门限3900下无恙)。

**注意: 这是治标 (FIFO 加深).** 4096 深约容纳 ≤6 段。治本需提升 DUT 排空速率 (减外层迭代 /
加宽处理位宽) 或按目标突发长度继续加大 FIFO。另: 若必须丢帧, 应在帧边界丢整帧, 别丢半帧
(丢半帧会错位污染解析)。

## 插曲: xsim TB 卡死 (已修)

TB 漏接 DUT 的 `reset_n` 软复位端口 (与 `ap_rst_n` 是两个独立输入) → 悬空 Z → 子 FSM 的
`reset_n==1` 比较得 X → phi-mux 全走 bx → dhcp_tx_process 卡死 state1 → 顶层卡 state22。
**这是"csim过/RTL卡"的典型, 印证全局铁律。** 修复: TB 实例化补 `.reset_n(rst_n)`。

## 相关文件
- `wrapper_1g.v:276-300` — rx_fifo 桥 (已修 4096/3900); `wrapper_1g_ila.v` — ILA 调试变体
- `tb_udp_echo.v`+`parse_resp.py` — DUT-only xsim (证 DUT 无错)
- `tb_wrapper_rx.v`+`gen_stim.py` — wrapper FIFO xsim (复现溢出)
- `vivado_ila_prj/`, `cap_*.csv`, `ila_analyze2.py` — ILA 捕获 (含 stride-21 机制证据)
- `PORT_NOTES.md` — 施工日志

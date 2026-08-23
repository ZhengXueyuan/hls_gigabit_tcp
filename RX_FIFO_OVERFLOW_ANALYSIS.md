# 2000B TCP echo 第4段错位 — 根因分析 (2026-08-23)

> 本文档记录 2000B 压测 bug 的完整调查链与最终根因。**结论: DUT(HLS 协议栈) 逻辑无错,
> 根因在 wrapper 的 RX FIFO 桥 (rx_fifo) — 慢速 DUT + 线速突发的速率差, 4 段背靠背时
> FIFO 顶到 1900 阈值溢出, 挤坏第4段。** 之前"RX 共享 buffer 竞态"的假设被实验证伪。

## 症状

PC 发 2000B 到 TCP 端口 7 (echo)。Windows 忽略 MSS=460, 拆成 **536×3 + 392 四段背靠背**。
- ping / UDP 64·512B / TCP 25B / **1608B (3段)** 全部 PASS
- **2000B (4段) FAIL**: 回显第4段内 (~偏移1722-1738) 出现乱序字节, 位置随综合轻微漂移

## 调查链 (每个假设 → 实验 → 结论)

| # | 假设 | 实验/改动 | 结果 |
|---|------|-----------|------|
| 1 | RX 共享 buffer 竞态 (MAC RX 写 vs TCP 读) | 双缓冲 BUF_A/B + 读路径全改 buf_base | 部分作用, 但 2000B 仍 FAIL |
| 2 | `ap_uint<9>` 地址截断 | TX_UDP_BASE=512 被截成 0 → 改 `ap_uint<10>` (6处) | **修复 UDP/TCP 全挂的回归** (ICMP 用 320<512 所以幸免) |
| 3 | `uint8_t wi` payload 索引溢出 | BUF_B 时 wi=256 回绕成 0 → 读 buf[0] 的 IP头 | **修复"回显混入IP头"的确定性错误**, 1608B 恢复 PASS |
| 4 | 4-FIFO 只存元数据不存 payload | 移除 FIFO, frame_done 当拍立即处理 | 错误位置移动但仍 FAIL |
| 5 | RX hls::stream 重构 (UG1399 官方模式) | MAC RX→frame_fifo(512深)→frame_buf, 各层顺序读 | csim 全过, 板上 2000B 仍 FAIL → **RX 假设证伪** |
| 6 | **DUT 逻辑本身错** | **xsim 直接喂 DUT 2000B** | **逐字节全对 → DUT 无错!** → bug 在 DUT 之外 |
| 7 | **wrapper rx_fifo 桥溢出** | **复刻 rx_fifo+DUT, 线速喂** | **max_occ=1900, drop_cnt=457 → 溢出实锤** |

## 根因

板上数据路径:
```
PHY → RGMII→GMII(util_gmii_to_rgmii) → rx_d1/rx_d2 同步 → rx_fifo[2048] → DUT(udp_echo)
```

- **HLS DUT 是慢速串行处理器**: 实测排空 ~15-20 拍/字节 (≈50Mbps), 远低于 125MHz 线速 (1Gbps)。
  因为整个协议栈在一个 ap_ctrl_none 自由运行 FSM 里, 每"拍"(一次外层迭代) 处理约1字节。
- **wrapper rx_fifo** 吸收"线速填入 vs DUT 慢排"的速率差: 2048 深, `rx_push = rx_dv_d2 && (rx_occ<1900)`。
- 单段/小流量: FIFO 装得下, 无溢出 → 全过。
- **4 段背靠背 (≈2392B > 1900)**: DUT 在处理/回显前段时离开 RX 态暂停消费, FIFO 在第4段
  到达时顶满 1900 → **丢字节/挤坏** → 第4段内容错位。

## 为什么这么多手段都没抓到 (教训)

1. **一直在 DUT(HLS) 里找竞态, 但 DUT 是对的** — 真正的瓶颈在 wrapper 的 Verilog FIFO 桥。
2. **csim 和 DUT-only xsim 都绕过了 wrapper FIFO**, 物理上复现不了 — 必须**连 wrapper 一起仿真**
   (或上板 ILA) 才能看见。
3. **"连续多架构同点失败时, 应早怀疑假设本身"** — 三种 RX 架构都在第4段失败, 早该想到
   病根不在 RX 缓冲。
4. **xsim 卡死的插曲**: TB 漏接 DUT 的 `reset_n` 软复位端口 (与 `ap_rst_n` 是两个), 导致子 FSM
   phi-mux 全 X 死锁 — 这是"csim过/RTL卡"的典型, 也印证了全局铁律。

## 自洽性验证

| 观察 | 解释 |
|------|------|
| 1608B PASS / 2000B FAIL | 3段≈1794B<1900 装得下; 4段≈2392B>1900 溢出 |
| 错误总在第4段 | 第4段到达时 FIFO 最满 |
| 错误位置随综合漂移 | DUT 排空速率随 HLS 调度变 → 溢出点变 |
| xsim 喂 DUT 不复现 | 未经 wrapper FIFO |

## 修复方向 (待板上 ILA 确认后定)

- **短期**: 扩大 rx_fifo (2048→4096, 阈值相应提高), 让 4 段装得下。注意这只是把容量瓶颈
  往后推 — 更大突发仍会溢出。
- **根本**: 提升 DUT 排空速率 (减少外层迭代周期 / 加宽处理位宽), 或 wrapper 层做
  更智能的流控/丢整帧而不是丢半帧。
- **注意**: 丢半帧比丢整帧更糟 (错位污染解析)。若必须丢, 应在帧边界丢。

## 相关文件
- `wrapper_1g.v:276-294` — rx_fifo 桥 (2048/1900)
- `tb_wrapper_rx.v` + `gen_stim.py` + `xsim_run/sim_files_w.prj` — 复现用 xsim 测试台
- `tb_udp_echo.v` + `parse_resp.py` — DUT-only xsim (证明 DUT 无错)
- `PORT_NOTES.md` — 施工日志

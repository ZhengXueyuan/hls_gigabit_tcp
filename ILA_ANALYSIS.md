# ILA 波形分析: buffer[39] BRAM 读写时序

> 构建日期: 2026-08-22
> 位流: wrapper_1g.bit (含 ILA u_ila_buf39)
> ILA 探针: buffer_r_U Port 0 (read) + Port 1 (write), 触发条件 address0==39

> **⚠ 结论更正 (2026-08-23): 本调查路线 (buffer[39] BRAM 读写竞态假设) 已被证伪,**
> **本文档保留作过程记录, 下方"待填"项不再执行。**
> 后续板级 ILA 实锤: 2000B 第4段错位的最终根因 = **wrapper 层 `rx_fifo` 溢出**
> (2048深/1900门限, 4 段背靠背 ~2392B 顶满; DUT 排空 ~1字节/20周期), 与 buffer BRAM /
> written 阵列 / tcp_send_bufs 均无关。**修复: rx_fifo 2048→4096 / 门限 1900→3900**,
> 板上 py_net_test 7/7 PASS。权威分析见 [RX_FIFO_OVERFLOW_ANALYSIS.md](RX_FIFO_OVERFLOW_ANALYSIS.md)。
> (实际破案的 ILA 工程 = `wrapper_1g_ila.v` + `vivado_ila_prj/`, 探针为 rx_occ/rx_wptr 等
> FIFO 信号 + tcp_send_bufs 端口, 捕获 cap_a/b/c.csv, 非本文档的 buffer[39] 单地址触发。)

## 1. ILA 探针配置

| 探针 | 位宽 | 信号 | 说明 |
|------|------|------|------|
| Probe0[20:12] | 9 | address0 | Port 0 读地址 (MSB first) |
| Probe0[11:3] | 9 | address1 | Port 1 写地址 (MSB first) |
| Probe0[2] | 1 | ce0 | Port 0 读使能 |
| Probe0[1] | 1 | ce1 | Port 1 使能 |
| Probe0[0] | 1 | we1 | Port 1 写使能 |
| Probe1[31:0] | 32 | q0 | Port 0 读数据 |
| Probe2[31:0] | 32 | d1 | Port 1 写数据 |
| Probe3[31:0] | 32 | q1 | Port 1 读回数据 |

- 时钟: gmii_clk (125MHz)
- 深度: 4096 样本 (约 32.7us @ 125MHz)
- 触发: address0 == 39 (Probe0[20:12] == 9'd39)

## 2. BRAM 架构回顾

```
buffer_r_U: udp_echo_buffer_r_RAM_2P_BRAM_1R1W (wrapper)
  └── udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram (BRAM, READ_FIRST)
```

- Port 0: 只读 (q0 = ram[address0], 1 周期延迟)
- Port 1: 读写 READ_FIRST (q1 = ram[address1]旧值, ram[address1] = d1)
- `written` 阵列: 512 位, 追踪地址是否被写过 (返 0 给未写地址)
- buffer[39] 是 uint32_t, 对应 BRAM 地址 39

## 3. 测试场景

### 3.1 1608B (3段, PASS)

TCP 1608B = 3 段 x 536B, 不触发 buffer[39] 的错误路径。

| 波形截图 | 说明 |
|---------|------|
| [待捕获] | ILA 波形: buffer[39] 的 MAC RX 写和 TCP 读 |

### 3.2 2000B (4段, FAIL)

TCP 2000B = 3 段 x 536B + 1 段 x 392B, 偏移 1726 处数据污染。

| 波形截图 | 说明 |
|---------|------|
| [待捕获] | ILA 波形: buffer[39] 的 MAC RX 写和 TCP 读 |

## 4. 波形分析

### 4.1 关键问题

对每次 buffer[39] 访问, 回答以下问题:

1. **MAC RX 写入 buffer[39] 的值是否正确?**
   - [ ] 正确: d1 的值与 PC 发送的 payload 一致
   - [ ] 错误: d1 的值与预期不符, 说明 MAC RX 层写错了

2. **TCP 读取 buffer[39] 的值是否正确?**
   - [ ] 正确: q0 的值与 d1 写入的值一致
   - [ ] 错误: q0 的值与 d1 不同, 说明发生了读/写冲突

3. **如果错误, 发生在哪个时钟周期?**
   - 周期数: [待填]
   - 错误类型: [读错/写错/时序冲突]

### 4.2 1608B vs 2000B 对比

| 项目 | 1608B (PASS) | 2000B (FAIL) |
|------|-------------|-------------|
| MAC RX 写 buffer[39] 的值 | [待填] | [待填] |
| TCP 读 buffer[39] 的值 | [待填] | [待填] |
| 读写时间间隔 | [待填] | [待填] |
| 同一周期读写冲突? | [是/否] | [是/否] |

## 5. 根因判断

### 假设 1: MAC RX 写错了 (d1 的值不对)
- 证据: [待填]
- 可能性: [高/中/低]

### 假设 2: TCP 读错了 (q0 的值与 d1 不一致)
- 证据: [待填]
- 可能性: [高/中/低]

### 假设 3: 时序冲突 (同一周期读写同一地址, READ_FIRST 返回旧值)
- 证据: [待填]
- 可能性: [高/中/低]

### 假设 4: 其他 (BRAM 初始化/written 阵列/时钟域交叉)
- 证据: [待填]
- 可能性: [高/中/低]

## 6. 结论

[待填: 综合波形分析, 明确指出根因和修复方向]

## 7. 操作步骤

### 构建
```bash
cd D:/repo/ECO/udp_hls_eco
cmd //c run_vivado_phy1g2.bat
```

### 烧录
```bash
vivado -mode batch -source program_eco.tcl -tclargs vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit
```

### 测试 (1608B PASS)
```powershell
powershell -File tcp_bulk_test.ps1 -Bytes 1608
```

### 测试 (2000B FAIL)
```powershell
powershell -File tcp_bulk_test.ps1 -Bytes 2000
```

### ILA 捕获
```bash
vivado -mode batch -source ila_capture.tcl -tclargs vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit
```

### 波形查看
在 Vivado GUI 中打开 Hardware Manager, 连接 localhost:3121, 打开 ILA dashboard 查看波形。

## 8. 波形截图

### 1608B PASS
[截图占位]

### 2000B FAIL
[截图占位]

### 波形对比
[截图占位]
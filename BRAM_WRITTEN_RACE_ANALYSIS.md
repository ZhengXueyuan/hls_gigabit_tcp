# TCP 多段 echo 偏移 1726 字节错误 — 深度根因分析

> 2026-08-22, 基于 HLS 生成 Verilog 网表的静态分析 + xsim 仿真验证

## 1. 现象回顾

| 测试 | 结果 |
|------|------|
| TCP 1608B (3段, 每段 536B) | ✅ PASS |
| TCP 1727B (4段) | ❌ 最后 1 字节错 |
| TCP 2000B (4段) | ❌ 偏移 1726 起错 |
| TCP 4096B (8段) | ❌ 收到 2144B 后截断 |

- 错误偏移: 精确在 1726 = 3×536+118, 对应 `buffer[39]` byte 2
- 错误特征: 非确定性, 每次 build 不同, 3 字节重复模式
- 临界点: 1726B (第 4 段 118 字节) PASS, 1727B (第 4 段 119 字节) FAIL

## 2. BRAM 架构 (已通过 xsim 仿真验证)

### 2.1 HLS 生成的 BRAM 模块链

```
udp_echo.v (顶层 FSM)
  └── buffer_r_U: udp_echo_buffer_r_RAM_2P_BRAM_1R1W (wrapper)
        └── udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram (BRAM 原语, READ_FIRST)
```

### 2.2 BRAM 原语 (1R1W_ram.v)

```verilog
// Port 0: 只读
always @(posedge clk) if (ce0) q0 <= ram[address0];

// Port 1: 读写 (READ_FIRST 模式)
always @(posedge clk) if (ce1) begin
    if (we1) ram[address1] <= d1;
    q1 <= ram[address1];    // 先读后写 — 读到旧值
end
```

### 2.3 BRAM wrapper — `written` 追踪阵列

```verilog
reg [511:0] written = 0;          // 512 位追踪寄存器

// 写操作: 标记地址已被写入
always @(posedge clk)
    if (ce1 & we1) written[address1] <= 1'b1;

// 读操作: 1 周期延迟后才知道地址是否被写过
always @(posedge clk)
    if (ce0) sel0_sr[0] <= written[address0];

// 输出: 未写入的地址返回 0 (ROM 回退)
assign q0 = sel0_sr[0] ? q0_ram : 0;
```

## 3. xsim 仿真验证 (关键结论)

### 3.1 验证环境

测试文件: `bram_sim/tb_written_race3.v`
运行命令: `xvlog + xelab + xsim -R` (Vivado 2025.2)

### 3.2 测试结果

| 测试 | 场景 | q0 结果 | 结论 |
|------|------|---------|------|
| 1 | 已写地址 + 同周期读写 | **0x11111111** (旧值) | READ_FIRST: 返回写前旧值 |
| 2 | 同周期写不同地址 + 读 | 0xDEADBEEF ✓ | 不同地址, 正确 |
| 3 | 未写地址 + 同周期读写 | **0x00000000** | `written` 首次追踪返回 0 |

### 3.3 关键结论

**`written` 阵列不是根因。** 对于已写入过的地址 (如 buffer[39], 在段 1-3 中已被写入), 同周期读写返回 READ_FIRST 旧数据, 但 `written` 阵列正确返回 1, 不返回 0。

READ_FIRST 行为也无法解释非确定性错误: 如果第 4 段读到第 3 段的旧数据, 错误应该是确定性的, 但实际错误是非确定性的。

**根因不在 BRAM wrapper 层面。** 需要从 HLS FSM 调度层面进一步分析。

## 4. 已排除的假设

| 假设 | 排除原因 |
|------|---------|
| `written` 阵列 2 周期延迟 | xsim 验证: 已写地址返回正确 |
| READ_FIRST 返回旧数据 | 确定性行为, 无法解释非确定性错误 |
| buffer 区域重叠 (RX 0..255 vs TX 320..511) | 地址不重叠 |
| 条件延迟 FIFO 丢帧 | 双缓冲 + 16 条目 FIFO 均无效 |
| HLS pragma / volatile / RAM_1P | 均无效 |

## 5. 待验证方向

1. **HLS FSM 32 状态中的 buffer 访问调度**: 分析 state7 (MAC RX 写) 到 state23 (TCP 读) 之间的精确时序
2. **tcp_rx_process 子模块内部 buffer 访问**: 该子模块同时有 buffer 读 (Port 0, RX 区) 和 buffer 写 (Port 1, TX 区, 来自 tcp_send), 内部调度可能冲突
3. **wrapper 层 RX FIFO 桥**: 2048 条目 FIFO 在背靠背 4 帧时可能有边界条件
4. **ILA 探针观察**: 在板级用 ILA 观察 buffer[39] 的实时值, 确定污染发生在 MAC RX 写还是 TCP 读阶段

## 6. 关键文件

| 文件 | 行号 | 内容 |
|------|------|------|
| `udp_echo_buffer_r_RAM_2P_BRAM_1R1W.v` | 27-78 | `written` 追踪和 `sel0_sr` 延迟 |
| `udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram.v` | 33-50 | BRAM 原语 (READ_FIRST) |
| `udp_echo.v` | 1051-1062 | buffer 实例化 |
| `udp_echo.v` | 31-40 | FSM 32 状态定义 |
| `src/layer_mac.cpp` | 133-156 | MAC RX payload 写入 |
| `src/layer_tcp.cpp` | 302-386 | TCP RX payload 读取 |
| `src/udp_echo.cpp` | 110-128 | 顶层 dispatch |
| `bram_sim/tb_written_race3.v` | — | BRAM 时序验证 testbench |

## 7. 重现仿真

```bash
cd D:/repo/ECO/udp_hls_eco
mkdir -p bram_sim
# 测试文件已在 bram_sim/tb_written_race3.v
"C:/AMDDesignTools/2025.2/Vivado/bin/xvlog.bat" \
  bram_sim/tb_written_race3.v \
  udp_echo_prj/solution1/syn/verilog/udp_echo_buffer_r_RAM_2P_BRAM_1R1W.v \
  udp_echo_prj/solution1/syn/verilog/udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram.v
"C:/AMDDesignTools/2025.2/Vivado/bin/xelab.bat" tb_written_race3 -L xil_defaultlib
"C:/AMDDesignTools/2025.2/Vivado/bin/xsim.bat" tb_written_race3 -R
```
# 双缓冲 + 读控制器方案 — 完整推演

## 核心架构

```
buffer[512] 重新划分:
  BUF_A: [0..159]    160 words (640B, 够装 536B 段 + IP+TCP 头)
  BUF_B: [160..319]  160 words
  TX:    [320..511]  192 words (unchanged)

MAC RX 交替写入 BUF_A / BUF_B
读控制器 在 frame_done 时立即拷贝 payload 到 tcp_send_bufs (独立 BRAM)
TCP 处理从 tcp_send_bufs 读 (不碰 buffer)
```

## 完整处理路径推演

### 场景 1: 正常 2000B (4 段, 每段 536B)

```
段1 到达:
  MAC RX: 写 BUF_A[0..143]            ← 占用 BUF_A
  frame_done → 读控制器: 拷 payload 到 tcp_send_bufs[0]
  TCP: 从 tcp_send_bufs[0] 读, echo 到 TX 区
  MAC TX: 发送段1 echo
  BUF_A 释放 (copy 完成)

段2 到达 (MAC TX 还在发段1):
  MAC RX: 写 BUF_B[0..143]            ← 用 BUF_B, 不碰 BUF_A
  frame_done → 读控制器: 拷 payload 到 tcp_send_bufs[1]
  TCP: 从 tcp_send_bufs[1] 读, echo 排队
  BUF_B 释放

段3 到达 (MAC TX 发段2):
  MAC RX: 写 BUF_A[0..143]            ← BUF_A 已释放, 安全
  frame_done → 读控制器: 拷 payload 到 tcp_send_bufs[2]
  BUF_A 释放

段4 到达 (MAC TX 发段3):
  MAC RX: 写 BUF_B[0..143]            ← BUF_B 已释放
  frame_done → 读控制器: 拷 payload 到 tcp_send_bufs[3]
  BUF_B 释放

✅ 全部 4 段 payload 安全保存在 tcp_send_bufs 中, 逐个 echo
```

### 场景 2: 读控制器处理速度跟不上 — 段2 到达时 BUF_A 还没释放

```
段1 到达:
  MAC RX: 写 BUF_A
  frame_done → 读控制器: 开始拷 BUF_A → tcp_send_bufs (需 144 拍)
  
段2 到达 (读控制器还在拷 BUF_A):
  MAC RX: 写 BUF_B[0..143]            ← 用 BUF_B, 安全
  frame_done → 读控制器: 拷 BUF_B → tcp_send_bufs (需 144 拍)
  
段3 到达 (读控制器还在拷 BUF_B, BUF_A 已释放?):
  MAC RX 需要写 BUF_A
  读控制器 是否已完成 BUF_A 拷贝?
  
  144 拍 @125MHz = 1.15µs
  段间间隔 = 帧时长 + IFG ≈ 4.6µs + 0.1µs ≈ 4.7µs
  1.15µs < 4.7µs ✅ 拷贝在下一段到达前完成
  
  如果帧间间隔 < 拷贝时间:
  ❌ BUF_A 未释放, BUF_B 也在用 → 读控制器 stalled
  → 段3 丢失 (或覆盖正在拷贝的 BUF_A)
```

### 场景 3: 读控制器 copy 延迟的风险分析

```
最坏情况: 两个 buffer 都 busy
  BUF_A: 段1 的 payload 正在被拷贝
  BUF_B: 段2 的 payload 正在被拷贝
  段3 到达: 无处可写

触发条件: 帧间间隔 < 拷贝时间
  拷贝时间: 144 字 × 8ns = 1.15µs
  帧间间隔: 帧长(576B) × 8ns/B = 4.6µs + IFG 0.1µs ≈ 4.7µs
  1.15µs < 4.7µs → 不会触发

但如果有短帧 (64B):
  帧间间隔: 64B × 8ns = 0.5µs
  拷贝时间: 1.15µs
  0.5µs < 1.15µs → ❌ 可能触发!

解决方案: 读控制器优先处理 payload 拷贝 (不到 TCP 头), 只拷贝 TCP 需要的部分
  56B (TCP段) × 8ns = 0.45µs < 0.5µs ✅
```

### 场景 4: 读控制器拷贝期间的 buffer 访问冲突

```
读控制器 正在读 BUF_A[39]:
  MAC RX 正在写 BUF_B[39]:
    不同 BRAM 区域, 不同地址 → 无冲突 ✅

读控制器 正在读 BUF_A[39]:
  TCP 正在读 tcp_send_bufs[0]:
    不同 BRAM (buffer vs tcp_send_bufs) → 无冲突 ✅

读控制器 正在读 BUF_A[39]:
  MAC TX 正在读 buffer[320]:
    同 BRAM, 不同地址 (39 vs 320) → 无冲突 ✅
```

### 场景 5: 异常帧处理

```
帧 FCS 错误:
  MAC RX 仍然写入 BUF_A, 但 mac_rx.valid = false
  frame_done 未触发, 读控制器 不拷贝
  BUF_A 被标记为 "dirty", 下一个有效帧需要覆盖它
  → 需要 BUF_A 释放逻辑: 帧无效时立即释放

帧 MAC 地址不匹配:
  MAC_RX_HEADER 中判定 is_unicast=false, state → IDLE
  BUF_A 未被写入 (或部分写入), 读控制器 不触发
  → BUF_A 需要释放或重置

帧超长 (> 640B):
  BUF_A 只有 160 字, 最大 640B
  536B 段 + 40B 头 = 576B, 安全
  但如果 PC 发 > 640B 帧 → BUF_A 溢出
  → 需要 buf_wr_addr 上限检查
```

### 场景 6: 读控制器实现细节

```
读控制器 是一个简单的 FSM:
  IDLE: 等 frame_done
  COPY: 从 buf_base 读 144 字, 写到 tcp_send_bufs[slot]
  DONE: 释放 buf, 触发 TCP 处理

需要记录的状态:
  - buf_A_busy: BUF_A 正在被拷贝
  - buf_B_busy: BUF_B 正在被拷贝
  - copy_addr: 当前拷贝到的地址
  - copy_slot: 目标 tcp_send_bufs 槽位

每拍拷贝 1 字 (32-bit), 144 拍完成
```

## 改动量估算

| 文件 | 改动 |
|------|------|
| eth_types.h | 加 BUF_A_BASE=0, BUF_B_BASE=160, BUF_SIZE=160 |
| layer_mac.cpp | buf_wr_addr 初始化改为 buf_sel ? BUF_B_BASE : BUF_A_BASE; 帧完成后 buf_sel=!buf_sel |
| mac_rx_t (eth_types.h) | 加 buf_base 字段 |
| udp_echo.cpp | 添加读控制器逻辑: frame_done 时从 mac_rx.buf_base 拷 payload 到 tcp_send_bufs |
| layer_tcp.cpp | 无改动 (tcp_queue 已从 tcp_send_bufs 读) |

## 和当前 4-FIFO 方案的关键区别

| 项目 | 4-FIFO | 双缓冲 + 读控制器 |
|------|--------|------------------|
| payload 保存 | ❌ 不保存, 依赖 buffer 不被覆盖 | ✅ 立即拷贝到 tcp_send_bufs |
| 4096B+ | ❌ 4 条目溢出 | ✅ 双缓冲 + 队列无限 |
| 竞态 | 🔧 缓解但未消除 | ✅ 读控制器在 frame_done 后读, 与 MAC RX 不同拍 |
| 改动量 | 10 行 | ~50 行 |
| 新增 BRAM | 无 | 无 (复用 tcp_send_bufs) |

## 最大风险点

1. **读控制器和 MAC RX 同时访问 buffer 不同区域**: 同 BRAM 不同地址, 理论上无冲突, 但 HLS 调度器可能把它们放在同一拍 → 需要在 HLS 中加 `#pragma HLS dependence` 或确保读控制器在 MAC RX 空闲时执行

2. **短帧风暴**: 64B 帧连续到达, 帧间间隔 < 拷贝时间 → 读控制器跟不上 → 需要队列 (tcp_send_bufs 已有)

3. **buf_sel 翻转时机**: 必须在读控制器拷贝完成后才能翻转, 否则 MAC RX 会覆盖正在被拷贝的区域
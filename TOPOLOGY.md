# ECO 板 FPGA 网络协议栈 — 拓扑结构

```mermaid
graph TB
    subgraph PC["PC (192.168.100.1)"]
        APP["PowerShell TCP/UDP Client<br/>py_net_test.py (7/7 PASS)"]
        NIC["Killer E5000B NIC<br/>comp 117"]
        PKTMON["pktmon 抓包"]
    end

    subgraph PHY["RTL8211E-VL PHY1 (ETH1)"]
        RGMII_IF["RGMII 4-bit DDR<br/>1.8V LVCMOS18<br/>bank 34"]
        MAG["RJ45 网口"]
    end

    subgraph WRAPPER["wrapper_1g.v (Vivado 顶层)"]
        subgraph CLOCKS["时钟基础设施"]
            MMCM["MMCME2_BASE<br/>50MHz → 200MHz"]
            IDELAYCTRL["IDELAYCTRL<br/>IODELAY_GROUP idelay"]
            BUFG["BUFG (gmii_clk)"]
        end

        subgraph RGMII_ADAP["RGMII 适配层"]
            RGMII_CONV["util_gmii_to_rgmii.v<br/>(k720 demo 逐字)"]
            IDDR["IDDR SAME_EDGE_PIPELINED<br/>RX: {Q2,Q1} 字节拼装"]
            ODDR["ODDR<br/>TX: D1=低nibble D2=高nibble"]
            IDELAY["IDELAYE2 FIXED=10<br/>RX 数据/CTL"]
        end

        subgraph BRIDGES["AXI-Stream 帧缓冲桥"]
            RX_FIFO["RX FIFO 4096×9 (阈值3900)<br/>{last, data[7:0]}<br/>2026-08-23 由2048/1900加深"]
            TX_FIFO["TX FIFO 2048×9<br/>整帧缓冲, ≥12周期IFG"]
            RX_CTL["rx_push: rx_dv_d2 门控<br/>rx_last = rx_dv_d2 && !rx_dv_d1"]
            TX_CTL["tx_draining 状态机<br/>TLAST=TDATA[8]"]
        end

        subgraph PROBES["调试探针"]
            NET_STATS["net_stats.v<br/>?net ?txd ?rxd ?raw<br/>@50MHz fpga_gclk"]
            DEMO_GEN["demo 克隆帧发生器<br/>72B ARP @1Hz<br/>CRC32 reflected LSB-first"]
            UART_SYNC["UART 同步器<br/>2-FF @50MHz"]
        end

        subgraph LEDS["LED 指示灯"]
            LED_D0["led_d0"]
            LED_D1["led_d1"]
            LED_D2["led_d2 = delay_ready"]
            LED_D3["led_d3 = mmcm_locked"]
        end
    end

    subgraph HLS_IPS["HLS IP 核"]
        subgraph IP1["IP1: udp_echo @125MHz gmii_clk"]
            direction TB
            FIFOBUF["frame_fifo (hls::stream, 512深)<br/>+ frame_buf[400] 帧暂存<br/>(RX 流式, UG1399 模式)"]
            BUF["buffer[768] BRAM (TX 专用)<br/>TX_SCRATCH[320..383]<br/>DHCP[384..511] TX_UDP[512..767]<br/>BUF_A/B[0..319] 为重构遗留"]

            subgraph LAYERS["协议栈层 (ap_ctrl_none, 事件驱动FSM)"]
                MAC_RX["MAC RX<br/>GMII→frame_fifo 1B/pass"]
                MAC_TX["MAC TX<br/>buffer→GMII 1B/pass"]
                ARP["ARP L1:8(LRU)+L2:256(BRAM)"]
                IP["IP checksum + 分发"]
                ICMP["ICMP Echo Reply"]
                IGMP["IGMPv1/v2"]
                TCP["TCP Reno + 滑动窗口<br/>Port 7 echo<br/>MSS=460, TX_CHUNK=536"]
                UDP["UDP 8080 echo<br/>UDP 68 DHCP"]
                DHCP["DHCP Client DORA"]
                STATS["stats_report → msg_stream"]
            end

            QUEUE["tcp_send_bufs BRAM<br/>echo 队列<br/>tcp_maintenance 刷新"]
        end

        IP2["IP2: uart_console @50MHz fpga_gclk<br/>Latency 0 / Interval 1<br/>?help ?mac ?ip ?dhcp ?arp ?stat"]
    end

    subgraph UART["UART 接口"]
        CH340["CH340E USB-Serial<br/>COM8 9600-8N1"]
        TX_AND["AND 门 TX 合并<br/>console_tx & stats_tx"]
    end

    subgraph PINS["FPGA 引脚 (Kintex-7 XC7K325T)"]
        CLK50["G22: fpga_gclk 50MHz"]
        RST["D26: reset_n (KEY1)"]
        UART_RX["B17: rs232_rx"]
        UART_TX["A17: rs232_tx"]
        LED_PINS["A23/A24/D23/C24: led_d0..3"]
        PHY1_RXC["AB2: phy1_rxc"]
        PHY1_RXD["AE2/AE1/AC1/AC2: phy1_rxd[3:0]"]
        PHY1_RXCTL["AF3: phy1_rxctl"]
        PHY1_TXC["AB1: phy1_txc"]
        PHY1_TXD["AB4/AA4/AA3/AA2: phy1_txd[3:0]"]
        PHY1_TXCTL["Y3: phy1_txctl"]
    end

    %% 数据流
    MAG -->|"125MHz RGMII"| RGMII_IF
    RGMII_IF -->|"phy1_rxc/rxd/rxctl"| IDELAY
    IDELAY --> IDDR
    IDDR -->|"e_rxd[7:0], e_rxdv"| RX_FIFO
    RX_FIFO -->|"AXI-Stream rx_stream"| IP1
    RX_CTL -.-> RX_FIFO

    IP1 -->|"AXI-Stream tx_stream"| TX_FIFO
    TX_FIFO -->|"e_txd[7:0], e_txen"| ODDR
    TX_CTL -.-> TX_FIFO
    ODDR -->|"phy1_txc/txd/txctl"| RGMII_IF
    RGMII_IF --> MAG

    MMCM -->|"200MHz"| IDELAYCTRL
    MMCM -->|"ref200_clk"| IDELAY
    BUFG -->|"gmii_clk 125MHz"| IDDR
    BUFG -->|"gmii_clk"| ODDR
    BUFG -->|"gmii_clk"| IP1
    CLK50 -->|"50MHz"| MMCM
    CLK50 -->|"50MHz"| IP2
    CLK50 -->|"50MHz"| NET_STATS

    DEMO_GEN -->|"e_txd, e_txen"| ODDR
    NET_STATS -->|"rs232_tx"| TX_AND
    IP2 -->|"uart_tx_raw"| TX_AND
    TX_AND -->|"rs232_tx"| CH340
    CH340 -->|"USB"| PC
    CH340 -->|"rs232_rx"| UART_SYNC
    UART_SYNC --> IP2
    UART_SYNC --> NET_STATS

    NIC <-->|"1G Ethernet"| MAG
    NIC -->|"pktmon"| PKTMON
    APP -->|"TCP:7 / UDP:8080"| NIC

    %% 样式
    style WRAPPER fill:#e1f5fe,stroke:#01579b
    style HLS_IPS fill:#e8f5e9,stroke:#1b5e20
    style PHY fill:#fff3e0,stroke:#e65100
    style PC fill:#f3e5f5,stroke:#4a148c
    style UART fill:#fce4ec,stroke:#880e4f
    style PINS fill:#f5f5f5,stroke:#616161
    style BUF fill:#ffeb3b,stroke:#f57f17
    style FIFOBUF fill:#c8e6c9,stroke:#1b5e20
    style QUEUE fill:#ff9800,stroke:#e65100
```

## 当前 buffer 布局 (2026-08-23, RX stream 化重构后)

```
RX 通路 (hls::stream 模式, UG1399 官方模式):
  MAC RX → frame_fifo (hls::stream<uint32_t>, 512深, DUT 内部)
         → frame_done 当拍 pop 到 frame_buf[400] (私有暂存, 单拍写后读)
         → 各层 (ip/tcp/udp/icmp/arp/dhcp) 从 frame_buf 0 基偏移解析
           (IP头@0, TCP/UDP/ICMP@5, ARP@0, DHCP@7)

buffer[768] BRAM = TX 专用 (RX 已不再写它):
  0..159   BUF_A      (双缓冲重构遗留, 未用)
  160..319 BUF_B      (双缓冲重构遗留, 未用)
  320..383 TX_SCRATCH (ARP/ICMP 回复帧)
  384..511 DHCP 帧区
  512..767 TX_UDP     (echo 帧写到这里; TX_UDP_BASE=512, 需 ap_uint<10> 地址)
```

## 数据流路径

```
RX: PC → PHY → RGMII → IDELAY → IDDR → RX_FIFO(4096×9/3900) → AXI-Stream
    → IP1(MAC_RX→frame_fifo→frame_buf→各层解析)
TX: IP1(buffer[TX区]→MAC_TX) → AXI-Stream → TX_FIFO → ODDR → RGMII → PHY → PC
UART: IP1(msg_stream) → IP2(uart_console) → TX_AND → CH340 → PC
Probe: NET_STATS ← RX/TX 计数 + 帧捕获 → TX_AND → CH340 → PC
```

## 已知问题 / 状态 (2026-08-23)

| 问题 | 状态 |
|------|------|
| ~~buffer[39] byte 2 多段竞态 (offset 1726)~~ | ✅ 已破案 — 真根因 = wrapper RX FIFO 溢出 (2048/1900 顶不住 4段背靠背), 非 DUT 竞态; 见 RX_FIFO_OVERFLOW_ANALYSIS.md |
| RX FIFO 容量不足 (2000B=4段顶满 2048) | ✅ 已修 2048→4096 / 阈值 1900→3900 (治标, 约容 ≤6 段; 治本 = 提升 DUT 排空速率, 后续可选优化) |
| 板级回归 | ✅ py_net_test 7/7 PASS (ping/UDP64/UDP512/TCP25/TCP1608/TCP2000×3) |
| ILA 探针链 | ✅ 已建成 (wrapper_1g_ila.v + vivado_ila_prj + ila_capture.bat + ila_analyze2.py), 2000B 破案主力 |
| msg_stream CDC FIFO | ✅ ?stat/?net 均可用 (板级验证) |
| TCP 健壮性 (重传/RST/乱序) | ⬜ 基本 echo 已验证; 丢包场景路径未覆盖 (见 MIGRATION_K7325T.md §3) |
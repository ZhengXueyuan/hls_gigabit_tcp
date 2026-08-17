# Patch net_stats.v: add ?raw command + per-mode tx_last
p = r'D:\repo\ECO\udp_hls_eco\net_stats.v'
src = open(p, encoding='utf-8').read()

src = src.replace("    input  [63:0]    rx_cap          // first 8 bytes of last RX frame\n);",
"""    input  [63:0]    rx_cap,         // first 8 bytes of last RX frame
    input  [127:0]   raw_cap         // first 16 raw bytes of the IP's TX stream
);""")

src = src.replace("    reg [127:0] txcap_s1, txcap_s2;\n    reg [63:0] rxcap_s1, rxcap_s2;",
"""    reg [127:0] txcap_s1, txcap_s2, rawcap_s1, rawcap_s2;
    reg [63:0] rxcap_s1, rxcap_s2;""")
src = src.replace("        if (!reset_n) begin txcap_s1<=0; txcap_s2<=0; rxcap_s1<=0; rxcap_s2<=0; end\n        else begin\n            txcap_s1 <= tx_cap; txcap_s2 <= txcap_s1;\n            rxcap_s1 <= rx_cap; rxcap_s2 <= rxcap_s1;\n        end",
"""        if (!reset_n) begin txcap_s1<=0; txcap_s2<=0; rxcap_s1<=0; rxcap_s2<=0; rawcap_s1<=0; rawcap_s2<=0; end
        else begin
            txcap_s1 <= tx_cap; txcap_s2 <= txcap_s1;
            rxcap_s1 <= rx_cap; rxcap_s2 <= rxcap_s1;
            rawcap_s1 <= raw_cap; rawcap_s2 <= rawcap_s1;
        end""")

src = src.replace("    reg        rxd_go;      // 1-cycle pulse: \"?rxd\" seen",
"""    reg        rxd_go;      // 1-cycle pulse: "?rxd" seen
    reg        raw_go;      // 1-cycle pulse: "?raw" seen""")
src = src.replace("            cmd_hist<=0; net_go<=0; txd_go<=0; rxd_go<=0;",
"""            cmd_hist<=0; net_go<=0; txd_go<=0; rxd_go<=0; raw_go<=0;""")
src = src.replace("            net_go <= 1'b0;\n            txd_go <= 1'b0;\n            rxd_go <= 1'b0;",
"""            net_go <= 1'b0;
            txd_go <= 1'b0;
            rxd_go <= 1'b0;
            raw_go <= 1'b0;""")
src = src.replace("""                        if (cmd_hist[23:0] == 24'h3F7278 && brx_shift == 8'h64)
                            rxd_go <= 1'b1;                  // "?rxd"
""",
"""                        if (cmd_hist[23:0] == 24'h3F7278 && brx_shift == 8'h64)
                            rxd_go <= 1'b1;                  // "?rxd"
                        if (cmd_hist[23:0] == 24'h3F7261 && brx_shift == 8'h77)
                            raw_go <= 1'b1;                  // "?raw"
""")

src = src.replace("    reg [127:0] lat_txd;\n    reg [63:0]  lat_rxd;\n    reg [1:0]  mode;        // 0=?net 1=?txd 2=?rxd",
"""    reg [127:0] lat_txd, lat_raw;
    reg [63:0]  lat_rxd;
    reg [1:0]  mode;        // 0=?net 1=?txd 2=?rxd 3=?raw""")

src = src.replace("    wire [5:0] tx_last = (mode == 2'd0) ? 6'd20 : 6'd35;",
"""    wire [5:0] tx_last =
        (mode == 2'd0) ? 6'd20 :   // ?net
        (mode == 2'd2) ? 6'd19 :   // ?rxd (20 bytes)
                         6'd35;    // ?txd / ?raw (36 bytes)""")

tail_marker = """                                 hex_asc(lat_txd[3:0])     // 5'd35
        ) : (mode == 2'd2) ? ("""
raw_branch = """                                 hex_asc(lat_txd[3:0])     // 5'd35
        ) : (mode == 2'd3) ? (
            // ?raw: "raw=" + 32 hex (first 16 raw IP-stream bytes)
            (tx_idx == 5'd0)  ? 8'h72 :   // 'r'
            (tx_idx == 5'd1)  ? 8'h61 :   // 'a'
            (tx_idx == 5'd2)  ? 8'h77 :   // 'w'
            (tx_idx == 5'd3)  ? 8'h3D :   // '='
            (tx_idx == 5'd4)  ? hex_asc(lat_raw[127:124]) :
            (tx_idx == 5'd5)  ? hex_asc(lat_raw[123:120]) :
            (tx_idx == 5'd6)  ? hex_asc(lat_raw[119:116]) :
            (tx_idx == 5'd7)  ? hex_asc(lat_raw[115:112]) :
            (tx_idx == 5'd8)  ? hex_asc(lat_raw[111:108]) :
            (tx_idx == 5'd9)  ? hex_asc(lat_raw[107:104]) :
            (tx_idx == 5'd10) ? hex_asc(lat_raw[103:100]) :
            (tx_idx == 5'd11) ? hex_asc(lat_raw[99:96])   :
            (tx_idx == 5'd12) ? hex_asc(lat_raw[95:92])   :
            (tx_idx == 5'd13) ? hex_asc(lat_raw[91:88])   :
            (tx_idx == 5'd14) ? hex_asc(lat_raw[87:84])   :
            (tx_idx == 5'd15) ? hex_asc(lat_raw[83:80])   :
            (tx_idx == 5'd16) ? hex_asc(lat_raw[79:76])   :
            (tx_idx == 5'd17) ? hex_asc(lat_raw[75:72])   :
            (tx_idx == 5'd18) ? hex_asc(lat_raw[71:68])   :
            (tx_idx == 5'd19) ? hex_asc(lat_raw[67:64])   :
            (tx_idx == 5'd20) ? hex_asc(lat_raw[63:60])   :
            (tx_idx == 5'd21) ? hex_asc(lat_raw[59:56])   :
            (tx_idx == 5'd22) ? hex_asc(lat_raw[55:52])   :
            (tx_idx == 5'd23) ? hex_asc(lat_raw[51:48])   :
            (tx_idx == 5'd24) ? hex_asc(lat_raw[47:44])   :
            (tx_idx == 5'd25) ? hex_asc(lat_raw[43:40])   :
            (tx_idx == 5'd26) ? hex_asc(lat_raw[39:36])   :
            (tx_idx == 5'd27) ? hex_asc(lat_raw[35:32])   :
            (tx_idx == 5'd28) ? hex_asc(lat_raw[31:28])   :
            (tx_idx == 5'd29) ? hex_asc(lat_raw[27:24])   :
            (tx_idx == 5'd30) ? hex_asc(lat_raw[23:20])   :
            (tx_idx == 5'd31) ? hex_asc(lat_raw[19:16])   :
            (tx_idx == 6'd32) ? hex_asc(lat_raw[15:12])   :
            (tx_idx == 6'd33) ? hex_asc(lat_raw[11:8])    :
            (tx_idx == 6'd34) ? hex_asc(lat_raw[7:4])     :
                                 hex_asc(lat_raw[3:0])     // 6'd35
        ) : (mode == 2'd2) ? ("""
assert tail_marker in src, "tail marker not found"
src = src.replace(tail_marker, raw_branch)

src = src.replace("            if ((net_go || txd_go || rxd_go) && !tx_active && quiet_cnt == 20'd0) begin",
"""            if ((net_go || txd_go || rxd_go || raw_go) && !tx_active && quiet_cnt == 20'd0) begin""")
src = src.replace("                lat_txd  <= txcap_s2;\n                lat_rxd  <= rxcap_s2;\n                mode     <= net_go ? 2'd0 : (txd_go ? 2'd1 : 2'd2);",
"""                lat_txd  <= txcap_s2;
                lat_rxd  <= rxcap_s2;
                lat_raw  <= rawcap_s2;
                mode     <= net_go ? 2'd0 : (txd_go ? 2'd1 : (rxd_go ? 2'd2 : 2'd3));""")
src = src.replace("            lat_rx<=0; lat_tx<=0; lat_txd<=0; lat_rxd<=0; mode<=0;",
"""            lat_rx<=0; lat_tx<=0; lat_txd<=0; lat_rxd<=0; lat_raw<=0; mode<=0;""")

src = src.replace('//   "?rxd" → "rxd=XXXXXXXXXXXXXXXX"     (first 8 bytes of last RX frame)',
'''//   "?rxd" → "rxd=XXXXXXXXXXXXXXXX"     (first 8 bytes of last RX frame)
//   "?raw" → "raw=" + 32 hex chars      (first 16 raw IP-stream TX bytes)''')

open(p, 'w', encoding='utf-8', newline='').write(src)
print("net_stats.v ?raw added OK")

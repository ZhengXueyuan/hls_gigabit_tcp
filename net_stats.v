`timescale 1ns/1ps
//=============================================================================
// net_stats.v — UART stats reporter: "?net" counters, "?txd"/"?rxd" captures
//=============================================================================
// Parses the SAME synchronized UART RX line as uart_console (9600-8N1 @50MHz,
// 5208 cycles/bit, mid-bit sample at 2603). Commands (4-byte history match):
//   "?net" → "rx=XXXX tx=YYYY L=Z\r\n"  (frame counters, MMCM/IDELAY lock)
//   "?txd" → "txd=" + 32 hex chars      (first 16 bytes of last TX frame)
//   "?rxd" → "rxd=XXXXXXXXXXXXXXXX"     (first 8 bytes of last RX frame)
//   "?raw" → "raw=" + 32 hex chars      (first 16 raw IP-stream TX bytes)
// TX is AND-merged onto the console TX line:
//   rs232_tx = uart_console_tx & stats_tx     (both idle-high)
// The console also sees the commands (echoes them, replies "?") — harmless.
// Frame pulses are toggled in the gmii clock domain by the wrapper and
// edge-detected here after 2-FF sync (toggle-based CDC, no multi-bit sync).
// Byte ends at the END of the stop cell (ECO-board CH340 needs 10.0 bit
// spacing; the old 9.5-bit spacing corrupted bursts).
//=============================================================================

module net_stats (
    input            clk50,          // 50MHz board clock (UART domain)
    input            reset_n,
    input            uart_rx,        // synchronized UART RX line (2-FF sync'd)
    input            uart_tx_in,     // uart_console TX (idle = 1)
    output           uart_tx_out,    // AND-merged TX to pin
    input            rx_toggle,      // toggles on each RX frame (@gmii_clk)
    input            tx_toggle,      // toggles on each TX frame (@gmii_clk)
    input            stat_lock,      // e.g. MMCM LOCKED bit
    input  [127:0]   tx_cap,         // first 16 bytes of last bridged TX frame
    input  [63:0]    rx_cap,         // first 8 bytes of last RX frame
    input  [127:0]   raw_cap,        // first 16 raw bytes of the IP's TX stream
    input  [15:0]    dbg0,           // {rx_fifo_occ[7:0], tx_fifo_occ[7:0]}
    input            dbg1            // IP rx_stream TREADY (sampled)
);

    // --- Frame counters: toggle-based CDC ---
    reg rx_t1, rx_t2, rx_t3, tx_t1, tx_t2, tx_t3;
    reg [15:0] rx_cnt, tx_cnt;
    always @(posedge clk50 or negedge reset_n) begin
        if (!reset_n) begin
            rx_t1<=0; rx_t2<=0; rx_t3<=0; tx_t1<=0; tx_t2<=0; tx_t3<=0;
            rx_cnt<=0; tx_cnt<=0;
        end else begin
            rx_t1 <= rx_toggle; rx_t2 <= rx_t1; rx_t3 <= rx_t2;
            tx_t1 <= tx_toggle; tx_t2 <= tx_t1; tx_t3 <= tx_t2;
            if (rx_t2 ^ rx_t3) rx_cnt <= rx_cnt + 16'd1;
            if (tx_t2 ^ tx_t3) tx_cnt <= tx_cnt + 16'd1;
        end
    end

    // --- tx_cap / rx_cap 2-FF sync (64 bits, values stable between frames) ---
    reg [127:0] txcap_s1, txcap_s2, rawcap_s1, rawcap_s2;
    reg [63:0] rxcap_s1, rxcap_s2;
    always @(posedge clk50 or negedge reset_n) begin
        if (!reset_n) begin txcap_s1<=0; txcap_s2<=0; rxcap_s1<=0; rxcap_s2<=0; rawcap_s1<=0; rawcap_s2<=0; end
        else begin
            txcap_s1 <= tx_cap; txcap_s2 <= txcap_s1;
            rxcap_s1 <= rx_cap; rxcap_s2 <= rxcap_s1;
            rawcap_s1 <= raw_cap; rawcap_s2 <= rawcap_s1;
        end
    end

    // --- Byte receiver (same scheme as the wrapper's @+/- parser) ---
    reg [15:0] brx_cnt;
    reg [3:0]  brx_bitn;
    reg [7:0]  brx_shift;
    reg        brx_active;
    reg [31:0] cmd_hist;    // last 4 received bytes: {b0,b1,b2,b3}
    reg        net_go;      // 1-cycle pulse: "?net" seen
    reg        txd_go;      // 1-cycle pulse: "?txd" seen
    reg        rxd_go;      // 1-cycle pulse: "?rxd" seen
    reg        raw_go;      // 1-cycle pulse: "?raw" seen
    always @(posedge clk50 or negedge reset_n) begin
        if (!reset_n) begin
            brx_cnt<=0; brx_bitn<=0; brx_shift<=0; brx_active<=0;
            cmd_hist<=0; net_go<=0; txd_go<=0; rxd_go<=0; raw_go<=0;
        end else begin
            net_go <= 1'b0;
            txd_go <= 1'b0;
            rxd_go <= 1'b0;
            raw_go <= 1'b0;
            if (!brx_active) begin
                if (uart_rx == 1'b0) begin   // start bit seen on synced line
                    brx_active <= 1'b1;
                    brx_cnt    <= 16'd0;
                    brx_bitn   <= 4'd0;
                end
            end else begin
                if (brx_cnt == 16'd5207) brx_cnt <= 16'd0;
                else                      brx_cnt <= brx_cnt + 16'd1;
                if (brx_cnt == 16'd2603) begin   // mid-bit sample
                    if (brx_bitn == 4'd0) begin
                        // start bit: nothing to shift
                    end else if (brx_bitn <= 4'd8) begin
                        brx_shift <= {uart_rx, brx_shift[7:1]};
                    end else begin                    // stop bit: byte done
                        cmd_hist <= {cmd_hist[23:0], brx_shift};
                        // history[23:0] = 3 bytes before the current one
                        if (cmd_hist[23:0] == 24'h3F6E65 && brx_shift == 8'h74)
                            net_go <= 1'b1;                  // "?net"
                        if (cmd_hist[23:0] == 24'h3F7478 && brx_shift == 8'h64)
                            txd_go <= 1'b1;                  // "?txd"
                        if (cmd_hist[23:0] == 24'h3F7278 && brx_shift == 8'h64)
                            rxd_go <= 1'b1;                  // "?rxd"
                        if (cmd_hist[23:0] == 24'h3F7261 && brx_shift == 8'h77)
                            raw_go <= 1'b1;                  // "?raw"
                        brx_active <= 1'b0;
                    end
                    if (brx_bitn < 4'd9) brx_bitn <= brx_bitn + 4'd1;
                end
            end
        end
    end

    // --- TX FSM: report string @9600, 10 cells per byte ---
    // Trigger → wait ~20ms (echo settles, line quiet) → send → back to idle.
    reg [15:0] lat_rx, lat_tx;
    reg [127:0] lat_txd, lat_raw;
    reg [63:0]  lat_rxd;
    reg [1:0]  mode;        // 0=?net 1=?txd 2=?rxd 3=?raw
    reg [19:0] quiet_cnt;
    reg [5:0]  tx_idx;      // byte index 0..35
    reg [3:0]  tx_cell;     // 0=start, 1..8=data, 9=stop
    reg [15:0] tx_cnt8;
    reg        tx_active;
    reg        tx_line;

    function [7:0] hex_asc;
        input [3:0] n;
        begin
            hex_asc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
        end
    endfunction

    wire [5:0] tx_last =
        (mode == 2'd0) ? 6'd34 :   // ?net (35 bytes: + R=XX T=XX Y=Z)
        (mode == 2'd2) ? 6'd19 :   // ?rxd (20 bytes)
                         6'd35;    // ?txd / ?raw (36 bytes)

    wire [7:0] tx_byte =
        (mode == 2'd1) ? (
            // ?txd: "txd=" + 32 hex (16 TX bytes)
            (tx_idx == 5'd0)  ? 8'h74 :   // 't'
            (tx_idx == 5'd1)  ? 8'h78 :   // 'x'
            (tx_idx == 5'd2)  ? 8'h64 :   // 'd'
            (tx_idx == 5'd3)  ? 8'h3D :   // '='
            (tx_idx == 5'd4)  ? hex_asc(lat_txd[127:124]) :
            (tx_idx == 5'd5)  ? hex_asc(lat_txd[123:120]) :
            (tx_idx == 5'd6)  ? hex_asc(lat_txd[119:116]) :
            (tx_idx == 5'd7)  ? hex_asc(lat_txd[115:112]) :
            (tx_idx == 5'd8)  ? hex_asc(lat_txd[111:108]) :
            (tx_idx == 5'd9)  ? hex_asc(lat_txd[107:104]) :
            (tx_idx == 5'd10) ? hex_asc(lat_txd[103:100]) :
            (tx_idx == 5'd11) ? hex_asc(lat_txd[99:96])   :
            (tx_idx == 5'd12) ? hex_asc(lat_txd[95:92])   :
            (tx_idx == 5'd13) ? hex_asc(lat_txd[91:88])   :
            (tx_idx == 5'd14) ? hex_asc(lat_txd[87:84])   :
            (tx_idx == 5'd15) ? hex_asc(lat_txd[83:80])   :
            (tx_idx == 5'd16) ? hex_asc(lat_txd[79:76])   :
            (tx_idx == 5'd17) ? hex_asc(lat_txd[75:72])   :
            (tx_idx == 5'd18) ? hex_asc(lat_txd[71:68])   :
            (tx_idx == 5'd19) ? hex_asc(lat_txd[67:64])   :
            (tx_idx == 5'd20) ? hex_asc(lat_txd[63:60])   :
            (tx_idx == 5'd21) ? hex_asc(lat_txd[59:56])   :
            (tx_idx == 5'd22) ? hex_asc(lat_txd[55:52])   :
            (tx_idx == 5'd23) ? hex_asc(lat_txd[51:48])   :
            (tx_idx == 5'd24) ? hex_asc(lat_txd[47:44])   :
            (tx_idx == 5'd25) ? hex_asc(lat_txd[43:40])   :
            (tx_idx == 5'd26) ? hex_asc(lat_txd[39:36])   :
            (tx_idx == 5'd27) ? hex_asc(lat_txd[35:32])   :
            (tx_idx == 5'd28) ? hex_asc(lat_txd[31:28])   :
            (tx_idx == 5'd29) ? hex_asc(lat_txd[27:24])   :
            (tx_idx == 5'd30) ? hex_asc(lat_txd[23:20])   :
            (tx_idx == 5'd31) ? hex_asc(lat_txd[19:16])   :
            (tx_idx == 6'd32) ? hex_asc(lat_txd[15:12])   :
            (tx_idx == 6'd33) ? hex_asc(lat_txd[11:8])    :
            (tx_idx == 6'd34) ? hex_asc(lat_txd[7:4])     :
                                 hex_asc(lat_txd[3:0])     // 5'd35
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
        ) : (mode == 2'd2) ? (
            // ?rxd: "rxd=" + 16 hex (8 RX bytes)
            (tx_idx == 5'd0)  ? 8'h72 :   // 'r'
            (tx_idx == 5'd1)  ? 8'h78 :   // 'x'
            (tx_idx == 5'd2)  ? 8'h64 :   // 'd'
            (tx_idx == 5'd3)  ? 8'h3D :   // '='
            (tx_idx == 5'd4)  ? hex_asc(lat_rxd[63:60]) :
            (tx_idx == 5'd5)  ? hex_asc(lat_rxd[59:56]) :
            (tx_idx == 5'd6)  ? hex_asc(lat_rxd[55:52]) :
            (tx_idx == 5'd7)  ? hex_asc(lat_rxd[51:48]) :
            (tx_idx == 5'd8)  ? hex_asc(lat_rxd[47:44]) :
            (tx_idx == 5'd9)  ? hex_asc(lat_rxd[43:40]) :
            (tx_idx == 5'd10) ? hex_asc(lat_rxd[39:36]) :
            (tx_idx == 5'd11) ? hex_asc(lat_rxd[35:32]) :
            (tx_idx == 5'd12) ? hex_asc(lat_rxd[31:28]) :
            (tx_idx == 5'd13) ? hex_asc(lat_rxd[27:24]) :
            (tx_idx == 5'd14) ? hex_asc(lat_rxd[23:20]) :
            (tx_idx == 5'd15) ? hex_asc(lat_rxd[19:16]) :
            (tx_idx == 5'd16) ? hex_asc(lat_rxd[15:12]) :
            (tx_idx == 5'd17) ? hex_asc(lat_rxd[11:8])  :
            (tx_idx == 5'd18) ? hex_asc(lat_rxd[7:4])   :
                                 hex_asc(lat_rxd[3:0])     // 5'd19
        ) : (
            // ?net: "rx=XXXX tx=YYYY L=Z\r\n"
            (tx_idx == 5'd0)  ? 8'h72 :   // 'r'
            (tx_idx == 5'd1)  ? 8'h78 :   // 'x'
            (tx_idx == 5'd2)  ? 8'h3D :   // '='
            (tx_idx == 5'd3)  ? hex_asc(lat_rx[15:12]) :
            (tx_idx == 5'd4)  ? hex_asc(lat_rx[11:8])  :
            (tx_idx == 5'd5)  ? hex_asc(lat_rx[7:4])   :
            (tx_idx == 5'd6)  ? hex_asc(lat_rx[3:0])   :
            (tx_idx == 5'd7)  ? 8'h20 :   // ' '
            (tx_idx == 5'd8)  ? 8'h74 :   // 't'
            (tx_idx == 5'd9)  ? 8'h78 :   // 'x'
            (tx_idx == 5'd10) ? 8'h3D :   // '='
            (tx_idx == 5'd11) ? hex_asc(lat_tx[15:12]) :
            (tx_idx == 5'd12) ? hex_asc(lat_tx[11:8])  :
            (tx_idx == 5'd13) ? hex_asc(lat_tx[7:4])   :
            (tx_idx == 5'd14) ? hex_asc(lat_tx[3:0])   :
            (tx_idx == 5'd15) ? 8'h20 :   // ' '
            (tx_idx == 5'd16) ? 8'h4C :   // 'L'
            (tx_idx == 5'd17) ? 8'h3D :   // '='
            (tx_idx == 5'd18) ? (stat_lock ? 8'h31 : 8'h30) :
            (tx_idx == 5'd19) ? 8'h20 :   // ' '
            (tx_idx == 5'd20) ? 8'h52 :   // 'R'
            (tx_idx == 5'd21) ? 8'h3D :   // '='
            (tx_idx == 5'd22) ? hex_asc(dbg0[15:12]) :
            (tx_idx == 5'd23) ? hex_asc(dbg0[11:8])  :
            (tx_idx == 5'd24) ? 8'h20 :   // ' '
            (tx_idx == 5'd25) ? 8'h54 :   // 'T'
            (tx_idx == 5'd26) ? 8'h3D :   // '='
            (tx_idx == 5'd27) ? hex_asc(dbg0[7:4])   :
            (tx_idx == 5'd28) ? hex_asc(dbg0[3:0])   :
            (tx_idx == 5'd29) ? 8'h20 :   // ' '
            (tx_idx == 5'd30) ? 8'h59 :   // 'Y'
            (tx_idx == 5'd31) ? 8'h3D :   // '='
            (tx_idx == 5'd32) ? (dbg1 ? 8'h31 : 8'h30) :
            (tx_idx == 5'd33) ? 8'h0D :   // CR
                                8'h0A     // LF (6'd34)
        );

    always @(posedge clk50 or negedge reset_n) begin
        if (!reset_n) begin
            lat_rx<=0; lat_tx<=0; lat_txd<=0; lat_rxd<=0; lat_raw<=0; mode<=0;
            quiet_cnt<=0; tx_idx<=0; tx_cell<=0;
            tx_cnt8<=0; tx_active<=0; tx_line<=1'b1;
        end else begin
            if ((net_go || txd_go || rxd_go || raw_go) && !tx_active && quiet_cnt == 20'd0) begin
                lat_rx   <= rx_cnt;
                lat_tx   <= tx_cnt;
                lat_txd  <= txcap_s2;
                lat_rxd  <= rxcap_s2;
                lat_raw  <= rawcap_s2;
                mode     <= net_go ? 2'd0 : (txd_go ? 2'd1 : (rxd_go ? 2'd2 : 2'd3));
                quiet_cnt <= 20'd1000000;   // 20ms @50MHz
            end
            if (quiet_cnt > 0) quiet_cnt <= quiet_cnt - 20'd1;

            if (!tx_active) begin
                if (quiet_cnt == 20'd1) begin
                    // start sending when the quiet window expires
                    tx_active <= 1'b1;
                    tx_idx <= 5'd0;
                    tx_cell <= 4'd0;
                    tx_cnt8 <= 16'd0;
                    tx_line <= 1'b0;      // start bit of first byte
                end
            end else begin
                if (tx_cnt8 == 16'd5207) begin
                    tx_cnt8 <= 16'd0;
                    if (tx_cell == 4'd9) begin
                        // byte done (stop cell ended): advance byte
                        if (tx_idx == tx_last) begin
                            tx_active <= 1'b0;
                            tx_line <= 1'b1;   // release line back to console
                        end else begin
                            tx_idx <= tx_idx + 6'd1;
                            tx_line <= 1'b0;   // start bit of next byte
                        end
                        tx_cell <= 4'd0;
                    end else begin
                        tx_cell <= tx_cell + 4'd1;
                        if (tx_cell == 4'd8)
                            tx_line <= 1'b1;   // stop bit
                        else
                            tx_line <= tx_byte[tx_cell[2:0]];  // data bit LSB-first
                    end
                end else begin
                    tx_cnt8 <= tx_cnt8 + 16'd1;
                end
            end
        end
    end

    assign uart_tx_out = tx_active ? tx_line : uart_tx_in;

endmodule

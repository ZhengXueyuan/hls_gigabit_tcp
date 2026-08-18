`timescale 1ns / 1ps  
//////////////////////////////////////////////////////////////////////////////////
// Module Name:    ethernet_test 
//////////////////////////////////////////////////////////////////////////////////
module eth_test_genrx(
    input        sys_clk_50m,
    input       rst_n,

	output[3:0] rgmii_txd,
	output      rgmii_txctl,
	output      rgmii_txc,
	input[3:0]  rgmii_rxd,
	input       rgmii_rxctl,
	input       rgmii_rxc
    );
wire            reset_n;
(*mark_debug="true"*)wire   [ 7:0]   gmii_txd;
(*mark_debug="true"*)wire            gmii_tx_en;
(*mark_debug="true"*)wire            gmii_tx_er;
(*mark_debug="true"*)wire            gmii_tx_clk;
wire            gmii_crs;
wire            gmii_col;
(*mark_debug="true"*)wire   [ 7:0]   gmii_rxd;
(*mark_debug="true"*)wire            gmii_rx_dv;
(*mark_debug="true"*)wire            gmii_rx_er;
(*mark_debug="true"*)wire            gmii_rx_clk;
wire            duplex_mode;     // 1 full, 0 half
wire            rgmii_rxcpll;

(*mark_debug="true"*)wire  [31:0]    pack_total_len ;

(*mark_debug="true"*)wire [1:0]      speed      ;
(*mark_debug="true"*)wire            link       ;
wire            e_rx_dv    ;
wire [7:0]      e_rxd      ;
wire            e_tx_en    ;
wire [7:0]      e_txd      ;
wire            e_rst_n    ; 

assign duplex_mode = 1'b1;
 assign speed= 2'b10;
 assign link='b1;

util_gmii_to_rgmii util_gmii_to_rgmii_m0(
.reset(1'b0),

.rgmii_td           (rgmii_txd      ),
.rgmii_tx_ctl       (rgmii_txctl    ),
.rgmii_txc          (rgmii_txc      ),
.rgmii_rd_i           (rgmii_rxd      ),
.rgmii_rx_ctl_i       (rgmii_rxctl    ),
.gmii_rx_clk        (gmii_rx_clk    ),
.gmii_txd           (e_txd          ),
.gmii_tx_en         (e_tx_en        ),
.gmii_tx_er         (1'b0           ),
.gmii_tx_clk        (gmii_tx_clk    ),
.gmii_crs           (gmii_crs       ),
.gmii_col           (gmii_col       ),
.gmii_rxd           (gmii_rxd       ),
.rgmii_rxc          (rgmii_rxc      ),//add
.gmii_rx_dv         (gmii_rx_dv     ),
.gmii_rx_er         (gmii_rx_er     ),
.speed_selection    (speed          ),
.duplex_mode        (duplex_mode    )
);
// --- DEMO-CLONE generator (replaces gmii_arbi + mac_test) ---
// Sends the k720 ipsend frame (72B GMII, correct CRC32) at ~1Hz, wired
// EXACTLY as wrapper_min: combinational demo_out mux -> e_txd/e_txen.
    reg [26:0] demo_cnt;
    reg [6:0]  demo_idx;
    reg        demo_sending;
    reg [31:0] demo_crc;
    wire       demo_tick = (demo_cnt == 27'd124999999);

    function [31:0] eth_crc32;
        // FIXED 2026-08-18: the old unreflected (MSB-first) CRC emitted the
        // bit-reversed FCS on the wire (21 27 d6 68 instead of the correct
        // 63 f9 a3 ca for the demo ARP frame) — the PC NIC silently dropped
        // every demo-clone frame as an FCS error. This is the standard
        // reflected CRC-32 (IEEE 802.3, same as zlib.crc32); wire order of
        // the final complement stays MSB-first per byte.
        input [31:0] crc;
        input [7:0]  data;
        reg [31:0] c;
        integer k;
        begin
            c = crc ^ data;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0]) c = (c >> 1) ^ 32'hEDB88320;
                else      c = (c >> 1);
            end
            eth_crc32 = c;
        end
    endfunction

    function [7:0] demo_byte;
        input [6:0] idx;
        begin
            case (idx)
                7'd0, 7'd1, 7'd2, 7'd3, 7'd4, 7'd5, 7'd6: demo_byte = 8'h55;
                7'd7:                                     demo_byte = 8'hD5;
                7'd8, 7'd9, 7'd10, 7'd11, 7'd12, 7'd13:  demo_byte = 8'hFF;
                7'd14: demo_byte = 8'h00; 7'd15: demo_byte = 8'h0A;
                7'd16: demo_byte = 8'h35; 7'd17: demo_byte = 8'h01;
                7'd18: demo_byte = 8'hFE; 7'd19: demo_byte = 8'hC0;
                7'd20: demo_byte = 8'h08; 7'd21: demo_byte = 8'h06;
                7'd22: demo_byte = 8'h00; 7'd23: demo_byte = 8'h01;
                7'd24: demo_byte = 8'h08; 7'd25: demo_byte = 8'h00;
                7'd26: demo_byte = 8'h06; 7'd27: demo_byte = 8'h04;
                7'd28: demo_byte = 8'h00; 7'd29: demo_byte = 8'h01;
                7'd30: demo_byte = 8'h00; 7'd31: demo_byte = 8'h0A;
                7'd32: demo_byte = 8'h35; 7'd33: demo_byte = 8'h01;
                7'd34: demo_byte = 8'hFE; 7'd35: demo_byte = 8'hC0;
                7'd36: demo_byte = 8'hC0; 7'd37: demo_byte = 8'hA8;
                7'd38: demo_byte = 8'h00; 7'd39: demo_byte = 8'h02;
                7'd40, 7'd41, 7'd42, 7'd43, 7'd44, 7'd45: demo_byte = 8'hFF;
                7'd46: demo_byte = 8'hC0; 7'd47: demo_byte = 8'hA8;
                7'd48: demo_byte = 8'h00; 7'd49: demo_byte = 8'h03;
                7'd50, 7'd51, 7'd52, 7'd53, 7'd54, 7'd55, 7'd56, 7'd57, 7'd58, 7'd59:
                    demo_byte = 8'h00;
                default: demo_byte = 8'h00;
            endcase
        end
    endfunction

    always @(posedge gmii_tx_clk or negedge rst_n) begin
        if (!rst_n) begin
            demo_cnt<=0; demo_idx<=0; demo_sending<=0; demo_crc<=32'hFFFFFFFF;
        end else begin
            if (demo_cnt >= 27'd124999999) demo_cnt <= 27'd0;
            else                            demo_cnt <= demo_cnt + 27'd1;
            if (demo_tick && !demo_sending) begin
                demo_sending <= 1'b1;
                demo_idx     <= 7'd0;
                demo_crc     <= 32'hFFFFFFFF;
            end else if (demo_sending) begin
                if (demo_idx >= 7'd8 && demo_idx < 7'd68)
                    demo_crc <= eth_crc32(demo_crc, demo_byte(demo_idx));
                if (demo_idx == 7'd71) demo_sending <= 1'b0;
                demo_idx <= demo_idx + 7'd1;
            end
        end
    end
    wire [31:0] demo_fcs = ~demo_crc;
    wire [7:0] demo_out =
        (demo_idx < 7'd68) ? demo_byte(demo_idx) :
        // FIX 2026-08-18 #2: the board's PHY/NIC chain expects the FCS in
        // LSB-first byte order (demo's wire FCS = CA A3 F9 63 = zlib register
        // little-endian). MSB-first (63 F9 A3 CA) frames were silently dropped.
        (demo_idx == 7'd68) ? demo_fcs[7:0]  :
        (demo_idx == 7'd69) ? demo_fcs[15:8] :
        (demo_idx == 7'd70) ? demo_fcs[23:16] :
                              demo_fcs[31:24];

    // drive the RGMII util module's GMII inputs directly (like wrapper_min)
    assign e_tx_en  = demo_sending;
    assign e_txd    = demo_out;
    assign e_rst_n  = rst_n;
    assign pack_total_len = 32'd125000000;

    // RX sink: consume gmii_rxd/gmii_rx_dv (keeps the RX IDELAY+IDDR chain
    // and IDELAYCTRL alive, same as the working demo rebuild)
    reg [7:0] rx_sink_d;
    reg       rx_sink_dv;
    reg [15:0] rx_sink_cnt;
    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin rx_sink_d<=0; rx_sink_dv<=0; rx_sink_cnt<=0; end
        else begin
            rx_sink_d <= gmii_rxd;
            rx_sink_dv <= gmii_rx_dv;
            if (gmii_rx_dv) rx_sink_cnt <= rx_sink_cnt + 16'd1;
        end
    end
    assign e_rx_dv  = rx_sink_dv;
    assign e_rxd    = rx_sink_d;

endmodule
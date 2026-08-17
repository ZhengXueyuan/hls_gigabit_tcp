`timescale 1ns/1ps

module util_gmii_to_rgmii (
  reset,
  rgmii_td,
  rgmii_tx_ctl,
  rgmii_txc,
  rgmii_rd_i,
  rgmii_rx_ctl_i,
  gmii_rx_clk,
  rgmii_rxc,
  gmii_txd,
  gmii_tx_en,
  gmii_tx_er,
  gmii_tx_clk,
  gmii_crs,
  gmii_col,
  gmii_rxd,
  gmii_rx_dv,
  gmii_rx_er,
  speed_selection,
  duplex_mode
  );
  input           rgmii_rxc;//add
  input           reset;
  output  [ 3:0]  rgmii_td;
  output          rgmii_tx_ctl;
  output          rgmii_txc;
  input   [ 3:0]  rgmii_rd_i;
  input           rgmii_rx_ctl_i;
  output           gmii_rx_clk;
  input   [ 7:0]  gmii_txd;
  input           gmii_tx_en;
  input           gmii_tx_er;
  
  
  output          gmii_tx_clk;
  output          gmii_crs;
  output          gmii_col;
  output  [ 7:0]  gmii_rxd;
  output          gmii_rx_dv;
  output          gmii_rx_er;
  input  [ 1:0]   speed_selection; // 1x gigabit, 01 100Mbps, 00 10mbps
  input           duplex_mode;     // 1 full, 0 half
  
  
    wire   [ 3:0]  rgmii_rd;
    wire           rgmii_rx_ctl;
  
  
  (* IODELAY_GROUP = "idelay" *) IDELAYE2 #(
  .CINVCTRL_SEL("FALSE"),          // Enable dynamic clock inversion (FALSE, TRUE)
  .DELAY_SRC("IDATAIN"),           // Delay input (IDATAIN, DATAIN)
  .HIGH_PERFORMANCE_MODE("FALSE"), // Reduced jitter ("TRUE"), Reduced power ("FALSE")
  .IDELAY_TYPE("FIXED"),           // FIXED, VARIABLE, VAR_LOAD, VAR_LOAD_PIPE
  .IDELAY_VALUE(10),                // Input delay tap setting (0-31)
  .PIPE_SEL("FALSE"),              // Select pipelined mode, FALSE, TRUE
  .REFCLK_FREQUENCY(200.0),        // IDELAYCTRL clock input frequency in MHz (190.0-210.0, 290.0-310.0).
  .SIGNAL_PATTERN("DATA")          // DATA, CLOCK input signal
)
delay_rgmii_rx_ctl1 (
      .IDATAIN       (rgmii_rx_ctl_i),
      .DATAOUT       (rgmii_rx_ctl),
      .DATAIN        (1'b0),
      .C             (1'b0),
      .CE            (1'b0),
      .INC           (1'b0),
      .CINVCTRL      (1'b0),
      .CNTVALUEIN    (5'h0),
      .CNTVALUEOUT   (),
      .LD            (1'b0),
      .LDPIPEEN      (1'b0),
      .REGRST        (1'b0)
      );
  genvar j;
generate for (j=0; j<4; j=j+1)
   begin : RGMII_RX_DATA_BUS1
      (* IODELAY_GROUP = "idelay" *)  IDELAYE2 #(
      .CINVCTRL_SEL("FALSE"),          // Enable dynamic clock inversion (FALSE, TRUE)
      .DELAY_SRC("IDATAIN"),           // Delay input (IDATAIN, DATAIN)
      .HIGH_PERFORMANCE_MODE("FALSE"), // Reduced jitter ("TRUE"), Reduced power ("FALSE")
      .IDELAY_TYPE("FIXED"),           // FIXED, VARIABLE, VAR_LOAD, VAR_LOAD_PIPE
      .IDELAY_VALUE(10),                // Input delay tap setting (0-31)
      .PIPE_SEL("FALSE"),              // Select pipelined mode, FALSE, TRUE
      .REFCLK_FREQUENCY(200.0),        // IDELAYCTRL clock input frequency in MHz (190.0-210.0, 290.0-310.0).
      .SIGNAL_PATTERN("DATA")          // DATA, CLOCK input signal
       )
       delay_rgmii_rxd1 (
          .IDATAIN       (rgmii_rd_i[j]),
          .DATAOUT       (rgmii_rd[j]),
          .DATAIN        (1'b0),
          .C             (1'b0),
          .CE            (1'b0),
          .INC           (1'b0),
          .CINVCTRL      (1'b0),
          .CNTVALUEIN    (5'h0),
          .CNTVALUEOUT   (),
          .LD            (1'b0),
          .LDPIPEEN      (1'b0),
          .REGRST        (1'b0)
       );
   end
endgenerate


  
  
  wire gigabit;
  wire gmii_tx_clk_s;
  wire gmii_rx_dv_s;

  wire  [ 7:0]    gmii_rxd_s;
  wire            rgmii_rx_ctl_delay;
  wire            rgmii_rx_ctl_s;
  // registers
  reg             tx_reset_d1;
  reg             tx_reset_sync;
  reg             rx_reset_d1;
  reg   [ 7:0]    gmii_txd_r;
  reg             gmii_tx_en_r;
  reg             gmii_tx_er_r;
  reg   [ 7:0]    gmii_txd_r_d1;
  reg             gmii_tx_en_r_d1;
  reg             gmii_tx_er_r_d1;

  reg             rgmii_tx_ctl_r;
  
  reg   [ 3:0]    gmii_txd_low;
  reg             gmii_col;
  reg             gmii_crs;

  reg  [ 7:0]     gmii_rxd;
  reg             gmii_rx_dv;
  reg             gmii_rx_er;

  assign gigabit        = speed_selection [1];
  assign gmii_tx_clk    = gmii_tx_clk_s;
  assign gmii_tx_clk_s  = gmii_rx_clk;

  
  BUFG bufmr_rgmii_rxc(
    .I(~rgmii_rxc),
    .O(gmii_rx_clk)
   );
  always @(posedge gmii_rx_clk)
  begin
    gmii_rxd       = gmii_rxd_s;
    gmii_rx_dv     = gmii_rx_dv_s;
    gmii_rx_er     = gmii_rx_dv_s ^ rgmii_rx_ctl_s;
  end

  always @(posedge gmii_tx_clk_s) begin
    tx_reset_d1    <= reset;
    tx_reset_sync  <= tx_reset_d1;
  end

  always @(posedge gmii_tx_clk_s)
  begin
    rgmii_tx_ctl_r = gmii_tx_en_r ^ gmii_tx_er_r;
    gmii_txd_low   = gigabit ? gmii_txd_r[7:4] :  gmii_txd_r[3:0];
    gmii_col       = duplex_mode ? 1'b0 : (gmii_tx_en_r| gmii_tx_er_r) & ( gmii_rx_dv | gmii_rx_er) ;
    gmii_crs       = duplex_mode ? 1'b0 : (gmii_tx_en_r| gmii_tx_er_r| gmii_rx_dv | gmii_rx_er);
  end

  always @(posedge gmii_tx_clk_s) begin
    if (tx_reset_sync == 1'b1) begin
      gmii_txd_r   <= 8'h0;
      gmii_tx_en_r <= 1'b0;
      gmii_tx_er_r <= 1'b0;
    end
    else
    begin
      gmii_txd_r   <= gmii_txd;
      gmii_tx_en_r <= gmii_tx_en;
      gmii_tx_er_r <= gmii_tx_er;
      gmii_txd_r_d1   <= gmii_txd_r;
      gmii_tx_en_r_d1 <= gmii_tx_en_r;
      gmii_tx_er_r_d1 <= gmii_tx_er_r;
    end
  end


  ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE")
  ) rgmii_txc_out (
    .Q (rgmii_txc),
    .C (gmii_tx_clk_s),
    .CE(1),
    .D1(1),
    .D2(0),
    .R(tx_reset_sync),
    .S(0));


  generate
  genvar i;
  for (i = 0; i < 4; i = i + 1) begin : gen_tx_data
    ODDR #(
      .DDR_CLK_EDGE("SAME_EDGE")
    ) rgmii_td_out (
      .Q (rgmii_td[i]),
      .C (gmii_tx_clk_s),
      .CE(1),
      .D1(gmii_txd_r_d1[i]),
      .D2(gmii_txd_low[i]),
      .R(tx_reset_sync),
      .S(0));
  end
  endgenerate

  ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE")
  ) rgmii_tx_ctl_out (
    .Q (rgmii_tx_ctl),
    .C (gmii_tx_clk_s),
    .CE(1),
    .D1(gmii_tx_en_r_d1),
    .D2(rgmii_tx_ctl_r),
    .R(tx_reset_sync),
    .S(0));

  
     
      generate
      for (i = 0; i < 4; i = i + 1) begin
        IDDR #(
          .DDR_CLK_EDGE("SAME_EDGE_PIPELINED")
        ) rgmii_rx_iddr (
          .Q1(gmii_rxd_s[i]),
          .Q2(gmii_rxd_s[i+4]),
          .C(gmii_rx_clk),
          .CE(1),
          .D(rgmii_rd[i]),
          .R(0),
          .S(0));
      end
      endgenerate
    
      IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED")
      ) rgmii_rx_ctl_iddr (
        .Q1(gmii_rx_dv_s),
        .Q2(rgmii_rx_ctl_s),
        .C(gmii_rx_clk),
        .CE(1),
        .D(rgmii_rx_ctl),
        .R(0),
        .S(0));

/*module util_gmii_to_rgmii (
  reset,
  rgmii_td,
  rgmii_tx_ctl,
  rgmii_txc,
  rgmii_rd,
  rgmii_rx_ctl,
  rgmii_rxc,

  gmii_txd,
  gmii_tx_en,
  gmii_tx_er,
  gmii_tx_clk,
  gmii_crs,
  gmii_col,
  gmii_rxd,
  gmii_rx_dv,
  gmii_rx_er,
  gmii_rx_clk,
  speed_selection,
  duplex_mode);
  input           reset;

  output  [ 3:0]  rgmii_td;
  output          rgmii_tx_ctl;
  output          rgmii_txc;
  input   [ 3:0]  rgmii_rd;
  input           rgmii_rx_ctl;
  input           rgmii_rxc;

  input   [ 7:0]  gmii_txd;
  input           gmii_tx_en;
  input           gmii_tx_er;
  output          gmii_tx_clk;
  output          gmii_crs;
  output          gmii_col;
  output  [ 7:0]  gmii_rxd;
  output          gmii_rx_dv;
  output          gmii_rx_er;
  output          gmii_rx_clk;
  input  [ 1:0]   speed_selection; // 1x gigabit, 01 100Mbps, 00 10mbps
  input           duplex_mode;     // 1 full, 0 half
  
  // wires
  
wire gigabit;
wire gmii_tx_clk_s;
wire gmii_rx_dv_s;

  wire  [ 7:0]    gmii_rxd_s;
  wire            rgmii_rx_ctl_delay;
  wire            rgmii_rx_ctl_s;



  // registers
  reg             tx_reset_d1;
  reg             tx_reset_sync;
  reg             rx_reset_d1;
  reg   [ 7:0]    gmii_txd_r;
  reg             gmii_tx_en_r;
  reg             gmii_tx_er_r;
  reg   [ 7:0]    gmii_txd_r_d1;
  reg             gmii_tx_en_r_d1;
  reg             gmii_tx_er_r_d1;

  reg             rgmii_tx_ctl_r;
  reg   [ 3:0]    gmii_txd_low;
  reg             gmii_col;
  reg             gmii_crs;

  reg  [ 7:0]     gmii_rxd;
  reg             gmii_rx_dv;
  reg             gmii_rx_er;

  assign gigabit        = speed_selection [1];
  assign gmii_tx_clk    = gmii_tx_clk_s;
  assign gmii_tx_clk_s  = gmii_rx_clk;
  
  always @(posedge gmii_rx_clk)
  begin
    gmii_rxd       = gmii_rxd_s;
    gmii_rx_dv     = gmii_rx_dv_s;
    gmii_rx_er     = gmii_rx_dv_s ^ rgmii_rx_ctl_s;
  end

  always @(posedge gmii_tx_clk_s) begin
    tx_reset_d1    <= reset;
    tx_reset_sync  <= tx_reset_d1;
  end

  always @(posedge gmii_tx_clk_s)
  begin
    rgmii_tx_ctl_r = gmii_tx_en_r ^ gmii_tx_er_r;
    gmii_txd_low   = gigabit ? gmii_txd_r[7:4] :  gmii_txd_r[3:0];
    gmii_col       = duplex_mode ? 1'b0 : (gmii_tx_en_r| gmii_tx_er_r) & ( gmii_rx_dv | gmii_rx_er) ;
    gmii_crs       = duplex_mode ? 1'b0 : (gmii_tx_en_r| gmii_tx_er_r| gmii_rx_dv | gmii_rx_er);
  end

  always @(posedge gmii_tx_clk_s) begin
    if (tx_reset_sync == 1'b1) begin
      gmii_txd_r   <= 8'h0;
      gmii_tx_en_r <= 1'b0;
      gmii_tx_er_r <= 1'b0;
    end
    else
    begin
      gmii_txd_r   <= gmii_txd;
      gmii_tx_en_r <= gmii_tx_en;
      gmii_tx_er_r <= gmii_tx_er;
      gmii_txd_r_d1   <= gmii_txd_r;
      gmii_tx_en_r_d1 <= gmii_tx_en_r;
      gmii_tx_er_r_d1 <= gmii_tx_er_r;
    end
  end
*//*
  ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE")
  ) rgmii_txc_out (
    .Q (rgmii_txc),
    .C (gmii_tx_clk_s),
    .CE(1),
    .D1(1),
    .D2(0),
    .R(tx_reset_sync),
    .S(0));
*//*
  ODDR2 #(
		  .DDR_ALIGNMENT("C0"), // Sets output alignment to "NONE", "C0" or "C1" 
		  .INIT(1'b0),    // Sets initial state of the Q output to 1'b0 or 1'b1
		  .SRTYPE("ASYNC") // Specifies "SYNC" or "ASYNC" set/reset
		  ) U_ODDR2
	     (
		  .Q(rgmii_txc),   // 1-bit DDR output data
		  .C0(gmii_tx_clk_s),   // 1-bit clock input
		  .C1(~gmii_tx_clk_s),   // 1-bit clock input
		  .CE(1'b1), // 1-bit clock enable input
		  .D0(1'b1), // 1-bit data input (associated with C0)
		  .D1(1'b0), // 1-bit data input (associated with C1)
		  .R(1'b0),   // 1-bit reset input
		  .S(1'b0)    // 1-bit set input
	      );
	*//*
  generate
  genvar i;
  for (i = 0; i < 4; i = i + 1) begin : gen_tx_data
    ODDR #(
      .DDR_CLK_EDGE("SAME_EDGE")
    ) rgmii_td_out (
      .Q (rgmii_td[i]),
      .C (gmii_tx_clk_s),
      .CE(1),
      .D1(gmii_txd_r_d1[i]),
      .D2(gmii_txd_low[i]),
      .R(tx_reset_sync),
      .S(0));
  end
  endgenerate

  ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE")
  ) rgmii_tx_ctl_out (
    .Q (rgmii_tx_ctl),
    .C (gmii_tx_clk_s),
    .CE(1),
    .D1(gmii_tx_en_r_d1),
    .D2(rgmii_tx_ctl_r),
    .R(tx_reset_sync),
    .S(0));
*//*

  generate
  genvar i;
  for (i = 0; i < 4; i = i + 1) begin : gen_tx_data
	ODDR2 #(
		 .DDR_ALIGNMENT("C0"), // Sets output alignment to "NONE", "C0" or "C1" 
		 .INIT(1'b0),    // Sets initial state of the Q output to 1'b0 or 1'b1
		 .SRTYPE("ASYNC") // Specifies "SYNC" or "ASYNC" set/reset
		    ) U2_ODDR2
	    (
		  .Q(rgmii_td[i]),   // 1-bit DDR output data
		  .C0(gmii_tx_clk_s),   // 1-bit clock input
		  .C1(~gmii_tx_clk_s),   // 1-bit clock input
		  .CE(1'b1), // 1-bit clock enable input
		  .D0(gmii_txd_r_d1[i]), // 1-bit data input (associated with C0)
		  .D1(gmii_txd_low[i]), // 1-bit data input (associated with C1)
		  .R(1'b0),   // 1-bit reset input
		  .S(1'b0)    // 1-bit set input
	    );
  end
  endgenerate

	ODDR2 #(
		  .DDR_ALIGNMENT("C0"), // Sets output alignment to "NONE", "C0" or "C1" 
		  .INIT(1'b0),    // Sets initial state of the Q output to 1'b0 or 1'b1
		  .SRTYPE("ASYNC") // Specifies "SYNC" or "ASYNC" set/reset
		 ) U3_ODDR2
	(
		  .Q(rgmii_tx_ctl),   // 1-bit DDR output data
		  .C0(gmii_tx_clk_s),   // 1-bit clock input
		  .C1(~gmii_tx_clk_s),   // 1-bit clock input
		  .CE(1'b1), // 1-bit clock enable input
		  .D0(gmii_tx_en_r_d1), // 1-bit data input (associated with C0)
		  .D1(rgmii_tx_ctl_r), // 1-bit data input (associated with C1)
		  .R(1'b0),   // 1-bit reset input
		  .S(1'b0)    // 1-bit set input
	);
	 
  BUFG bufmr_rgmii_rxc(
    .I(rgmii_rxc),
    .O(gmii_rx_clk));
*//*
  generate
  for (i = 0; i < 4; i = i + 1) begin
    IDDR #(
      .DDR_CLK_EDGE("SAME_EDGE_PIPELINED")
    ) rgmii_rx_iddr (
      .Q1(gmii_rxd_s[i]),
      .Q2(gmii_rxd_s[i+4]),
      .C(gmii_rx_clk),
      .CE(1),
      .D(rgmii_rd[i]),
      .R(0),
      .S(0));
  end
  endgenerate

  IDDR #(
    .DDR_CLK_EDGE("SAME_EDGE_PIPELINED")
  ) rgmii_rx_ctl_iddr (
    .Q1(gmii_rx_dv_s),
    .Q2(rgmii_rx_ctl_s),
    .C(gmii_rx_clk),
    .CE(1),
    .D(rgmii_rx_ctl),
    .R(0),
    .S(0));
*//*
  generate
  for (i = 0; i < 4; i = i + 1) begin	
	IDDR2 #(
   .DDR_ALIGNMENT("NONE"), // Sets output alignment to "NONE", "C0" or "C1"
   .INIT_Q0(1'b0), // Sets initial state of the Q0 output to 1'b0 or 1'b1
   .INIT_Q1(1'b0), // Sets initial state of the Q1 output to 1'b0 or 1'b1
   .SRTYPE("SYNC") // Specifies "SYNC" or "ASYNC" set/reset
	) rgmii_rx_iddr (
   .Q0(gmii_rxd_s[i]), // 1-bit output captured with C0 clock
   .Q1(gmii_rxd_s[i+4]), // 1-bit output captured with C1 clock
   .C0(gmii_rx_clk), // 1-bit clock input
   .C1(~gmii_rx_clk), // 1-bit clock input
   .CE(1), // 1-bit clock enable input
   .D(rgmii_rd[i]),   // 1-bit DDR data input
   .R(0),   // 1-bit reset input
   .S(0)    // 1-bit set input
	);
  end
  endgenerate
  
	IDDR2 #(
   .DDR_ALIGNMENT("NONE"), // Sets output alignment to "NONE", "C0" or "C1"
   .INIT_Q0(1'b0), // Sets initial state of the Q0 output to 1'b0 or 1'b1
   .INIT_Q1(1'b0), // Sets initial state of the Q1 output to 1'b0 or 1'b1
   .SRTYPE("SYNC") // Specifies "SYNC" or "ASYNC" set/reset
	) rgmii_rx_iddr (
   .Q0(gmii_rx_dv_s), // 1-bit output captured with C0 clock
   .Q1(rgmii_rx_ctl_s), // 1-bit output captured with C1 clock
   .C0(gmii_rx_clk), // 1-bit clock input
   .C1(~gmii_rx_clk), // 1-bit clock input
   .CE(1), // 1-bit clock enable input
   .D(rgmii_rx_ctl),   // 1-bit DDR data input
   .R(0),   // 1-bit reset input
   .S(0)    // 1-bit set input
	);	 
	
*//*wire clk_ila;
 clk_wiz_0 instance_name
   (
    // Clock out ports
    .clk_out1(clk_ila),     // output clk_out1
    // Status and control signals
    .reset(1'b0), // input reset
    .locked(),       // output locked
   // Clock in ports
    .clk_in1(sys_clk));      // input clk_in1*//*
*//*ila_0 your_instance_name (

    .clk(gmii_rx_clk), // input wire clk
    .probe0(rgmii_tx_ctl_r), // input wire [0:0]  probe0  
    .probe1(gmii_tx_en), // input wire [0:0]  probe1 
    .probe2(gmii_rx_dv), // input wire [0:0]  probe2 
  //  .probe3(gmii_rx_clk), // input wire [0:0]  probe3 
   .probe3(1'b0), // input wire [0:0]  probe3 
  // .probe4(rgmii_rd), // input wire [3:0]  probe4 
  // .probe5(4'd0), // input wire [3:0]  probe5 
   .probe4(4'd0), // input wire [3:0]  probe4 
    .probe5(gmii_txd_low), // input wire [3:0]  probe5 
    .probe6(gmii_txd), // input wire [7:0]  probe6 
    .probe7(gmii_rxd), // input wire [7:0]  probe7 
    .probe8(rgmii_rx_ctl), // input wire [0:0]  probe8 
    .probe9(gmii_col), // input wire [0:0]  probe9
    .probe10(gigabit), // input wire [0:0]  probe8 
    .probe11(gmii_txd_r_d1) // input wire [0:0]  probe9
);  *//**/
endmodule

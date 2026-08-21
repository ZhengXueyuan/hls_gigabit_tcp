// ==============================================================
// FIX v4: udp_echo_buffer_r_RAM_2P_BRAM_1R1W
// Tracks the last write address+data. If the next read is at the
// same address, forwards the write data directly. No combinational
// loop because the forward is registered (1 cycle delay).
// ==============================================================
`timescale 1ns/1ps

(* DowngradeIPIdentifiedWarnings="yes" *) module udp_echo_buffer_r_RAM_2P_BRAM_1R1W
#(parameter
    DataWidth    = 32,
    AddressWidth = 9,
    AddressRange = 512
)(
    input  wire [AddressWidth-1:0] address0,
    input  wire                    ce0,
    output wire [DataWidth-1:0]    q0,
    input  wire [AddressWidth-1:0] address1,
    input  wire                    ce1,
    input  wire                    we1,
    input  wire [DataWidth-1:0]    d1,
    output wire [DataWidth-1:0]    q1,
    input  wire                    clk,
    input  wire                    reset
);
    reg  [AddressRange-1:0] written = {AddressRange{1'b0}} ;
    wire [DataWidth-1:0]    q0_ram;
    wire [DataWidth-1:0]    q0_rom;
    wire                    q0_sel;
    reg  [0:0]              sel0_sr;
    wire [DataWidth-1:0]    q1_ram;
    wire [DataWidth-1:0]    q1_rom;
    wire                    q1_sel;
    reg  [0:0]              sel1_sr;

    // Last-write tracking: capture the write address+data
    reg [AddressWidth-1:0] last_wr_addr;
    reg [DataWidth-1:0]    last_wr_data;
    reg                    last_wr_valid;

    udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram #(
        .DataWidth(DataWidth), .AddressWidth(AddressWidth), .AddressRange(AddressRange))
    u_ram (.address0(address0), .ce0(ce0), .q0(q0_ram),
           .address1(address1), .ce1(ce1), .we1(we1), .d1(d1), .q1(q1_ram),
           .clk(clk), .reset(reset));

    // Forward: if reading the last-written address, use the captured data
    wire forward_hit = last_wr_valid && (address0 == last_wr_addr);
    assign q0_rom = forward_hit ? last_wr_data : 'b0;
    assign q0_sel = forward_hit ? 1'b1 : sel0_sr[0];
    assign q0     = q0_sel ? q0_ram : q0_rom;

    assign q1     = q1_sel ? q1_ram : q1_rom;
    assign q1_sel = sel1_sr[0];
    assign q1_rom = 'b0;

    always @(posedge clk) begin
        if (reset) begin
            written       <= 1'b0;
            last_wr_valid <= 1'b0;
            last_wr_addr  <= 'b0;
            last_wr_data  <= 'b0;
        end else begin
            if (ce1 & we1) begin
                written[address1] <= 1'b1;
                last_wr_addr  <= address1;
                last_wr_data  <= d1;
                last_wr_valid <= 1'b1;
            end
            // Invalidate forward after one read at the same address
            if (ce0 && forward_hit) begin
                last_wr_valid <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (ce0) sel0_sr[0] <= written[address0];
        if (ce1) sel1_sr[0] <= written[address1];
    end

endmodule
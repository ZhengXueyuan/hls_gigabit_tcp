// ==============================================================
// REPLACEMENT for udp_echo_buffer_r_RAM_2P_BRAM_1R1W
// Fix: combinational read of `written` array instead of registered
// (sel0_sr). This removes the 1-cycle delay between write and
// read-acknowledge, so the first read of any address returns the
// correct RAM data instead of 0 (ROM fallback).
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
    input  wire                    clk,
    input  wire                    reset
);
    //------------------------Local signal-------------------
    reg  [AddressRange-1:0] written = {AddressRange{1'b0}} ;
    wire [DataWidth-1:0]    q0_ram;

    //------------------------Instantiation------------------
    udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram #(
        .DataWidth(DataWidth),
        .AddressWidth(AddressWidth),
        .AddressRange(AddressRange))
    udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram_u(
        .address0 ( address0 ),
        .ce0      ( ce0 ),
        .q0       ( q0_ram ),
        .address1 ( address1 ),
        .ce1      ( ce1 ),
        .we1      ( we1 ),
        .d1       ( d1 ),
        .clk      ( clk ),
        .reset    ( reset )
    );
    //------------------------Body---------------------------
    // FIX: combinational read of `written` — no 1-cycle delay.
    // The write to `written[address1]` and read from `written[address0]`
    // happen in the same cycle. If address0 == address1, the write
    // data is forwarded combinationally (the BRAM itself handles
    // WRITE_FIRST or READ_FIRST based on its configuration).
    assign q0 = written[address0] ? q0_ram : 'b0;

    always @(posedge clk) begin
        if (reset)
            written <= 1'b0;
        else begin
            if (ce1 & we1) begin
                written[address1] <= 1'b1;
            end
        end
    end

endmodule
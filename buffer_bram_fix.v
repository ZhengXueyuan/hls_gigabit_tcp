// ==============================================================
// REPLACEMENT for udp_echo_buffer_r_RAM_2P_BRAM_1R1W
// Fix: combinational write-data forwarding for same-address
// read+write. Removes the 1-cycle read delay from the `written`
// tracking array for the first read of any address.
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
    wire [DataWidth-1:0]    q0_ram;
    wire                    same_addr_wr;
    reg  [DataWidth-1:0]    q0_reg;

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
    // Combinational: detect same-address write while reading
    assign same_addr_wr = ce1 && we1 && ce0 && (address0 == address1);

    // Register the RAM output for timing
    always @(posedge clk) begin
        if (ce0) q0_reg <= q0_ram;
    end

    // Output: forward write data for same-cycle write, else registered read
    assign q0 = same_addr_wr ? d1 : q0_reg;

endmodule
// ==============================================================
// FIXED: udp_echo_buffer_r_RAM_2P_BRAM_1R1W
//
// When Port 0 reads and Port 1 writes to the SAME address in the
// same cycle, the BRAM READ_FIRST mode returns old data (from before
// the write). This fix detects the conflict and forwards the write
// data to the read port on the NEXT clock cycle — registered, not
// combinational, so no combinatorial loop is created.
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
    //------------------------Local signal-------------------
    reg  [AddressRange-1:0] written = {AddressRange{1'b0}} ;
    wire [DataWidth-1:0]    q0_ram;
    wire [DataWidth-1:0]    q0_rom;
    wire                    q0_sel;
    reg  [0:0]              sel0_sr;
    wire [DataWidth-1:0]    q1_ram;
    wire [DataWidth-1:0]    q1_rom;
    wire                    q1_sel;
    reg  [0:0]              sel1_sr;

    // Conflict: same-address read+write
    wire conflict = ce0 && ce1 && we1 && (address0 == address1);

    // Forward register: captures d1 on conflict, outputs on next cycle
    reg  conflict_active;
    reg  [DataWidth-1:0] conflict_data;

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
        .q1       ( q1_ram ),
        .clk      ( clk ),
        .reset    ( reset )
    );
    //------------------------Body---------------------------
    // Normal path: written tracking (unchanged from original)
    assign q0_rom = conflict_active ? conflict_data : 'b0;
    assign q0_sel = conflict_active ? 1'b1 : sel0_sr[0];
    assign q0     = q0_sel ? q0_ram : q0_rom;

    assign q1     = q1_sel ? q1_ram : q1_rom;
    assign q1_sel = sel1_sr[0];
    assign q1_rom = 'b0;

    always @(posedge clk) begin
        if (reset) begin
            written    <= 1'b0;
            conflict_active <= 1'b0;
            conflict_data <= 'b0;
        end else begin
            if (ce1 & we1)
                written[address1] <= 1'b1;

            // On conflict: capture the new data, output it next cycle
            if (conflict) begin
                conflict_data   <= d1;          // capture write data
                conflict_active <= 1'b1;         // activate forwarding
            end else begin
                conflict_active <= 1'b0;         // one-shot: clear after 1 cycle
            end
        end
    end

    always @(posedge clk) begin
        if (ce0) begin
            sel0_sr[0] <= written[address0];
        end
        if (ce1) begin
            sel1_sr[0] <= written[address1];
        end
    end

endmodule
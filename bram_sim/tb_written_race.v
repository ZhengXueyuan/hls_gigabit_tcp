`timescale 1ns/1ps
module tb_written_race;
    reg clk = 0, reset = 1;
    reg [8:0] addr0, addr1;
    reg ce0, ce1, we1;
    reg [31:0] d1;
    wire [31:0] q0, q1;
    always #4 clk = ~clk;
    udp_echo_buffer_r_RAM_2P_BRAM_1R1W #(.DataWidth(32), .AddressWidth(9), .AddressRange(512))
    uut (.address0(addr0), .ce0(ce0), .q0(q0),
         .address1(addr1), .ce1(ce1), .we1(we1), .d1(d1), .q1(q1),
         .clk(clk), .reset(reset));
    initial begin
        $display("=== written array 2-cycle read delay test ===");
        reset = 1; #8; reset = 0; ce0 = 0; ce1 = 0; we1 = 0;
        // Write addr=39
        addr1 = 39; d1 = 32'hDEADBEEF; ce1 = 1; we1 = 1; #8;
        ce1 = 0; we1 = 0;
        // Read addr=39 (1 cycle after write)
        addr0 = 39; ce0 = 1; #8;
        $display("T+1: q0=0x%h %s", q0, (q0==0) ? "<<< RETURNS 0 (sel0_sr delay)" : "OK");
        // Read addr=39 (2 cycles after write)
        addr0 = 39; ce0 = 1; #8;
        $display("T+2: q0=0x%h %s", q0, (q0=='hDEADBEEF) ? "OK" : "FAIL");
        // Same-cycle read+write
        addr0 = 39; ce0 = 1; addr1 = 39; ce1 = 1; we1 = 1; d1 = 32'hCAFEBABE; #8;
        $display("T+3: q0=0x%h (same-cycle read+write)", q0);
        // Read addr=39 (2 cycles after second write)
        ce0 = 0; ce1 = 0; we1 = 0; #8;
        addr0 = 39; ce0 = 1; #8;
        $display("T+5: q0=0x%h %s", q0, (q0=='hCAFEBABE) ? "OK" : "FAIL");
        $finish;
    end
endmodule

`timescale 1ns/1ps
module tb_fix_test;
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
        $display("=== FIX test: registered forwarding on conflict ===");
        reset = 1; #8; reset = 0; ce0 = 0; ce1 = 0; we1 = 0; #8;
        
        // Pre-write addr=39 and addr=40
        addr1 = 39; ce1 = 1; we1 = 1; d1 = 32'hAAAAAAAA; #8;
        addr1 = 40; ce1 = 1; we1 = 1; d1 = 32'hBBBBBBBB; #8;
        ce1 = 0; we1 = 0; #8;
        
        // Test: same-cycle read+write addr=39
        $display("Same-cycle write(0xDEADBEEF)+read addr=39:");
        @(negedge clk);
        addr1 = 39; ce1 = 1; we1 = 1; d1 = 32'hDEADBEEF;
        addr0 = 39; ce0 = 1;
        @(negedge clk); // conflict cycle
        $display("  Cycle 0 (conflict): q0=0x%h", q0);
        @(negedge clk); // next cycle - should get forwarded data
        $display("  Cycle 1 (forward): q0=0x%h", q0);
        @(negedge clk); // next cycle - should get normal data
        $display("  Cycle 2 (normal):  q0=0x%h", q0);
        
        ce0 = 0; ce1 = 0; we1 = 0; #8;
        
        // Test: no-conflict read (different addr)
        $display("No-conflict read addr=40:");
        addr0 = 40; ce0 = 1; #8;
        $display("  q0=0x%h (expect 0xBBBBBBBB)", q0);
        
        $finish;
    end
endmodule

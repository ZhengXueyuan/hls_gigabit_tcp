`timescale 1ns/1ps
module tb_written_race3;
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
        $display("=== Simulate 4-segment TCP burst ===");
        reset = 1; #8; reset = 0; ce0 = 0; ce1 = 0; we1 = 0; #8;
        
        // Pre-write addr 39 (simulating segments 1-3)
        addr1 = 39; d1 = 32'h11111111; ce1 = 1; we1 = 1; #8;
        ce1 = 0; we1 = 0; #8; #8;  // 2 cycles later, written[39]=1
        
        // Now simulate segment 4: write AND read addr 39 in same cycle
        $display("Segment 4: same-cycle write+read addr=39 (previously written)");
        @(negedge clk);
        addr1 = 39; d1 = 32'hDEADBEEF; ce1 = 1; we1 = 1;
        addr0 = 39; ce0 = 1;
        @(negedge clk);
        ce1 = 0; we1 = 0; ce0 = 0;
        @(negedge clk);
        $display("  q0=0x%h (expect 0xDEADBEEF)", q0);
        if (q0 == 0) $display("  *** CONFIRMED: written array returns 0 even for pre-written addr! ***");
        
        // Test: what if we write a DIFFERENT addr while reading addr 39?
        $display("Segment 4 variation: write addr=100, read addr=39 same cycle");
        @(negedge clk);
        addr1 = 100; d1 = 32'hCAFEBABE; ce1 = 1; we1 = 1;
        addr0 = 39; ce0 = 1;
        @(negedge clk);
        ce1 = 0; we1 = 0; ce0 = 0;
        @(negedge clk);
        $display("  q0=0x%h (expect 0xDEADBEEF from previous write)", q0);
        
        $finish;
    end
endmodule

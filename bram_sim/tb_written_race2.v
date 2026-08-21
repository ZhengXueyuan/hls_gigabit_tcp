`timescale 1ns/1ps
module tb_written_race2;
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
    
    task write_word;
        input [8:0] a; input [31:0] d;
        begin
            @(negedge clk);
            addr1 = a; d1 = d; ce1 = 1; we1 = 1;
            @(negedge clk);
            ce1 = 0; we1 = 0;
        end
    endtask
    
    task read_word;
        input [8:0] a;
        begin
            @(negedge clk);
            addr0 = a; ce0 = 1;
            @(negedge clk);
            ce0 = 0;
        end
    endtask
    
    initial begin
        $display("=== Precise written array timing test ===");
        reset = 1; #8; reset = 0; ce0 = 0; ce1 = 0; we1 = 0; #8;
        
        // Test 1: write, then read 1 cycle later
        $display("Test 1: Write addr=39, read 1 cycle later");
        write_word(39, 32'hDEADBEEF);
        @(negedge clk);  // 1 cycle gap
        read_word(39);
        @(negedge clk);
        $display("  q0=0x%h (expect 0xDEADBEEF)", q0);
        
        // Test 2: write, read SAME cycle (no gap)
        $display("Test 2: Write addr=40, read SAME cycle addr=40");
        @(negedge clk);
        addr1 = 40; d1 = 32'hCAFEBABE; ce1 = 1; we1 = 1;
        addr0 = 40; ce0 = 1;
        @(negedge clk);
        ce1 = 0; we1 = 0; ce0 = 0;
        @(negedge clk);
        $display("  q0=0x%h (expect 0xCAFEBABE or 0x00000000)", q0);
        
        // Test 3: write, read SAME cycle (different addr)
        $display("Test 3: Write addr=41, read SAME cycle addr=39 (different)");
        write_word(39, 32'h11111111);  // prime addr=39
        @(negedge clk);
        addr1 = 41; d1 = 32'h22222222; ce1 = 1; we1 = 1;
        addr0 = 39; ce0 = 1;
        @(negedge clk);
        ce1 = 0; we1 = 0; ce0 = 0;
        @(negedge clk);
        $display("  q0=0x%h (expect 0x11111111)", q0);
        
        $finish;
    end
endmodule

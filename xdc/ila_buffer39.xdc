#=============================================================================
# ila_buffer39.xdc — ILA to observe BRAM buffer[39] read/write behavior
#=============================================================================
# Purpose: Capture buffer_r_U Port 0 (read) and Port 1 (write) activity
#          when address 39 is accessed. Trigger on address0==39 or address1==39.
#
# Hierarchy: wrapper_1g → u_net (udp_echo) → buffer_r_U (RAM_2P_BRAM_1R1W)
#
# Net names: Vivado preserves hierarchy; the BRAM instance ports are:
#   u_net/buffer_r_U/address0[8:0], /ce0, /q0[31:0]
#   u_net/buffer_r_U/address1[8:0], /ce1, /we1, /d1[31:0], /q1[31:0]
#=============================================================================

# --- ILA Core ---
create_debug_core u_ila_buf39 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_buf39]
set_property ALL_PROBE_SAME_MU_CNT 4 [get_debug_cores u_ila_buf39]
set_property C_ADV_TRIGGER true [get_debug_cores u_ila_buf39]
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_buf39]
set_property C_EN_STRG_QUAL true [get_debug_cores u_ila_buf39]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_buf39]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_buf39]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_buf39]

# --- Clock: gmii_clk (125MHz, same as u_net/ap_clk) ---
set_property port_width 1 [get_debug_ports u_ila_buf39/clk]
connect_debug_port u_ila_buf39/clk [get_nets [list gmii_clk]]

# --- Probe0: address0(9) + address1(9) + ce0(1) + ce1(1) + we1(1) = 21 bits ---
# Trigger-capable: match units on address0 and address1 for trigger on ==39
# Bit order (MSB→LSB): address0[8:0], address1[8:0], ce0, ce1, we1
create_debug_port u_ila_buf39 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_buf39/probe0]
set_property port_width 21 [get_debug_ports u_ila_buf39/probe0]

# Build ordered list of nets for probe0
set probe0_nets [list]
# address0[8:0] — MSB first
for {set i 8} {$i >= 0} {incr i -1} {
    lappend probe0_nets [get_nets [format {u_net/buffer_r_U/address0[%d]} $i]]
}
# address1[8:0] — MSB first
for {set i 8} {$i >= 0} {incr i -1} {
    lappend probe0_nets [get_nets [format {u_net/buffer_r_U/address1[%d]} $i]]
}
# Single-bit control signals
lappend probe0_nets [get_nets {u_net/buffer_r_U/ce0}]
lappend probe0_nets [get_nets {u_net/buffer_r_U/ce1}]
lappend probe0_nets [get_nets {u_net/buffer_r_U/we1}]
connect_debug_port u_ila_buf39/probe0 $probe0_nets

# --- Probe1: q0[31:0] = Port 0 read data (32 bits) ---
create_debug_port u_ila_buf39 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_buf39/probe1]
set_property port_width 32 [get_debug_ports u_ila_buf39/probe1]
set probe1_nets [list]
for {set i 31} {$i >= 0} {incr i -1} {
    lappend probe1_nets [get_nets [format {u_net/buffer_r_U/q0[%d]} $i]]
}
connect_debug_port u_ila_buf39/probe1 $probe1_nets

# --- Probe2: d1[31:0] = Port 1 write data (32 bits) ---
create_debug_port u_ila_buf39 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_buf39/probe2]
set_property port_width 32 [get_debug_ports u_ila_buf39/probe2]
set probe2_nets [list]
for {set i 31} {$i >= 0} {incr i -1} {
    lappend probe2_nets [get_nets [format {u_net/buffer_r_U/d1[%d]} $i]]
}
connect_debug_port u_ila_buf39/probe2 $probe2_nets

# --- Probe3: q1[31:0] = Port 1 read-back data (32 bits) ---
create_debug_port u_ila_buf39 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_buf39/probe3]
set_property port_width 32 [get_debug_ports u_ila_buf39/probe3]
set probe3_nets [list]
for {set i 31} {$i >= 0} {incr i -1} {
    lappend probe3_nets [get_nets [format {u_net/buffer_r_U/q1[%d]} $i]]
}
connect_debug_port u_ila_buf39/probe3 $probe3_nets

# --- dbg_hub clock ---
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets [list gmii_clk]]
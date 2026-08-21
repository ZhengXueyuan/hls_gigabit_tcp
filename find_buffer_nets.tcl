#=============================================================================
# find_buffer_nets.tcl — Discover buffer_r net names in synthesized design
#=============================================================================
# Usage: vivado -mode batch -source find_buffer_nets.tcl
# Run this after synthesis if the ILA nets are not found automatically.
# It opens the synthesized design and prints all buffer_r-related nets.
#=============================================================================

set project_name  udp_dual_phy1g2
set part_name     xc7k325tffg676-2

# Open the existing project
open_project ./vivado_prj/${project_name}.xpr

# Open the synthesized design
if {[catch {open_run synth_1} msg]} {
    puts "ERROR: Cannot open synth_1: $msg"
    puts "Run synthesis first: vivado -mode batch -source run_vivado_phy1g2.tcl"
    exit 1
}

puts "===== Searching for buffer_r nets ====="
puts ""

# Search for all nets containing "buffer_r" in their name
set all_buffer_nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*}]
puts "Total buffer_r nets found: [llength $all_buffer_nets]"

# Categorize by type
puts ""
puts "--- address0 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*address0* && NAME !~ *address1*}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join [lsort -dictionary $nets] "\n"] }

puts ""
puts "--- address1 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*address1*}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join [lsort -dictionary $nets] "\n"] }

puts ""
puts "--- ce0 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*ce0 && NAME !~ *ce1*}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join $nets "\n"] }

puts ""
puts "--- ce1 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*ce1 && NAME !~ *ce0*}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join $nets "\n"] }

puts ""
puts "--- we1 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*we1}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join $nets "\n"] }

puts ""
puts "--- q0 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*q0* && NAME !~ *q1*}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join [lsort -dictionary $nets] "\n"] }

puts ""
puts "--- d1 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*d1*}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join [lsort -dictionary $nets] "\n"] }

puts ""
puts "--- q1 nets ---"
set nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer_r*q1*}]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join [lsort -dictionary $nets] "\n"] }

# Also search for GMII clock
puts ""
puts "--- gmii_clk net ---"
set nets [get_nets -quiet [list gmii_clk]]
puts "Count: [llength $nets]"
if {[llength $nets] > 0} { puts [join $nets "\n"] } else {
    set nets [get_nets -hierarchical -quiet -filter {NAME =~ *gmii_clk*}]
    puts "Hierarchical: [llength $nets]"
    if {[llength $nets] > 0} { puts [join $nets "\n"] }
}

# Also search for any net containing "buffer_r" in the full hierarchical name
puts ""
puts "--- ALL buffer_r nets (full names) ---"
if {[llength $all_buffer_nets] > 0} {
    puts [join [lsort -dictionary $all_buffer_nets] "\n"]
} else {
    puts "NONE FOUND"
    puts ""
    puts "Trying broader search for 'buffer' nets..."
    set all_buffer_nets [get_nets -hierarchical -quiet -filter {NAME =~ *buffer*}]
    puts "Total buffer nets: [llength $all_buffer_nets]"
    if {[llength $all_buffer_nets] > 0 && [llength $all_buffer_nets] < 50} {
        puts [join [lsort -dictionary $all_buffer_nets] "\n"]
    }
}

close_design
puts "===== DONE ====="
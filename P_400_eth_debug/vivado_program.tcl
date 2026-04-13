# vivado_program.tcl - Full programming flow using Vivado + XSCT
# Vivado opens hw_target (clears DAP errors), then XSCT loads ELF
#
# Usage: vivado -mode batch -source vivado_program.tcl

set base_dir [file dirname [file normalize [info script]]]

puts "=== Step 1: Vivado opens HW target ==="
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target [lindex [get_hw_targets] 0]
puts "  Devices: [get_hw_devices]"
puts "  DAP cleared, ARM cores should be visible"

# Get hw_server port (should be 3121)
puts "\n=== Step 2: Launching XSCT to load ELF ==="
set xsct_path "C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"
set xsct_script "$base_dir/program.tcl"

# Run XSCT (it will connect to our hw_server on 3121)
set result [exec $xsct_path $xsct_script 2>@1]
puts $result

puts "\n=== Step 3: Cleanup ==="
close_hw_target
close_hw_manager
puts "Done."

# start_hw.tcl - Open hw_manager and keep hw_server alive
# Run: vivado -mode tcl -source start_hw.tcl
# Then use XSCT in another terminal

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target [lindex [get_hw_targets] 0]
puts "=== HW Target opened ==="
puts "Devices: [get_hw_devices]"
puts "=== hw_server ready on port 3121 ==="
puts "=== Now run XSCT in another terminal ==="

# Keep alive - wait for user to close
after 999999999

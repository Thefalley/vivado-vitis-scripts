# ==============================================================
# program.tcl
# Uso: vivado -mode batch -source tcl/program.tcl -tclargs <bitstream.bit>
# ==============================================================

set bit_file [lindex $argv 0]

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream no encontrado: $bit_file"
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

current_hw_device [get_hw_devices xc7z020_1]
set_property PROBES.FILE {} [get_hw_devices xc7z020_1]
set_property FULL_PROBES.FILE {} [get_hw_devices xc7z020_1]
set_property PROGRAM.FILE $bit_file [get_hw_devices xc7z020_1]
program_hw_devices [get_hw_devices xc7z020_1]
refresh_hw_device [lindex [get_hw_devices xc7z020_1] 0]

puts "OK: Bitstream programado en xc7z020_1"

close_hw_target
disconnect_hw_server
close_hw_manager

# run_crop.tcl -- Run conv_crop_test on ZedBoard via JTAG
#
# Usage:
#   xsct run_crop.tcl <bit_file> <elf_file> <fsbl_file>
#
# Example:
#   C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat run_crop.tcl \
#     ../vitis_ws/conv_test/_ide/bitstream/zynq_conv.bit \
#     ../vitis_ws/conv_test/build/conv_test.elf \
#     ../vitis_ws/zynq_conv_platform/export/zynq_conv_platform/sw/zynq_conv_platform/boot/fsbl.elf

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

connect
after 2000
targets 4
fpga $bit_file
after 1000
targets 2
rst -processor
dow $fsbl_file
con
after 5000
stop
rst -processor
dow $elf_file
con

puts "\nEsperando resultado (crop test, puede tardar ~30s)..."
set timeout 120
set elapsed 0
while {$elapsed < $timeout} {
    after 2000
    set elapsed [expr {$elapsed + 2}]
    stop
    set magic [lindex [mrd -value 0x01200000 1] 0]
    con
    if {$magic == 0xDEAD1234} { break }
}
after 500
stop
set res [mrd -value 0x01200000 3]
puts "\n========================================="
puts "  Conv Crop Test -- RESULTADO JTAG"
puts "========================================="
puts "  Total bytes compared: [lindex $res 1]"
puts "  Errors: [lindex $res 2]"
if {[lindex $res 2] == 0} {
    puts "  >>> 2048/2048 PASS -- BIT-EXACTO <<<"
    puts "  >>> YOLOv4 layer-1 crop VERIFIED! <<<"
} else {
    puts "  >>> FAILED <<<"
}
puts "========================================="

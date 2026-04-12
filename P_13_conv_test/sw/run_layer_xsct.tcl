# run_layer_xsct.tcl -- Run a layer test ELF on ZedBoard via JTAG
#
# Usage:
#   xsct run_layer_xsct.tcl <bit_file> <elf_file> <fsbl_file> [<target_fpga> <target_cpu>]
#
# Default targets: 4 (FPGA) and 2 (CPU) for ZedBoard #1

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]
set tgt_fpga  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 4}]
set tgt_cpu   [expr {[llength $argv] > 4 ? [lindex $argv 4] : 2}]

puts "=== run_layer_xsct.tcl ==="
puts "bit_file  = $bit_file"
puts "elf_file  = $elf_file"
puts "fsbl_file = $fsbl_file"
puts "tgt_fpga  = $tgt_fpga"
puts "tgt_cpu   = $tgt_cpu"

connect
after 2000
targets $tgt_fpga
fpga $bit_file
after 1000
targets $tgt_cpu
rst -processor
dow $fsbl_file
con
after 5000
stop
rst -processor
dow $elf_file
con

puts "\nWaiting for result (layer test)..."
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

# Read result: [magic, layer_idx, total_bytes, errors]
set res [mrd -value 0x01200000 4]
set magic     [lindex $res 0]
set layer_idx [lindex $res 1]
set total     [lindex $res 2]
set errors    [lindex $res 3]

puts "\n========================================="
puts "  Layer $layer_idx -- RESULTADO JTAG"
puts "========================================="
puts "  Magic: [format 0x%08X $magic]"
puts "  Total bytes compared: $total"
puts "  Errors: $errors"

if {$magic != 0xDEAD1234} {
    puts "  >>> TIMEOUT -- no MAGIC received <<<"
    puts "  STATUS: TIMEOUT"
} elseif {$errors == 0} {
    puts "  >>> $total/$total PASS -- BIT-EXACTO <<<"
    puts "  STATUS: PASS"
} else {
    puts "  >>> FAILED ($errors errors) <<<"
    puts "  STATUS: FAIL"
}
puts "========================================="

disconnect

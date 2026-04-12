set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

connect
after 2000
targets 4
fpga $bit_file
after 2000
targets 2
rst -processor
dow $fsbl_file
con
after 5000
stop
rst -processor
dow $elf_file
con
after 5000
stop

puts "\n=== REGISTER READ PROBE ==="
set markers [mrd -value 0x01200000 16]
for {set i 0} {$i < 16} {incr i} {
    set v [lindex $markers $i]
    set prefix [expr {($v >> 24) & 0xFF}]
    if {$prefix == 0xAA} {
        puts [format "  marker\[%2d\] = 0x%08X  <-- HUNG HERE (AA = started read, never completed)" $i $v]
    } elseif {$prefix == 0xBB} {
        puts [format "  marker\[%2d\] = 0x%08X  (read OK, value=0x%04X)" $i $v [expr {$v & 0xFFFF}]]
    } elseif {$v == 0xCAFECAFE} {
        puts [format "  marker\[%2d\] = 0x%08X  ALL READS PASSED!" $i $v]
    } else {
        puts [format "  marker\[%2d\] = 0x%08X" $i $v]
    }
}
puts "==========================="
disconnect

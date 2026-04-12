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

puts "\nEsperando resultado..."
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
puts "  Conv Engine Test (PYNQ-Z2) -- RESULTADO JTAG"
puts "========================================="
puts "  Total: [lindex $res 1] tests"
puts "  Errors: [lindex $res 2]"
if {[lindex $res 2] == 0} { puts "  >>> ALL PASSED -- BIT-EXACTO <<<" } else { puts "  >>> FAILED <<<" }
puts "========================================="

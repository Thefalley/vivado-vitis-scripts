set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]
puts "\n>>> CIERRA Tera Term <<<\n"
connect
after 2000
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
after 1000
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
rst -processor
dow $fsbl_file
con
after 5000
stop
rst -processor
dow $elf_file
con
puts "\nEsperando resultado..."
set timeout 60
set elapsed 0
set magic 0
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
set total  [lindex $res 1]
set errors [lindex $res 2]
puts "\n========================================="
puts "  MAC Array Test — RESULTADO JTAG"
puts "========================================="
puts "  Total: $total canales"
puts "  Errors: $errors"
if {$errors == 0} { puts "  >>> ALL PASSED — BIT-EXACTO <<<" } else { puts "  >>> FAILED <<<" }
puts "========================================="

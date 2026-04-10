# run.tcl -- Programa + ejecuta ea_test via JTAG (lee resultado de DDR)
set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

set RESULT_ADDR 0x01200000
set MAGIC_DONE  0xDEAD1234

puts "\n>>> CIERRA Tera Term si lo tienes abierto <<<\n"
connect
after 2000

puts "Programando bitstream ..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
after 1000

targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
puts "Cargando FSBL ..."
rst -processor
dow $fsbl_file
con
after 5000
stop

puts "Ejecutando ea_test ..."
rst -processor
dow $elf_file
con

# Poll DDR
puts "\nEsperando resultado..."
set timeout 60
set elapsed 0
set magic 0
while {$elapsed < $timeout} {
    after 2000
    set elapsed [expr {$elapsed + 2}]
    stop
    set magic [lindex [mrd -value $RESULT_ADDR 1] 0]
    con
    if {$magic == $MAGIC_DONE} { break }
}
after 500
stop

if {$magic != $MAGIC_DONE} {
    puts "TIMEOUT"
    exit 1
}

set res [mrd -value $RESULT_ADDR 3]
set total  [lindex $res 1]
set errors [lindex $res 2]

puts "\n========================================="
puts "  ElemAdd Layer_017 -- RESULTADO JTAG"
puts "========================================="
puts "  Total tests:  $total"
puts "  Errors:       $errors"
if {$errors == 0} {
    puts "  >>> ALL $total TESTS PASSED -- BIT-EXACTO <<<"
} else {
    puts "  >>> FAILED: $errors errors <<<"
}
puts "========================================="

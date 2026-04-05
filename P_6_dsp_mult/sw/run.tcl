# ==============================================================
# run.tcl - Programa + ejecuta mult_stress via JTAG
# Lee resultado de DDR (sin UART)
# Uso: xsct run.tcl <bitstream.bit> <elf_file> <fsbl.elf>
# ==============================================================

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

# Direccion del resultado en DDR (debe coincidir con mult_stress.c)
set RESULT_ADDR  0x01200000
set MAGIC_DONE   0xDEAD1234

puts "\n>>> CIERRA Tera Term si lo tienes abierto <<<\n"

puts "Conectando a ZedBoard ..."
connect
after 2000
targets

puts "\nProgramando bitstream ..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
after 1000

targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}

puts "Cargando FSBL (inicializando DDR) ..."
rst -processor
dow $fsbl_file
con
after 5000
stop

puts "Cargando y ejecutando stress test ..."
rst -processor
dow $elf_file
con

# ==============================================================
# POLL: esperar hasta que el ARM escriba MAGIC_DONE en DDR
# Timeout: 5 minutos (300 segundos)
# ==============================================================
puts "\nEsperando resultado (polling DDR cada 5s, timeout 300s)..."
set timeout 300
set elapsed 0

while {$elapsed < $timeout} {
    after 5000
    set elapsed [expr {$elapsed + 5}]

    # Leer magic word
    stop
    set magic_raw [mrd -value $RESULT_ADDR 1]
    set magic [lindex $magic_raw 0]
    con

    if {$magic == $MAGIC_DONE} {
        puts "  -> Test completado en ~${elapsed}s"
        break
    }

    # Progress
    if {[expr {$elapsed % 30}] == 0} {
        puts "  ... ${elapsed}s (magic=0x[format %08X $magic], aun ejecutando)"
    }
}

after 1000
stop

if {$magic != $MAGIC_DONE} {
    puts "TIMEOUT: El test no termino en ${timeout}s"
    puts "Magic word = 0x[format %08X $magic]"
    exit 1
}

# ==============================================================
# LEER RESULTADO DE DDR
# ==============================================================
# Estructura (9 words de 32 bits):
#   0x00: magic
#   0x04: total_tests
#   0x08: total_errors
#   0x0C: phase1_errors
#   0x10: phase2_errors
#   0x14: phase3_errors
#   0x18: phase1_count
#   0x1C: phase2_count
#   0x20: phase3_count

set result_data [mrd -value $RESULT_ADDR 9]

set total_tests   [lindex $result_data 1]
set total_errors  [lindex $result_data 2]
set p1_errors     [lindex $result_data 3]
set p2_errors     [lindex $result_data 4]
set p3_errors     [lindex $result_data 5]
set p1_count      [lindex $result_data 6]
set p2_count      [lindex $result_data 7]
set p3_count      [lindex $result_data 8]

puts "\n========================================="
puts "  STRESS TEST RESULTADO (via JTAG)"
puts "========================================="
puts ""
puts "  Fase 1 - Boundary carry:   $p1_count tests, $p1_errors errors"
puts "  Fase 2 - Extremos signed:  $p2_count tests, $p2_errors errors"
puts "  Fase 3 - Random masivo:    $p3_count tests, $p3_errors errors"
puts ""
puts "  ----------------------------------------"
puts "  TOTAL:  $total_tests tests"
puts "  ERRORS: $total_errors"
puts ""

if {$total_errors == 0} {
    puts "  >>>>>>  ALL $total_tests TESTS PASSED  <<<<<<"
} else {
    puts "  >>>>>>  FAILED: $total_errors errors  <<<<<<"
}
puts "========================================="

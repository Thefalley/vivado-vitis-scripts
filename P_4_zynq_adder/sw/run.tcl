# ==============================================================
# run.tcl - Programa + ejecuta + verifica via JTAG (sin UART)
# Uso: xsct run.tcl <bitstream.bit> <elf_file> <fsbl.elf>
# ==============================================================

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

# Test parameters (must match adder_test.c)
set src_addr     0x01000000
set dst_addr     0x01100000
set num_words    64
set adder_base   0x40000000

puts "\n>>> CIERRA Tera Term si lo tienes abierto <<<\n"

# Connect
puts "Conectando a ZedBoard ..."
connect
after 2000
targets

# Program FPGA
puts "\nProgramando bitstream ..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
after 1000

# Select ARM
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}

# FSBL
puts "Cargando FSBL (inicializando DDR) ..."
rst -processor
dow $fsbl_file
con
after 5000
stop

# Load and run app
puts "Cargando y ejecutando app ..."
rst -processor
dow $elf_file
con

# Wait for app to finish all 6 tests
after 8000
stop

# ==============================================================
# VERIFICACION POR JTAG: leer DDR y comprobar
# ==============================================================
puts "\n========================================="
puts "  VERIFICACION POR JTAG"
puts "========================================="

# Test: source = 0,1,2,3... add_value = 5, dest should be 5,6,7,8...

# Read source and dest buffers from DDR (accessible via JTAG)
puts "  Leyendo DDR ..."
set src_data [mrd -value $src_addr $num_words]
set dst_data [mrd -value $dst_addr $num_words]

set add_val_int 5

# Show first 8 words
puts "\n  Word | Source     | Dest       | Expected   | OK?"
puts "  -----|------------|------------|------------|----"

set errors 0

for {set i 0} {$i < $num_words} {incr i} {
    set s_int [lindex $src_data $i]
    set d_int [lindex $dst_data $i]
    set expected [expr {($s_int + $add_val_int) & 0xFFFFFFFF}]

    if {$d_int != $expected} {
        incr errors
    }

    if {$i < 8} {
        if {$d_int == $expected} {
            set ok "OK"
        } else {
            set ok "FAIL"
        }
        puts [format "  %4d | 0x%08X | 0x%08X | 0x%08X | %s" $i $s_int $d_int $expected $ok]
    }
}

puts "\n========================================="
if {$errors == 0} {
    puts "  RESULTADO: PASS ($num_words/$num_words words OK)"
    puts "  stream_adder + DMA FUNCIONA"
} else {
    puts "  RESULTADO: FAIL ($errors/$num_words errores)"
}
puts "========================================="

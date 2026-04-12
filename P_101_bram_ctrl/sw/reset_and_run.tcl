# reset_and_run.tcl — handles DAP errors by doing system reset first

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

set src_addr     0x01000000
set dst_addr     0x01100000
set num_words    260
set pattern_base 0xCAFE0000

puts "Conectando..."
connect
after 2000

puts "Targets iniciales:"
targets

# Try to do a system reset via DAP to clear error state
puts "\nIntentando system reset via DAP..."
catch {
    targets -set -nocase -filter {name =~ "*DAP*"}
    rst -system
}
after 3000

puts "\nTargets despues de system reset:"
targets

# Program FPGA
puts "\nProgramando bitstream..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*xc7z*"}
fpga $bit_file
after 3000

puts "\nTargets despues de FPGA programming:"
targets

# Select ARM core
puts "\nSeleccionando ARM A9..."
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}

# FSBL
puts "Cargando FSBL..."
rst -processor
dow $fsbl_file
con
after 5000
stop

# App
puts "Cargando y ejecutando app..."
rst -processor
dow $elf_file
con
after 15000
stop

# Verify via JTAG
puts "\n========================================="
puts "  VERIFICACION POR JTAG (incremental test)"
puts "========================================="

set src_data [mrd -value $src_addr $num_words]
set dst_data [mrd -value $dst_addr $num_words]

puts "\n  Word | Source     | Dest       | OK?"
puts "  -----|------------|------------|----"

set errors 0
for {set i 0} {$i < $num_words} {incr i} {
    set s [lindex $src_data $i]
    set d [lindex $dst_data $i]
    set expected [expr {($pattern_base + $i) & 0xFFFFFFFF}]

    if {$d != $expected} { incr errors }

    if {$i < 4 || $i >= ($num_words - 4) || $d != $expected} {
        set ok [expr {$d == $expected ? "OK" : "FAIL"}]
        puts [format "  %4d | 0x%08X | 0x%08X | %s" $i $s $d $ok]
    }
}

puts "\n========================================="
if {$errors == 0} {
    puts "  RESULTADO: PASS ($num_words/$num_words words OK)"
    puts "  Incremental flow control VERIFICADO"
} else {
    puts "  RESULTADO: FAIL ($errors/$num_words errores)"
}
puts "========================================="
disconnect

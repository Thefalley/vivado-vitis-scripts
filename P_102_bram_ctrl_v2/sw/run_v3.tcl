# ==============================================================
# run_v3.tcl - Programa + ejecuta + verifica via JTAG
# P_102 bram_ctrl_v2: counter test
# Uso: xsct run_v3.tcl <bitstream.bit> <elf_file> <fsbl.elf>
# ==============================================================

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

set src_addr      0x01000000
set dst_addr      0x01100000
set marker_addr   0x01200000
set num_words     100
set pattern_base  0xBEEF0000

puts "\n>>> CIERRA Tera Term si lo tienes abierto <<<\n"

# Connect
puts "Conectando a ZedBoard ..."
connect
after 3000

puts "\nTargets:"
targets
after 1000

# Program FPGA (target PL/xc7z020)
puts "\nProgramando bitstream ..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
puts "  Bitstream programado"
after 5000

# After FPGA programming, ARM cores should appear
puts "\nTargets despues de FPGA:"
targets
after 2000

# Select ARM core
puts "\nSeleccionando ARM core ..."
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}

# FSBL for DDR init
puts "Cargando FSBL (inicializando DDR) ..."
rst -processor
after 1000
dow $fsbl_file
con
after 6000
stop
after 1000

# Load and run counter test app
puts "\nCargando y ejecutando counter_test ..."
rst -processor
after 1000
dow $elf_file
con

# Wait for test to complete (load 100 + drain 40+60 = ~200 words)
after 25000
stop
after 1000

# ==============================================================
# VERIFICACION POR JTAG
# ==============================================================
puts "\n========================================="
puts "  VERIFICACION POR JTAG - P_102 bram_ctrl_v2"
puts "========================================="

# Read markers
puts "\n  --- JTAG Markers ---"
set markers [mrd -value $marker_addr 8]
set result      [lindex $markers 0]
set data_err    [lindex $markers 1]
set counter_err [lindex $markers 2]
set last_phase  [lindex $markers 3]

puts [format "  Result:       0x%08X" $result]
puts [format "  Data errors:  %d" $data_err]
puts [format "  Counter errs: %d" $counter_err]
puts [format "  Last phase:   0x%02X" $last_phase]

# Read data
puts "\n  --- Data Verification ---"
set src_data [mrd -value $src_addr $num_words]
set dst_data [mrd -value $dst_addr $num_words]

puts "\n  Word | Source     | Dest       | Expected   | OK?"
puts "  -----|------------|------------|------------|----"

set jtag_data_errors 0

for {set i 0} {$i < $num_words} {incr i} {
    set s_int [lindex $src_data $i]
    set d_int [lindex $dst_data $i]
    set expected [expr {($pattern_base + $i) & 0xFFFFFFFF}]

    if {$d_int != $expected} {
        incr jtag_data_errors
    }

    if {$i < 4 || $i >= $num_words - 4 || $d_int != $expected} {
        if {$d_int == $expected} {
            set ok "OK"
        } else {
            set ok "FAIL"
        }
        puts [format "  %4d | 0x%08X | 0x%08X | 0x%08X | %s" $i $s_int $d_int $expected $ok]
    }
}

# AXI-Lite counter readback
puts "\n  --- AXI-Lite Counter Readback (JTAG) ---"
set ctrl_base 0x40000000

if {[catch {
    set ctrl_state [mrd -value [expr {$ctrl_base + 0x0C}] 1]
    set occupancy  [mrd -value [expr {$ctrl_base + 0x10}] 1]
    set in_lo      [mrd -value [expr {$ctrl_base + 0x14}] 1]
    set in_hi      [mrd -value [expr {$ctrl_base + 0x18}] 1]
    set out_lo     [mrd -value [expr {$ctrl_base + 0x24}] 1]
    set out_hi     [mrd -value [expr {$ctrl_base + 0x28}] 1]

    puts [format "  ctrl_state:  %d" [lindex $ctrl_state 0]]
    puts [format "  occupancy:   %d" [lindex $occupancy 0]]
    puts [format "  total_in:    0x%08X_%08X" [lindex $in_hi 0] [lindex $in_lo 0]]
    puts [format "  total_out:   0x%08X_%08X" [lindex $out_hi 0] [lindex $out_lo 0]]
    puts "  (Counters should be 0 after final reset in C app)"
} err]} {
    puts "  WARN: Could not read AXI-Lite registers"
    puts "        ($err)"
}

# Final verdict
puts "\n========================================="
if {$result == 0xCAFE0000 && $jtag_data_errors == 0} {
    puts "  RESULTADO: PASS"
    puts "  Data:     $num_words/$num_words words OK"
    puts "  Counters: $counter_err errors (from C app)"
    puts "  bram_ctrl_top v2 COUNTERS + FIFO + READBACK OK"
} else {
    puts "  RESULTADO: FAIL"
    puts [format "  C app result: 0x%08X" $result]
    puts "  JTAG data errors: $jtag_data_errors"
    puts "  C app data errors: $data_err"
    puts "  C app counter errors: $counter_err"
}
puts "========================================="

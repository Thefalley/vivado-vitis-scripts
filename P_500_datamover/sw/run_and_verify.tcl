# run_and_verify.tcl - Programa, ejecuta y verifica via JTAG
# Usa ps7_init.tcl para inicializar PS directamente (sin FSBL)
#
# Uso: xsct run_and_verify.tcl <bit> <elf> <ps7_init_tcl>

set bit_file    [lindex $argv 0]
set elf_file    [lindex $argv 1]
set ps7_init    [lindex $argv 2]

# Addresses
set GPIO_CTRL_CH2  0x41210008
set SRC_ADDR       0x01000000
set DST_ADDR       0x02000000
set N_WORDS        64

puts ""
puts "========================================"
puts "P_500 DataMover - Run & Verify"
puts "========================================"

# Connect
connect
after 2000
targets

# Program FPGA - ZedBoard PL is target index 4 (JTAG device 3)
# (PYNQ-Z2 PL is index 8, skip that)
puts "\n\[1\] Programando bitstream (ZedBoard, target 4) ..."
targets -set -filter {target_id == 4}
fpga $bit_file
after 1000

# Select ZedBoard ARM Cortex-A9 #0 (target 2)
targets -set -filter {target_id == 2}

# Initialize PS using ps7_init (DDR, clocks, MIO, level shifters)
puts "\[2\] Inicializando PS (ps7_init) ..."
source $ps7_init
ps7_init
after 500
ps7_post_config
after 500

# Download and run app
puts "\[3\] Cargando dm_test.elf ..."
dow $elf_file
after 500

puts "\[4\] Ejecutando app ..."
con
after 3000
stop

# Verify via JTAG memory reads
puts "\n\[5\] Verificando via JTAG ..."

# Read status register
puts "\n--- Status GPIO (dm_s2mm_ctrl) ---"
if {[catch {
    set status [mrd -value $GPIO_CTRL_CH2 1]
    set status_val [lindex $status 0]
    puts "  Raw: 0x[format %08X $status_val]"
    puts "  Busy:  [expr {$status_val & 1}]"
    puts "  Done:  [expr {($status_val >> 1) & 1}]"
    puts "  Error: [expr {($status_val >> 2) & 1}]"
    set dm_sts [expr {($status_val >> 4) & 0xFF}]
    puts "  DM STS: 0x[format %02X $dm_sts] (OK=[expr {($dm_sts >> 4) & 1}] DECERR=[expr {($dm_sts >> 7) & 1}] SLVERR=[expr {($dm_sts >> 6) & 1}] INTERR=[expr {($dm_sts >> 5) & 1}])"
} err]} {
    puts "  ERROR reading status: $err"
}

# Read source data
puts "\n--- Source DDR (0x01000000) first 8 words ---"
if {[catch {
    set src_data [mrd -value $SRC_ADDR 8]
    for {set i 0} {$i < 8} {incr i} {
        puts "  SRC\[$i\] = 0x[format %08X [lindex $src_data $i]]"
    }
} err]} {
    puts "  ERROR reading source: $err"
}

# Read destination data
puts "\n--- Destination DDR (0x02000000) first 8 words ---"
if {[catch {
    set dst_data [mrd -value $DST_ADDR 8]
    for {set i 0} {$i < 8} {incr i} {
        puts "  DST\[$i\] = 0x[format %08X [lindex $dst_data $i]]"
    }
} err]} {
    puts "  ERROR reading destination: $err"
}

# Full comparison
puts "\n--- Full Verify ($N_WORDS words) ---"
if {[catch {
    set src_all [mrd -value $SRC_ADDR $N_WORDS]
    set dst_all [mrd -value $DST_ADDR $N_WORDS]
    set errors 0
    for {set i 0} {$i < $N_WORDS} {incr i} {
        set sv [lindex $src_all $i]
        set dv [lindex $dst_all $i]
        if {$sv != $dv} {
            if {$errors < 8} {
                puts "  MISMATCH \[$i\]: src=0x[format %08X $sv] dst=0x[format %08X $dv]"
            }
            incr errors
        }
    }
    puts ""
    if {$errors == 0} {
        puts "RESULT: PASS - $N_WORDS words match"
    } else {
        puts "RESULT: FAIL - $errors / $N_WORDS mismatched"
    }
} err]} {
    puts "  ERROR during verify: $err"
}

puts "========================================"

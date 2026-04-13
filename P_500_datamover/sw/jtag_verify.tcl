# jtag_verify.tcl - Verifica resultado del DataMover via JTAG
# Lee status GPIO + memoria src/dst y compara
#
# Uso: xsct jtag_verify.tcl

# Addresses (from Vivado address editor)
set GPIO_CTRL_BASE 0x41210000
set GPIO_CTRL_CH2  [expr {$GPIO_CTRL_BASE + 0x08}]
set SRC_ADDR       0x01000000
set DST_ADDR       0x02000000
set N_WORDS        64

puts ""
puts "========================================"
puts "P_500 DataMover - JTAG Verification"
puts "========================================"

# Connect
connect
after 1000
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
stop

# Read status register
puts "\n--- Status GPIO (0x41210008) ---"
set status [mrd -value $GPIO_CTRL_CH2 1]
set status_val [lindex $status 0]
puts "  Raw status: 0x[format %08X $status_val]"
puts "  Busy:  [expr {$status_val & 1}]"
puts "  Done:  [expr {($status_val >> 1) & 1}]"
puts "  Error: [expr {($status_val >> 2) & 1}]"
puts "  DM STS byte: 0x[format %02X [expr {($status_val >> 4) & 0xFF}]]"

# Read source data (first 8 words)
puts "\n--- Source DDR (0x01000000) ---"
set src_data [mrd -value $SRC_ADDR 8]
for {set i 0} {$i < 8} {incr i} {
    set v [lindex $src_data $i]
    puts "  SRC\[$i\] = 0x[format %08X $v]"
}

# Read destination data (first 8 words)
puts "\n--- Destination DDR (0x02000000) ---"
set dst_data [mrd -value $DST_ADDR 8]
for {set i 0} {$i < 8} {incr i} {
    set v [lindex $dst_data $i]
    puts "  DST\[$i\] = 0x[format %08X $v]"
}

# Full comparison
puts "\n--- Full Verify ($N_WORDS words) ---"
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
    puts "RESULT: PASS - $N_WORDS words match OK"
} else {
    puts "RESULT: FAIL - $errors / $N_WORDS words mismatched"
}
puts "========================================"

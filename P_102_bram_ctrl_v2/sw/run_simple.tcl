# run_simple.tcl — Simplified programming + JTAG verify
# No rst -system (can destabilize), just connect + program + load + run

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

set src_addr     0x01000000
set dst_addr     0x01100000
set marker_addr  0x01200000
set num_words    100

connect
after 2000

# Program FPGA
puts "\nProgramando bitstream..."
targets 4
fpga $bit_file
after 2000

# Select ARM
targets 2

# FSBL
puts "Cargando FSBL..."
rst -processor
dow $fsbl_file
con
after 5000
stop

# App
puts "Cargando counter_test..."
rst -processor
dow $elf_file
con
after 30000
stop

# Read markers
puts "\n========================================="
puts "  JTAG Verification"
puts "========================================="

set marker [mrd -value $marker_addr 4]
set result [lindex $marker 0]
set data_err [lindex $marker 1]
set cnt_err [lindex $marker 2]
set phase [lindex $marker 3]

puts "  Result marker: [format 0x%08X $result]"
puts "  Data errors: $data_err"
puts "  Counter errors: $cnt_err"
puts "  Last phase: $phase"

# Read first 4 + last 4 of dst
set dst_head [mrd -value $dst_addr 4]
set dst_tail [mrd -value [expr {$dst_addr + ($num_words - 4) * 4}] 4]

puts "\n  dst[0..3]: [format {0x%08X 0x%08X 0x%08X 0x%08X} [lindex $dst_head 0] [lindex $dst_head 1] [lindex $dst_head 2] [lindex $dst_head 3]]"
puts "  dst[96..99]: [format {0x%08X 0x%08X 0x%08X 0x%08X} [lindex $dst_tail 0] [lindex $dst_tail 1] [lindex $dst_tail 2] [lindex $dst_tail 3]]"

if {$result == 0xCAFE0000} {
    puts "\n  RESULTADO: PASS"
} else {
    puts "\n  RESULTADO: FAIL (o app no termino)"
}
puts "========================================="
disconnect

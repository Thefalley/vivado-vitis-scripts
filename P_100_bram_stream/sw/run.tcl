# ==============================================================
# run.tcl - Program + run + JTAG-verify for P_100 bram_stream
# Usage: xsct run.tcl <bitstream.bit> <elf_file> <fsbl.elf>
#
# Reads SRC and DST buffers from DDR via JTAG (without relying on UART)
# and checks that DST is an identity copy of SRC (pass-through through
# BRAM). PASS iff every word matches.
# ==============================================================

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

# Test parameters (must match bram_stream_test.c)
set src_addr   0x01000000
set dst_addr   0x01100000
set num_words  256

puts ">>> Connecting to hw_server ..."
connect
after 2000
targets

puts "\n>>> Programming bitstream ..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
after 1000

targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}

puts "\n>>> Loading FSBL (DDR init) ..."
rst -processor
dow $fsbl_file
con
after 5000
stop

puts "\n>>> Loading and running app ..."
rst -processor
dow $elf_file
con
after 8000
stop

# ==============================================================
# JTAG verification: read DDR buffers, compare identity
# ==============================================================
puts "\n========================================="
puts "  JTAG verification"
puts "========================================="

puts "  Reading DDR ..."
set src_data [mrd -value $src_addr $num_words]
set dst_data [mrd -value $dst_addr $num_words]

puts "\n  Word | Source     | Dest       | OK?"
puts "  -----|------------|------------|----"

set errors 0
for {set i 0} {$i < $num_words} {incr i} {
    set s [lindex $src_data $i]
    set d [lindex $dst_data $i]
    set expected $s

    if {$d != $expected} {
        incr errors
    }

    if {$i < 8 || $i >= ($num_words - 4)} {
        if {$d == $expected} {
            set ok "OK"
        } else {
            set ok "FAIL"
        }
        puts [format "  %4d | 0x%08X | 0x%08X | %s" $i $s $d $ok]
    }
}

puts "\n========================================="
if {$errors == 0} {
    puts "  RESULT: PASS ($num_words/$num_words words OK)"
    puts "  bram_stream + BRAM + DMA works on real HW"
} else {
    puts "  RESULT: FAIL ($errors/$num_words errors)"
}
puts "========================================="
disconnect

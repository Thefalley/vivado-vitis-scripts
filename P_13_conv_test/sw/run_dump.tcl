set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

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
set timeout 120
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
puts "\n========================================="
puts "  Conv Engine Test -- DUMP"
puts "========================================="
puts "  Status: [format 0x%08X [lindex $res 0]]"
puts "  Total:  [lindex $res 1]"
puts "  Errors: [lindex $res 2]"
puts ""

# Dump BRAM output region via AXI-Lite
# WRAPPER_BASE = 0x43C00000, BRAM_OUTPUT_ADDR = 0xC00
# Output: 32 OCs * 9 pixels = 288 bytes = 72 words
set base 0x43C01C00
puts "BRAM output region (0x43C01C00, 288 bytes):"
for {set oc 0} {$oc < 32} {incr oc} {
    set addr [expr {$base + $oc * 9}]
    # Read enough words to cover 9 bytes (need 3 words = 12 bytes, take 9)
    set w1 [mrd -value [expr {$addr & ~3}]]
    set w2 [mrd -value [expr {($addr & ~3) + 4}]]
    set w3 [mrd -value [expr {($addr & ~3) + 8}]]
    puts [format "  oc=%2d addr=0x%08x  w=%08x %08x %08x" $oc $addr $w1 $w2 $w3]
}

puts "========================================="

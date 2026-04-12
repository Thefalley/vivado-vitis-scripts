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
puts "  Conv Engine Test -- DUMP DDR"
puts "========================================="
puts "  Status: [format 0x%08X [lindex $res 0]]"
puts "  Total:  [lindex $res 1]"
puts "  Errors: [lindex $res 2]"
puts ""

# Dump output region (288 bytes = 72 words @ 0x01200100)
puts "=== OUTPUT (288 bytes, 32 OCs x 9 pixels):"
set data [mrd -value 0x01200100 72]
for {set oc 0} {$oc < 32} {incr oc} {
    set base [expr {$oc * 9}]
    set b0w [expr {$base / 4}]
    set b0o [expr {$base % 4}]
    set bytes {}
    for {set p 0} {$p < 9} {incr p} {
        set abs [expr {$base + $p}]
        set wi [expr {$abs / 4}]
        set bi [expr {$abs % 4}]
        set w [lindex $data $wi]
        set b [expr {($w >> ($bi * 8)) & 0xff}]
        if {$b >= 128} { set b [expr {$b - 256}] }
        lappend bytes [format %4d $b]
    }
    puts "  oc=[format %2d $oc]: [join $bytes { }]"
}

puts ""
puts "=== BIAS readback (32 x int32 @ 0x01200300):"
set bdata [mrd -value 0x01200300 32]
for {set i 0} {$i < 32} {incr i} {
    puts [format "  bias\[%2d\] = %d (0x%08x)" $i [expr {[lindex $bdata $i] - (([lindex $bdata $i] >> 31) << 32)}] [lindex $bdata $i]]
}

puts ""
puts "=== INPUT readback (first 32 bytes @ 0x01200400):"
set idata [mrd -value 0x01200400 8]
for {set w 0} {$w < 8} {incr w} {
    set word [lindex $idata $w]
    set b0 [expr {$word & 0xff}]
    set b1 [expr {($word >> 8) & 0xff}]
    set b2 [expr {($word >> 16) & 0xff}]
    set b3 [expr {($word >> 24) & 0xff}]
    foreach v {b0 b1 b2 b3} {
        set val [set $v]
        if {$val >= 128} { set $v [expr {$val - 256}] }
    }
    puts [format "  word %d: %4d %4d %4d %4d" $w $b0 $b1 $b2 $b3]
}
puts ""
puts "=== WEIGHTS readback (first 32 bytes @ 0x01200500):"
set wdata [mrd -value 0x01200500 8]
for {set w 0} {$w < 8} {incr w} {
    set word [lindex $wdata $w]
    set b0 [expr {$word & 0xff}]
    set b1 [expr {($word >> 8) & 0xff}]
    set b2 [expr {($word >> 16) & 0xff}]
    set b3 [expr {($word >> 24) & 0xff}]
    if {$b0 >= 128} { set b0 [expr {$b0 - 256}] }
    if {$b1 >= 128} { set b1 [expr {$b1 - 256}] }
    if {$b2 >= 128} { set b2 [expr {$b2 - 256}] }
    if {$b3 >= 128} { set b3 [expr {$b3 - 256}] }
    puts [format "  word %d: %4d %4d %4d %4d" $w $b0 $b1 $b2 $b3]
}
puts "========================================="

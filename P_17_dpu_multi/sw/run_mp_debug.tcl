set bit_file  [lindex $argv 0]
set fsbl_file [lindex $argv 1]
set elf_file  [lindex $argv 2]

set RESULT_ADDR 0x10200000
set MAGIC 0xDEAD1234

connect
after 1000

set fpga_id ""
foreach t [targets -filter {name =~ "xc7z020*"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> fpga_id
    break
}
set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id
    break
}

targets $fpga_id
fpga $bit_file
after 1000

targets $arm_id
rst -processor
after 500
dow $fsbl_file
con
after 3000
stop
mwr $RESULT_ADDR 0
rst -processor
after 500
dow $elf_file
con

set elapsed 0
while {$elapsed < 60} {
    after 1000
    incr elapsed 1
    stop
    set magic [lindex [mrd -value $RESULT_ADDR 1] 0]
    con
    if {$magic == $MAGIC} { break }
}
after 500
stop

set res [mrd -value $RESULT_ADDR 8]
puts ""
puts "== maxpool_test output =="
puts "magic  : 0x[format %08x [lindex $res 0]]"
puts "total  : [lindex $res 1]"
puts "errors : [lindex $res 2]"
puts "out[0-3]  (word): 0x[format %08x [lindex $res 3]]"
puts "out[4-7]  (word): 0x[format %08x [lindex $res 4]]"
puts "out[8-11] (word): 0x[format %08x [lindex $res 5]]"
puts "out[12-15](word): 0x[format %08x [lindex $res 6]]"

# Decodificar byte a byte
set bytes [list]
for {set w 3} {$w < 7} {incr w} {
    set v [lindex $res $w]
    for {set b 0} {$b < 4} {incr b} {
        set byte [expr {($v >> ($b * 8)) & 0xFF}]
        lappend bytes $byte
    }
}

set expected {0x03 0xFF 0x7F 0x80 0x64 0x28 0xFF 0x05 0x66 0x0F 0x7F 0x7F 0x01 0x42 0x08 0x00}
puts ""
puts [format "  %-4s %-8s %-8s %s" "idx" "got" "exp" "ok"]
for {set i 0} {$i < 16} {incr i} {
    set g [lindex $bytes $i]
    set e [lindex $expected $i]
    set ok "OK"
    if {$g != $e} { set ok "FAIL" }
    puts [format "  %-4d 0x%02X     0x%02X     %s" $i $g $e $ok]
}

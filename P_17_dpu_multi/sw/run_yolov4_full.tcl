set bit_file       [lindex $argv 0]
set fsbl_file      [lindex $argv 1]
set elf_file       [lindex $argv 2]
set weights_bin    [lindex $argv 3]
set input_bin      [lindex $argv 4]
set heads_out_dir  [lindex $argv 5]

set ADDR_INPUT    0x10000000
set ADDR_WEIGHTS  0x12000000
set ADDR_HEAD_52  0x18000000
set ADDR_HEAD_26  0x18200000
set ADDR_HEAD_13  0x18400000
set RESULT_ADDR   0x10200000
set MAGIC         0xDEAD1234

set HEAD_52_BYTES [expr 52*52*255]
set HEAD_26_BYTES [expr 26*26*255]
set HEAD_13_BYTES [expr 13*13*255]

set TIMEOUT_SEC 7200

connect
after 2000

set fpga_id ""
foreach t [targets -filter {name =~ "xc7z020*"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> fpga_id; break
}
set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id; break
}
puts "fpga_id=$fpga_id arm_id=$arm_id"

targets $fpga_id
fpga $bit_file
after 2000

targets $arm_id
rst -processor
after 500
dow $fsbl_file
con
after 3000
stop

puts ">>> Loading weights blob..."
set t0 [clock seconds]
dow -data $weights_bin $ADDR_WEIGHTS
set t1 [clock seconds]
puts ">>> weights loaded in [expr $t1 - $t0] seconds"

puts ">>> Loading input..."
set t0 [clock seconds]
dow -data $input_bin $ADDR_INPUT
set t1 [clock seconds]
puts ">>> input loaded in [expr $t1 - $t0] seconds"

rst -processor
after 500
dow $elf_file
con
puts ">>> ELF running, polling..."

set elapsed 0
while {$elapsed < $TIMEOUT_SEC} {
    after 5000
    incr elapsed 5
    stop
    set magic [lindex [mrd -value $RESULT_ADDR 1] 0]
    con
    if {$magic == $MAGIC} { break }
    if {$elapsed % 60 == 0} {
        puts "    $elapsed s (magic=0x[format %08x $magic])"
    }
}

after 500
stop
set res [mrd -value $RESULT_ADDR 8]
puts "magic=0x[format %08x [lindex $res 0]] ok=[lindex $res 1] fail=[lindex $res 2]"

file mkdir $heads_out_dir
mrd -bin -file [file join $heads_out_dir head_52.bin] $ADDR_HEAD_52 [expr $HEAD_52_BYTES/4]
mrd -bin -file [file join $heads_out_dir head_26.bin] $ADDR_HEAD_26 [expr $HEAD_26_BYTES/4]
mrd -bin -file [file join $heads_out_dir head_13.bin] $ADDR_HEAD_13 [expr $HEAD_13_BYTES/4]

# Dump status table (255 uint32) - bits[31:16]=op_type, bits[15:0]=err code
set ADDR_STATUS 0x10210000
mrd -bin -file [file join $heads_out_dir status_table.bin] $ADDR_STATUS 255
puts "heads + status dumped to $heads_out_dir"

# Print per-layer status summary
puts ""
puts "=== Per-layer status (first 30 + last 10) ==="
set status_data [mrd -value $ADDR_STATUS 255]
for {set i 0} {$i < 30} {incr i} {
    set v [lindex $status_data $i]
    set op [expr {($v >> 16) & 0xFFFF}]
    set st [expr {$v & 0xFFFF}]
    set tag [expr {$st == 0 ? "OK" : "FAIL($st)"}]
    puts [format "  [%3d] op=%d %s" $i $op $tag]
}
puts "..."
for {set i 245} {$i < 255} {incr i} {
    set v [lindex $status_data $i]
    set op [expr {($v >> 16) & 0xFFFF}]
    set st [expr {$v & 0xFFFF}]
    set tag [expr {$st == 0 ? "OK" : "FAIL($st)"}]
    puts [format "  [%3d] op=%d %s" $i $op $tag]
}

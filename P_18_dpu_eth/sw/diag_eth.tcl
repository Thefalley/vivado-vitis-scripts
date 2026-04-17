connect
after 1000

set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id; break
}
puts "arm_id=$arm_id"
targets $arm_id

stop
after 200

puts "=== ARM registers ==="
rrd pc
rrd lr
rrd cpsr
rrd sp

puts ""
puts "=== XEMACPS_0 registers (base 0xE000B000) ==="
puts "NW_CTRL       [format %08x [lindex [mrd -value 0xE000B000 1] 0]]"
puts "NW_CFG        [format %08x [lindex [mrd -value 0xE000B004 1] 0]]"
puts "NW_STATUS     [format %08x [lindex [mrd -value 0xE000B008 1] 0]]"
puts "DMA_CFG       [format %08x [lindex [mrd -value 0xE000B010 1] 0]]"
puts "TX_STATUS     [format %08x [lindex [mrd -value 0xE000B014 1] 0]]"
puts "RX_STATUS     [format %08x [lindex [mrd -value 0xE000B020 1] 0]]"
puts "INT_STATUS    [format %08x [lindex [mrd -value 0xE000B024 1] 0]]"
puts "PHY_MAINT     [format %08x [lindex [mrd -value 0xE000B034 1] 0]]"
puts "RX_PAUSE      [format %08x [lindex [mrd -value 0xE000B038 1] 0]]"
puts "OCT_RX_LO     [format %08x [lindex [mrd -value 0xE000B100 1] 0]]"
puts "FRAMES_RX     [format %08x [lindex [mrd -value 0xE000B158 1] 0]]"
puts "FRAMES_TX     [format %08x [lindex [mrd -value 0xE000B108 1] 0]]"

con
disconnect

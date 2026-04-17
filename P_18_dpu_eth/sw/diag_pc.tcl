connect
after 1000

set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id; break
}
targets $arm_id

# Sample PC 5 times to see if ARM is running (PC changes) or halted
for {set i 0} {$i < 5} {incr i} {
    stop
    set pc_val  [lindex [rrd pc] 1]
    set lr_val  [lindex [rrd lr] 1]
    set sp_val  [lindex [rrd sp] 1]
    set cpsr    [lindex [rrd cpsr] 1]
    puts "[$i] PC=$pc_val LR=$lr_val SP=$sp_val CPSR=$cpsr"
    con
    after 200
}

stop
puts ""
puts "=== Final PC context (try disassemble) ==="
set pc_val [lindex [rrd pc] 1]
puts "pc=$pc_val"
disassemble $pc_val 8

con
disconnect

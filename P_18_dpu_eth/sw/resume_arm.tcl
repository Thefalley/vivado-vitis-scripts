connect
after 500
set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id; break
}
targets $arm_id
con
puts "ARM resumed"
disconnect

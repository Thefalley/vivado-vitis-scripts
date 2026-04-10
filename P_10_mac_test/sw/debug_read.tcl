connect
after 2000
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
set dst [mrd -value 0x01100000 32]
puts "\n  ch | got"
puts "  ---+------------"
for {set i 0} {$i < 32} {incr i} {
    set v [lindex $dst $i]
    if {$v > 2147483647} { set v [expr {$v - 4294967296}] }
    puts [format "  %2d | %10d" $i $v]
}

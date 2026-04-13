# Debug JTAG targets
connect
after 5000

puts "\n=== TARGETS ==="
targets

puts "\n=== JTAG TARGETS ==="
jtag targets

puts "\n=== TARGET PROPERTIES ==="
catch {
    foreach t [targets -target-properties] {
        puts "  ID=[dict get $t target_id] NAME=[dict get $t name]"
    }
} err
if {$err ne ""} { puts "  Error: $err" }

puts "\n=== TRYING sequential targets ==="
for {set i 1} {$i <= 5} {incr i} {
    catch {
        targets $i
        puts "  Target $i: OK"
    } err
    if {[string match "*no targets*" $err] || [string match "*invalid*" $err]} {
        puts "  Target $i: $err"
    }
}

disconnect

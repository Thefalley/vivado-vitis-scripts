connect
after 5000
puts "=== TARGETS ==="
foreach t [targets -target-properties] {
    puts "  ID=[dict get $t target_id] NAME=[dict get $t name]"
}
puts "=== RST -SRST ==="
catch {targets 1; rst -srst; after 5000} err
puts "  Result: $err"
puts "=== AFTER RESET ==="
foreach t [targets -target-properties] {
    puts "  ID=[dict get $t target_id] NAME=[dict get $t name]"
}
disconnect

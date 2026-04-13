connect
after 10000
puts "=== All targets ==="
puts [targets]
puts "=== Target details ==="
foreach t [targets -target-properties] {
    puts $t
}

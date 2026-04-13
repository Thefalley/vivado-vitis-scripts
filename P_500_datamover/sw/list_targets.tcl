connect
after 2000
set tgt_list [targets -target-properties]
puts "=== TARGETS ==="
foreach tgt $tgt_list {
    dict with tgt {
        puts "  Index: $target_id  Name: $name  JTAG: [expr {[dict exists $tgt jtag_device_id] ? [dict get $tgt jtag_device_id] : {N/A}}]"
    }
}
puts "=== END ==="

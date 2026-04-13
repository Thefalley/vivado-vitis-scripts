# vivado_full.tcl - Full programming via Vivado + embedded XSCT
# Opens hw_target (fixes DAP), then immediately runs XSCT in same process

open_hw_manager
connect_hw_server -allow_non_jtag

set tgts [get_hw_targets]
puts "Targets: $tgts"
open_hw_target [lindex $tgts 0]
puts "Devices: [get_hw_devices]"

# Keep target open - get the hw_server URL
set url [get_property CONN [get_hw_servers]]
puts "hw_server URL: $url"

# Now use xsdb (embedded in Vivado) to access ARM cores
# Vivado 2025.2 includes xsdb capability
puts "\n=== Trying xsdb from within Vivado ==="
catch {
    # Try the embedded debug commands
    xsdb::connect -url $url
    xsdb::targets
} msg
puts "xsdb result: $msg"

# Alternative: just get info about what we can see
puts "\n=== Device properties ==="
foreach dev [get_hw_devices] {
    puts "$dev -> [get_property PART $dev]"
}

# Don't close - leave for manual XSCT connection
puts "\n=== Target left OPEN on $url ==="
puts "=== Now run in another terminal: ==="
puts "=== xsct -eval 'connect -url $url; targets' ==="

# Wait a bit for manual testing
after 30000
close_hw_target
close_hw_manager

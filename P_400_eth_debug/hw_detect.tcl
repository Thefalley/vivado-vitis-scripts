# Detect hardware - try Vivado's hw_manager
open_hw_manager
connect_hw_server -allow_non_jtag
puts "=== HW Targets ==="
get_hw_targets
foreach t [get_hw_targets] {
    puts "Target: $t"
    catch {
        open_hw_target $t
        puts "  Devices: [get_hw_devices]"
        close_hw_target
    }
}
close_hw_manager

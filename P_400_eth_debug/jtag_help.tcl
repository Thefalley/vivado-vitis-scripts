# Get JTAG command help and try to fix DAP

# Use Vivado-style connection first (which works)
open_hw_manager
connect_hw_server -allow_non_jtag
puts "=== HW Targets ==="
set tgts [get_hw_targets]
puts $tgts

if {[llength $tgts] > 0} {
    open_hw_target [lindex $tgts 0]
    puts "Devices: [get_hw_devices]"

    # Try to refresh the device to clear DAP errors
    foreach dev [get_hw_devices] {
        puts "Refreshing $dev..."
        catch {refresh_hw_device $dev} msg
        puts "  Result: $msg"
    }

    puts "\n=== After refresh ==="
    puts "Devices: [get_hw_devices]"

    # Now try XSCT-style target listing
    # Vivado internally has the debug targets
    catch {
        puts "\n=== Attempting to access ARM via hw_device ==="
        current_hw_device [get_hw_devices arm_dap_0]
        puts "ARM DAP selected"
        # Try to get properties
        report_property [current_hw_device]
    } msg
    puts $msg

    close_hw_target
}

close_hw_manager

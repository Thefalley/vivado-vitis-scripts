# ==============================================================
# gen_bitstream.tcl
# Uso: vivado -mode batch -source tcl/gen_bitstream.tcl -tclargs <build_dir/project.xpr>
# ==============================================================

set xpr_path [lindex $argv 0]
open_project $xpr_path

# Check impl status, only run write_bitstream step
set impl_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $impl_status"

if {$impl_status eq "route_design Complete!"} {
    # Implementation done, just run write_bitstream
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
} elseif {$impl_status eq "write_bitstream Complete!"} {
    puts "Bitstream already generated"
} else {
    # Run full implementation + bitstream
    reset_run impl_1
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
}

puts "OK: Bitstream generated"

set xpr_path [lindex $argv 0]
open_project $xpr_path
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "ERROR: impl_1 did not complete"
    exit 1
}
puts "OK: Implementation + bitstream regenerated"

# Force full rebuild: reset all runs, relaunch synth then impl.
# Usage: vivado -mode batch -source tcl/rebuild_all.tcl -tclargs <xpr>

set xpr_path [lindex $argv 0]
open_project $xpr_path

puts "\n>>> Resetting all runs <<<\n"
foreach r [get_runs] {
    catch { reset_run $r }
}

puts "\n>>> Launching synth_1 <<<\n"
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed"
    exit 1
}

puts "\n>>> Launching impl_1 (with bitstream) <<<\n"
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set st [get_property STATUS [get_runs impl_1]]
if {$st ne "write_bitstream Complete!" && $st ne "route_design Complete!"} {
    puts "ERROR: Implementation failed (status: $st)"
    exit 1
}

puts "\nOK: Full rebuild complete"

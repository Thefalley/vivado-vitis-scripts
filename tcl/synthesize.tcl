# ==============================================================
# synthesize.tcl
# Uso: vivado -mode batch -source tcl/synthesize.tcl -tclargs <build_dir/project.xpr>
# ==============================================================

set xpr_path [lindex $argv 0]
open_project $xpr_path

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed"
    exit 1
}

puts "OK: Synthesis complete"

# ==============================================================
# synthesize.tcl
# Uso: vivado -mode batch -source tcl/synthesize.tcl -tclargs <build_dir/project.xpr>
# ==============================================================

set xpr_path [lindex $argv 0]
open_project $xpr_path

# For BD projects: ensure IP output products are generated before synthesis
# This prevents race conditions where OOC runs start before IP files exist
foreach bd [get_files -quiet *.bd] {
    generate_target all $bd
}

# Reset ALL synthesis runs (OOC + top) to ensure clean state
foreach run [get_runs -filter {IS_SYNTHESIS}] {
    set st [get_property STATUS $run]
    if {$st ne "synth_design Complete!"} {
        puts "Resetting run: $run (status: $st)"
        reset_run $run
    }
}

reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed"
    foreach run [get_runs -filter {IS_SYNTHESIS && NAME != "synth_1"}] {
        set st [get_property STATUS $run]
        if {$st ne "synth_design Complete!"} {
            puts "  FAILED OOC run: $run -- $st"
        }
    }
    exit 1
}

puts "OK: Synthesis complete"

# ==============================================================
# implement.tcl
# Uso: vivado -mode batch -source tcl/implement.tcl -tclargs <build_dir/project.xpr>
# ==============================================================

set xpr_path [lindex $argv 0]
open_project $xpr_path

launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {
    puts "ERROR: Implementation failed"
    exit 1
}

puts "OK: Implementation complete"

# ==============================================================
# gen_bitstream.tcl
# Uso: vivado -mode batch -source tcl/gen_bitstream.tcl -tclargs <build_dir/project.xpr>
# ==============================================================

set xpr_path [lindex $argv 0]
open_project $xpr_path

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

puts "OK: Bitstream generated"

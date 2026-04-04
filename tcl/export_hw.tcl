# ==============================================================
# export_hw.tcl
# Exporta hardware (.xsa) para Vitis
# Uso: vivado -mode batch -source tcl/export_hw.tcl -tclargs <project.xpr> <output.xsa>
# ==============================================================

set xpr_path [lindex $argv 0]
set xsa_path [lindex $argv 1]

open_project $xpr_path
write_hw_platform -fixed -include_bit -force -file $xsa_path

puts "OK: Hardware exportado a $xsa_path"

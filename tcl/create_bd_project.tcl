# ==============================================================
# create_bd_project.tcl
# Crea proyecto Vivado y ejecuta un script de Block Design
# Uso: vivado -mode batch -source tcl/create_bd_project.tcl -tclargs <project_dir> <name> <part> <bd_tcl>
# ==============================================================

set project_dir [lindex $argv 0]
set project_name [lindex $argv 1]
set part [lindex $argv 2]
set bd_tcl [lindex $argv 3]

set build_dir [file join $project_dir build]

# Create project
create_project $project_name $build_dir -part $part -force
set_property target_language Verilog [current_project]

# Try to set board part (may not be installed)
catch {set_property board_part avnet.com:zedboard:part0:1.4 [current_project]}

# Source the block design TCL
source [file join $project_dir $bd_tcl]

update_compile_order -fileset sources_1

puts "OK: Proyecto BD '$project_name' creado en $build_dir"

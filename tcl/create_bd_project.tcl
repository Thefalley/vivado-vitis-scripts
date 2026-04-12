# ==============================================================
# create_bd_project.tcl
# Crea proyecto Vivado y ejecuta un script de Block Design
# Uso: vivado -mode batch -source tcl/create_bd_project.tcl \
#        -tclargs <project_dir> <name> <part> <bd_tcl> [<top>]
# ==============================================================

set project_dir [lindex $argv 0]
set project_name [lindex $argv 1]
set part [lindex $argv 2]
set bd_tcl [lindex $argv 3]
# Optional: explicit top module name passed from build.py (project.cfg "top")
set explicit_top ""
if {$argc > 4} { set explicit_top [lindex $argv 4] }

set build_dir [file join $project_dir build]

# Create project
create_project $project_name $build_dir -part $part -force
set_property target_language Verilog [current_project]

# Try to set board part (may not be installed)
catch {set_property board_part avnet.com:zedboard:part0:1.4 [current_project]}

# Source the block design TCL
source [file join $project_dir $bd_tcl]

update_compile_order -fileset sources_1

# Lock the top module: use the explicit name from project.cfg if provided,
# otherwise keep whatever the BD TCL set.  Disable auto-detection so that
# Vivado does not silently pick a wrong module (e.g. conv_engine instead
# of the BD wrapper).
if {$explicit_top ne ""} {
    set final_top $explicit_top
} else {
    set final_top [get_property top [current_fileset]]
}
if {$final_top ne ""} {
    set_property top $final_top [current_fileset]
    set_property top_auto_set false [current_fileset]
    puts "INFO: Top module locked to: $final_top"
}

puts "OK: Proyecto BD '$project_name' creado en $build_dir"

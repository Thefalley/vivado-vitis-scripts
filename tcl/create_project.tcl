# ==============================================================
# create_project.tcl
# Uso: vivado -mode batch -source tcl/create_project.tcl -tclargs <project_dir> <name> <part> <top> <sources...> -constrs <xdc...> -sim <sim_top> <sim_sources...>
# ==============================================================

# --- Parse arguments ---
set project_dir [lindex $argv 0]
set project_name [lindex $argv 1]
set part [lindex $argv 2]
set top_module [lindex $argv 3]

set sources {}
set constrs {}
set sim_sources {}
set sim_top ""
set mode "sources"

for {set i 4} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-constrs"} {
        set mode "constrs"
    } elseif {$arg eq "-sim"} {
        set mode "sim"
        incr i
        set sim_top [lindex $argv $i]
    } else {
        switch $mode {
            "sources" { lappend sources $arg }
            "constrs" { lappend constrs $arg }
            "sim"     { lappend sim_sources $arg }
        }
    }
}

# --- Create project ---
set build_dir [file join $project_dir build]
create_project $project_name $build_dir -part $part -force

set_property target_language Verilog [current_project]

# --- Add sources ---
foreach src $sources {
    add_files -norecurse [file join $project_dir $src]
}
set_property top $top_module [current_fileset]

# --- Add constraints ---
foreach xdc $constrs {
    add_files -fileset constrs_1 -norecurse [file join $project_dir $xdc]
}

# --- Add simulation sources ---
if {[llength $sim_sources] > 0} {
    foreach sim $sim_sources {
        add_files -fileset sim_1 -norecurse [file join $project_dir $sim]
    }
    if {$sim_top ne ""} {
        set_property top $sim_top [get_filesets sim_1]
    }
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "OK: Proyecto '$project_name' creado en $build_dir"

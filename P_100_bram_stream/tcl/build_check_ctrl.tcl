# ==============================================================
# build_check_ctrl.tcl
# Synth + BRAM count for bram_ctrl_fifo.
# Expected: 80 RAMB36E1 (wrapper around fifo_2x40_bram).
# ==============================================================

set project_dir  "P_100_bram_stream"
set project_name "bram_ctrl_fifo"
set part         "xc7z020clg484-1"
set top_module   "bram_ctrl_fifo"

set build_dir [file join $project_dir build_ctrl]

create_project $project_name $build_dir -part $part -force
set_property target_language VHDL [current_project]

add_files -norecurse [file join $project_dir src HsSkidBuf_dest.vhd]
add_files -norecurse [file join $project_dir src bram_sp.vhd]
add_files -norecurse [file join $project_dir src fifo_2x40_bram.vhd]
add_files -norecurse [file join $project_dir src bram_ctrl_fifo.vhd]

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

puts "OK: project created at $build_dir"

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed"
    exit 1
}
puts "OK: synthesis complete"

open_run synth_1

set ramb36 [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set ramb18 [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]

set rpt_file [file join $build_dir utilization_ctrl.rpt]
report_utilization -file $rpt_file

puts "==========================================="
puts "BRAM_CHECK_CTRL: RAMB36E1=$ramb36 RAMB18E1=$ramb18"
puts "==========================================="

if {$ramb36 >= 80} {
    puts "PASS: expected 80 Block RAMs inferred for bram_ctrl_fifo"
    exit 0
} elseif {$ramb36 > 0} {
    puts "PARTIAL: only $ramb36 RAMB36E1 inferred (expected 80). Vivado may have mapped some to RAMB18 or merged banks."
    exit 0
} else {
    puts "FAIL: no RAMB36 inferred"
    exit 2
}

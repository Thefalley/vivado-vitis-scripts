# ==============================================================
# build_check_chain.tcl
# Synth + BRAM-count check for iteration 2 (bram_chain = 2x bram_stream).
# Expectation: 2 RAMB36E1 inferred (one per bram_sp instance).
#
#   vivado -mode batch -nojournal -nolog \
#          -source P_100_bram_stream/tcl/build_check_chain.tcl
# ==============================================================

set project_dir  "P_100_bram_stream"
set project_name "bram_chain"
set part         "xc7z020clg484-1"
set top_module   "bram_chain"

set build_dir [file join $project_dir build_chain]

create_project $project_name $build_dir -part $part -force
set_property target_language VHDL [current_project]

add_files -norecurse [file join $project_dir src HsSkidBuf_dest.vhd]
add_files -norecurse [file join $project_dir src bram_sp.vhd]
add_files -norecurse [file join $project_dir src bram_stream.vhd]
add_files -norecurse [file join $project_dir src bram_chain.vhd]

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

set rpt_file [file join $build_dir utilization_chain.rpt]
report_utilization -file $rpt_file

puts "==========================================="
puts "BRAM_CHECK_CHAIN: RAMB36E1=$ramb36 RAMB18E1=$ramb18"
puts "==========================================="

if {$ramb36 >= 2} {
    puts "PASS: 2 Block RAMs inferred for bram_chain"
    exit 0
} elseif {$ramb36 == 1 && $ramb18 >= 2} {
    puts "PASS: 2 Block RAMs inferred (1xRAMB36 + 2xRAMB18)"
    exit 0
} else {
    puts "FAIL: Expected >= 2 Block RAMs, got RAMB36=$ramb36 RAMB18=$ramb18"
    exit 2
}

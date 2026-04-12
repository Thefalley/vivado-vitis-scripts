# ==============================================================
# build_check.tcl
# One-shot script: create project, run synthesis, report BRAM usage.
# Intended to be run from the parent directory of P_100_bram_stream.
#
#   vivado -mode batch -nojournal -nolog \
#          -source P_100_bram_stream/tcl/build_check.tcl
# ==============================================================

set project_dir  "P_100_bram_stream"
set project_name "bram_stream"
set part         "xc7z020clg484-1"
set top_module   "bram_stream"

set build_dir [file join $project_dir build]

# --- Create project ---
create_project $project_name $build_dir -part $part -force
set_property target_language VHDL [current_project]

# --- Add sources (order matters for VHDL: low-level first) ---
add_files -norecurse [file join $project_dir src HsSkidBuf_dest.vhd]
add_files -norecurse [file join $project_dir src bram_sp.vhd]
add_files -norecurse [file join $project_dir src bram_stream.vhd]

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

puts "OK: project created at $build_dir"

# --- Run synthesis ---
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed"
    exit 1
}
puts "OK: synthesis complete"

# --- Open synth run and count primitives ---
open_run synth_1

set ramb36 [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
set ramb18 [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
set lutram32 [llength [get_cells -hier -filter {REF_NAME == RAM32X1S}]]
set lutram64 [llength [get_cells -hier -filter {REF_NAME == RAM64X1S}]]
set lutram128 [llength [get_cells -hier -filter {REF_NAME == RAM128X1S}]]
set lutram256 [llength [get_cells -hier -filter {REF_NAME == RAM256X1S}]]

set rpt_file [file join $build_dir utilization.rpt]
report_utilization -file $rpt_file

puts "==========================================="
puts "BRAM_CHECK: RAMB36E1=$ramb36 RAMB18E1=$ramb18"
puts "LUTRAM_CHECK: RAM32X1S=$lutram32 RAM64X1S=$lutram64 RAM128X1S=$lutram128 RAM256X1S=$lutram256"
puts "==========================================="

if {$ramb36 > 0 || $ramb18 > 0} {
    puts "PASS: Block RAM inferred"
    exit 0
} else {
    puts "FAIL: No Block RAM inferred (check coding style and ram_style attribute)"
    exit 2
}

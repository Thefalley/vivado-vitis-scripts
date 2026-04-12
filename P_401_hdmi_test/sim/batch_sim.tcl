# =============================================================================
# batch_sim.tcl - P_401 HDMI Test: batch simulation on server
#
# Usage (on server):
#   cd C:/Users/jce03/Desktop/claude/vivado-server/P_401_hdmi_test
#   E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source sim/batch_sim.tcl
#
# Creates project, compiles, simulates, saves WDB for later GUI viewing.
# =============================================================================

set base_dir [file dirname [file dirname [file normalize [info script]]]]
set proj_dir $base_dir/sim_proj
set src_dir  $base_dir/src
set sim_dir  $base_dir/sim

file delete -force $proj_dir

create_project hdmi_sim $proj_dir -part xc7z020clg484-1 -force
set_property target_language VHDL [current_project]

# RTL sources (only timing + color bars needed for sim, no MMCM/I2C)
add_files -norecurse [list \
    $src_dir/video_timing.vhd \
    $src_dir/color_bars.vhd   \
]

# Testbench
add_files -fileset sim_1 -norecurse $sim_dir/tb_hdmi_top.vhd
set_property top tb_hdmi_top [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Run behavioral simulation in batch mode
launch_simulation -mode behavioral
run 150 us

puts "=== SIMULATION COMPLETE ==="
puts "WDB file: [current_sim]/tb_hdmi_top.wdb"

close_sim
close_project

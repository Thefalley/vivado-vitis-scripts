# =============================================================================
# open_sim.tcl - P_401 HDMI Test: behavioral simulation with waveform GUI
#
# Usage:
#   vivado -source P_401_hdmi_test/sim/open_sim.tcl
#
# Creates a temporary project, compiles, launches simulation and shows waves.
# =============================================================================

set base_dir [file dirname [file dirname [file normalize [info script]]]]
set proj_dir $base_dir/sim_proj
set src_dir  $base_dir/src
set sim_dir  $base_dir/sim

file delete -force $proj_dir

create_project hdmi_sim $proj_dir -part xc7z020clg484-1 -force
set_property target_language VHDL [current_project]

# RTL sources
add_files -norecurse [list \
    $src_dir/video_timing.vhd \
    $src_dir/color_bars.vhd   \
]

# Testbench
add_files -fileset sim_1 -norecurse $sim_dir/tb_hdmi_top.vhd
set_property top tb_hdmi_top [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Launch behavioral simulation (opens xsim inside Vivado GUI)
launch_simulation

# ---- Waveform setup ----

add_wave -divider "Clock / Reset"
add_wave /tb_hdmi_top/clk
add_wave /tb_hdmi_top/rst

add_wave -divider "Video Timing"
add_wave /tb_hdmi_top/hsync
add_wave /tb_hdmi_top/vsync
add_wave /tb_hdmi_top/de
add_wave -radix unsigned /tb_hdmi_top/pixel_x
add_wave -radix unsigned /tb_hdmi_top/pixel_y

add_wave -divider "Color Output"
add_wave -radix hex /tb_hdmi_top/r_out
add_wave -radix hex /tb_hdmi_top/g_out
add_wave -radix hex /tb_hdmi_top/b_out
add_wave /tb_hdmi_top/cb_de

add_wave -divider "Timing Internals"
add_wave -radix unsigned /tb_hdmi_top/u_timing/h_cnt
add_wave -radix unsigned /tb_hdmi_top/u_timing/v_cnt

# Run simulation
run 150 us

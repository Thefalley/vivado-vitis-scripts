# =============================================================================
# build.tcl - P_401 HDMI Test: PL-only build (no Zynq PS)
#
# Usage (on server):
#   cd C:/Users/jce03/Desktop/claude/vivado-server/P_401_hdmi_test
#   E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source vivado/build.tcl
#
# Creates project, compiles VHDL, synthesizes, implements, generates bitstream.
# =============================================================================

set base_dir [file dirname [file dirname [file normalize [info script]]]]
set proj_dir $base_dir/build
set src_dir  $base_dir/src
set xdc_dir  $base_dir/vivado

puts "============================================"
puts " P_401 HDMI Color Bar Test - Build"
puts " Base dir: $base_dir"
puts "============================================"

# Clean previous build
file delete -force $proj_dir

# Create project (PL-only, no block design)
create_project hdmi_test $proj_dir -part xc7z020clg484-1 -force
set_property target_language VHDL [current_project]

# Add VHDL sources
add_files -norecurse [list \
    $src_dir/video_timing.vhd \
    $src_dir/color_bars.vhd   \
    $src_dir/i2c_init.vhd     \
    $src_dir/hdmi_top.vhd     \
]

# Set top module
set_property top hdmi_top [current_fileset]

# Add constraints
add_files -fileset constrs_1 -norecurse $xdc_dir/zedboard_hdmi.xdc

# Update compile order
update_compile_order -fileset sources_1

# ---- Synthesis ----
puts ">>> Running Synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"
if {[string match "*ERROR*" $synth_status] || [string match "*FAILED*" $synth_status]} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# ---- Implementation ----
puts ">>> Running Implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: $impl_status"
if {[string match "*ERROR*" $impl_status] || [string match "*FAILED*" $impl_status]} {
    puts "ERROR: Implementation failed!"
    exit 1
}

# ---- Bitstream ----
puts ">>> Generating Bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "Bitstream generation complete."

# Copy bitstream to a convenient location
set bit_file [glob -nocomplain $proj_dir/hdmi_test.runs/impl_1/*.bit]
if {$bit_file ne ""} {
    file copy -force $bit_file $base_dir/hdmi_test.bit
    puts "Bitstream copied to: $base_dir/hdmi_test.bit"
} else {
    puts "WARNING: Bitstream file not found in impl_1 directory"
}

puts "============================================"
puts " BUILD COMPLETE"
puts "============================================"

close_project

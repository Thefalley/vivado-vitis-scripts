# build_all.tcl — Full build: BD + Synth + Impl + Bitstream + XSA
# Run: vivado -mode batch -source build_all.tcl

set part xc7z020clg400-1
set proj_name conv_simple_proj
set bd_name conv_bd

# ============================================================
# 1. Create project
# ============================================================
create_project $proj_name . -part $part -force
set_property target_language VHDL [current_project]

# ============================================================
# 2. Add RTL sources
# ============================================================
add_files -norecurse {
    src/mul_s32x32_pipe.vhd
    src/mac_unit.vhd
    src/mac_array.vhd
    src/requantize.vhd
    src/conv_simple.vhd
    src/axi_lite_conv.vhd
    src/conv_simple_top.vhd
}
update_compile_order -fileset sources_1

# ============================================================
# 3. Create Block Design
# ============================================================
create_bd_design $bd_name

# Zynq PS
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} $ps
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] $ps

# Our IP (RTL module reference)
set conv [create_bd_cell -type module -reference conv_simple_top conv_top_0]

# AXI Interconnect
set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic]
set_property CONFIG.NUM_MI {1} $ic

# Connect PS GP0 -> IC -> conv_top
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins conv_top_0/S_AXI]

# Clocks
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins axi_ic/ACLK] \
    [get_bd_pins axi_ic/S00_ACLK] \
    [get_bd_pins axi_ic/M00_ACLK] \
    [get_bd_pins conv_top_0/S_AXI_ACLK]

# Reset
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_0]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] \
    [get_bd_pins axi_ic/ARESETN] \
    [get_bd_pins axi_ic/S00_ARESETN] \
    [get_bd_pins axi_ic/M00_ARESETN] \
    [get_bd_pins conv_top_0/S_AXI_ARESETN]

# Address: conv_top at 0x40000000, 32KB
assign_bd_address -target_address_space ps7/Data \
    [get_bd_addr_segs conv_top_0/S_AXI/reg0] \
    -range 32K -offset 0x40000000

validate_bd_design
save_bd_design

# Generate BD wrapper
make_wrapper -files [get_files $bd_name.bd] -top
add_files -norecurse $proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.vhd
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ============================================================
# 4. Synthesize
# ============================================================
puts "=== SYNTHESIS ==="
launch_runs synth_1 -jobs 6
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed"
    exit 1
}
puts "=== SYNTH OK ==="

# Report timing after synth
open_run synth_1
set wns_synth [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "WNS (synth) = $wns_synth ns"

# ============================================================
# 5. Implementation
# ============================================================
puts "=== IMPLEMENTATION ==="
launch_runs impl_1 -jobs 6
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {
    puts "ERROR: Implementation failed"
    exit 1
}
puts "=== IMPL OK ==="

# ============================================================
# 6. Bitstream
# ============================================================
puts "=== BITSTREAM ==="
launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1
puts "=== BITSTREAM OK ==="

# Report timing after impl
open_run impl_1
report_timing_summary -file impl_timing.rpt
set wns_impl [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "WNS (impl) = $wns_impl ns"
report_utilization -file impl_util.rpt

# ============================================================
# 7. Export XSA
# ============================================================
puts "=== EXPORT XSA ==="
write_hw_platform -fixed -include_bit -force conv_simple.xsa
puts "=== BUILD COMPLETE ==="
puts "  Bitstream: conv_simple_proj.runs/impl_1/${bd_name}_wrapper.bit"
puts "  XSA:       conv_simple.xsa"
puts "  WNS:       $wns_impl ns"

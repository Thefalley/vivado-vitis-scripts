# Block Design: Zynq PS + AXI-Lite -> conv_test_wrapper (no DMA)

create_bd_design "zynq_conv_bd"

set proj_dir [get_property DIRECTORY [current_project]]
set src_dir [file normalize [file join $proj_dir ../src]]

read_vhdl [file join $src_dir mac_unit.vhd]
read_vhdl [file join $src_dir mac_array.vhd]
read_vhdl [file join $src_dir mul_s32x32_pipe.vhd]
read_vhdl [file join $src_dir requantize.vhd]
read_vhdl [file join $src_dir conv_engine.vhd]
read_vhdl [file join $src_dir conv_engine_v2.vhd]
read_vhdl [file join $src_dir conv_test_wrapper.vhd]
update_compile_order -fileset sources_1

# Zynq PS
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
if {[catch {set_property -dict [list CONFIG.preset {ZedBoard}] $zynq}]} {}
set_property -dict [list \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41J128M16HA-15E} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {2048 MBits} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {90} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
] $zynq

# conv_test_wrapper (module reference)
create_bd_cell -type module -reference conv_test_wrapper conv_test_wrapper_0

# AXI interconnect: 1 master (PS GP0) -> 1 slave (wrapper)
set ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $ic_gp0

# Proc sys reset
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

# Clock connections
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins conv_test_wrapper_0/s_axi_aclk] \
    [get_bd_pins axi_ic_gp0/ACLK] [get_bd_pins axi_ic_gp0/S00_ACLK] [get_bd_pins axi_ic_gp0/M00_ACLK] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

# Reset connections
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins axi_ic_gp0/ARESETN] [get_bd_pins axi_ic_gp0/S00_ARESETN] [get_bd_pins axi_ic_gp0/M00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins conv_test_wrapper_0/s_axi_aresetn]

# AXI connections: PS GP0 -> interconnect -> wrapper
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M00_AXI] [get_bd_intf_pins conv_test_wrapper_0/s_axi]

# DDR and FIXED_IO
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} $zynq

assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files zynq_conv_bd.bd] -top
set bd_dir [file dirname [get_files zynq_conv_bd.bd]]
add_files -norecurse [file normalize "$bd_dir/hdl/zynq_conv_bd_wrapper.v"]
set_property top zynq_conv_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "OK: Block Design zynq_conv_bd"

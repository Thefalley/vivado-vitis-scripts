# Block Design: Zynq PS + AXI DMA + mac_test_stream

create_bd_design "zynq_mac_bd"

set proj_dir [get_property DIRECTORY [current_project]]
set src_dir [file normalize [file join $proj_dir ../src]]

read_vhdl [file join $src_dir mac_unit.vhd]
read_vhdl [file join $src_dir mac_array.vhd]
read_vhdl [file join $src_dir mac_test_stream.vhd]
update_compile_order -fileset sources_1

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
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] $zynq

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_mm2s_burst_size {256} \
    CONFIG.c_s2mm_burst_size {256} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
] $dma

create_bd_cell -type module -reference mac_test_stream mac_test_stream_0

set ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $ic_gp0
set ic_hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] $ic_hp0

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]
set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property -dict [list CONFIG.NUM_PORTS {2}] $concat

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] [get_bd_pins mac_test_stream_0/clk] \
    [get_bd_pins axi_ic_gp0/ACLK] [get_bd_pins axi_ic_gp0/S00_ACLK] [get_bd_pins axi_ic_gp0/M00_ACLK] \
    [get_bd_pins axi_ic_hp0/ACLK] [get_bd_pins axi_ic_hp0/S00_ACLK] [get_bd_pins axi_ic_hp0/S01_ACLK] \
    [get_bd_pins axi_ic_hp0/M00_ACLK] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins axi_ic_gp0/ARESETN] [get_bd_pins axi_ic_gp0/S00_ARESETN] [get_bd_pins axi_ic_gp0/M00_ARESETN] \
    [get_bd_pins axi_ic_hp0/ARESETN] [get_bd_pins axi_ic_hp0/S00_ARESETN] [get_bd_pins axi_ic_hp0/S01_ARESETN] \
    [get_bd_pins axi_ic_hp0/M00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] [get_bd_pins mac_test_stream_0/resetn]

connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M00_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_ic_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_ic_hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_hp0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]

connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins mac_test_stream_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins mac_test_stream_0/m_axis] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins ps7/IRQ_F2P]

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} $zynq

assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files zynq_mac_bd.bd] -top
set bd_dir [file dirname [get_files zynq_mac_bd.bd]]
add_files -norecurse [file normalize "$bd_dir/hdl/zynq_mac_bd_wrapper.v"]
set_property top zynq_mac_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "OK: Block Design zynq_mac_bd"

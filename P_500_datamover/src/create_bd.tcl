# ==============================================================
# create_bd.tcl - Block Design: ZedBoard + AXI DataMover Study
# P_500_datamover
#
# Arquitectura:
#   Zynq PS --M_AXI_GP0--> AXI IC --> {DMA S_AXI_LITE, GPIO_addr, GPIO_ctrl}
#
#   Data path:
#     ARM escribe datos test en DDR[src_addr]
#     DMA MM2S lee DDR[src_addr] --> AXI-Stream
#     AXI-Stream --> DataMover S2MM --> escribe DDR[dest_addr]
#
#   Control path:
#     ARM configura dest_addr via GPIO_addr
#     ARM configura byte_count + start via GPIO_ctrl
#     dm_s2mm_ctrl genera comando 72-bit --> DataMover
#     DataMover responde status --> dm_s2mm_ctrl
#     ARM lee status via GPIO_ctrl channel 2
#
# ==============================================================

# --- Add RTL sources (needed before module reference) ---
set src_dir [file dirname [info script]]
add_files -fileset sources_1 [file join $src_dir rtl/dm_s2mm_ctrl.vhd]
update_compile_order -fileset sources_1

# --- Create Block Design ---
create_bd_design "dm_study_bd"

# ==============================================================
# 1. Zynq Processing System (ZedBoard)
# ==============================================================
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]

if {[catch {set_property -dict [list CONFIG.preset {ZedBoard}] $zynq}]} {
    puts "WARN: ZedBoard preset not available, configuring manually"
}

# ZedBoard DDR3 (MT41J128M16HA-15E, 512MB)
set_property -dict [list \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41J128M16HA-15E} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {2048 MBits} \
    CONFIG.PCW_UIPARAM_DDR_T_FAW {40.0} \
    CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN {35.0} \
    CONFIG.PCW_UIPARAM_DDR_T_RC {48.75} \
    CONFIG.PCW_UIPARAM_DDR_CWL {6} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
] $zynq

set_property -dict [list \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] $zynq

# ==============================================================
# 2. AXI DMA (MM2S only - data source from DDR)
# ==============================================================
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_mm2s_burst_size {256} \
] $dma

# ==============================================================
# 3. AXI DataMover (S2MM only - writes stream data to DDR)
#    This is the IP we're studying!
# ==============================================================
# Try creating DataMover - handle version differences (2022.2 vs 2025.2.1)
set dm_ok 0
foreach vlnv {"xilinx.com:ip:axi_datamover:5.1" "xilinx.com:ip:axi_datamover"} {
    if {![catch {create_bd_cell -type ip -vlnv $vlnv axi_datamover_0}]} {
        set dm_ok 1
        puts "OK: DataMover created with VLNV: $vlnv"
        break
    }
}
if {!$dm_ok} {
    error "ERROR: Cannot create axi_datamover. Check IP catalog."
}

set_property -dict [list \
    CONFIG.c_enable_mm2s {0} \
    CONFIG.c_s2mm_btt_used {23} \
    CONFIG.c_s2mm_burst_size {256} \
] [get_bd_cells axi_datamover_0]

# ==============================================================
# 4. dm_s2mm_ctrl (custom RTL - command generator)
# ==============================================================
set ctrl [create_bd_cell -type module -reference dm_s2mm_ctrl dm_s2mm_ctrl_0]

# ==============================================================
# 5. AXI GPIO - Address register (32-bit output)
# ==============================================================
set gpio_addr [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio_addr]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_DOUT_DEFAULT {0x10000000} \
] $gpio_addr

# ==============================================================
# 6. AXI GPIO - Control/Status (dual channel)
#    Ch1: 32-bit output [22:0]=BTT, [31]=start
#    Ch2: 32-bit input  [0]=busy, [1]=done, [2]=error, [11:4]=sts
# ==============================================================
set gpio_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 gpio_ctrl]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] $gpio_ctrl

# ==============================================================
# 7. Infrastructure: Reset, Interrupt concat, Interconnects
# ==============================================================
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property CONFIG.NUM_PORTS {3} $concat

# GP0 interconnect: PS -> {DMA, GPIO_addr, GPIO_ctrl}
set ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {3} CONFIG.NUM_SI {1}] $ic_gp0

# HP0 interconnect: {DMA MM2S, DataMover S2MM} -> PS DDR
set ic_hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] $ic_hp0

# ==============================================================
# CONNECTIONS
# ==============================================================

# --- Clocks ---
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_datamover_0/m_axi_s2mm_aclk] \
    [get_bd_pins axi_datamover_0/m_axis_s2mm_cmdsts_awclk] \
    [get_bd_pins dm_s2mm_ctrl_0/clk] \
    [get_bd_pins gpio_addr/s_axi_aclk] \
    [get_bd_pins gpio_ctrl/s_axi_aclk] \
    [get_bd_pins axi_ic_gp0/ACLK] \
    [get_bd_pins axi_ic_gp0/S00_ACLK] \
    [get_bd_pins axi_ic_gp0/M00_ACLK] \
    [get_bd_pins axi_ic_gp0/M01_ACLK] \
    [get_bd_pins axi_ic_gp0/M02_ACLK] \
    [get_bd_pins axi_ic_hp0/ACLK] \
    [get_bd_pins axi_ic_hp0/S00_ACLK] \
    [get_bd_pins axi_ic_hp0/S01_ACLK] \
    [get_bd_pins axi_ic_hp0/M00_ACLK] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

# --- Resets ---
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins axi_ic_gp0/ARESETN] \
    [get_bd_pins axi_ic_gp0/S00_ARESETN] \
    [get_bd_pins axi_ic_gp0/M00_ARESETN] \
    [get_bd_pins axi_ic_gp0/M01_ARESETN] \
    [get_bd_pins axi_ic_gp0/M02_ARESETN] \
    [get_bd_pins axi_ic_hp0/ARESETN] \
    [get_bd_pins axi_ic_hp0/S00_ARESETN] \
    [get_bd_pins axi_ic_hp0/S01_ARESETN] \
    [get_bd_pins axi_ic_hp0/M00_ARESETN]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins axi_datamover_0/m_axi_s2mm_aresetn] \
    [get_bd_pins axi_datamover_0/m_axis_s2mm_cmdsts_aresetn] \
    [get_bd_pins dm_s2mm_ctrl_0/resetn] \
    [get_bd_pins gpio_addr/s_axi_aresetn] \
    [get_bd_pins gpio_ctrl/s_axi_aresetn]

# --- AXI GP0 path: PS -> Interconnect -> peripherals ---
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
    [get_bd_intf_pins axi_ic_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M00_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M01_AXI] \
    [get_bd_intf_pins gpio_addr/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M02_AXI] \
    [get_bd_intf_pins gpio_ctrl/S_AXI]

# --- AXI HP0 path: DMA + DataMover -> Interconnect -> PS DDR ---
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins axi_ic_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_datamover_0/M_AXI_S2MM] \
    [get_bd_intf_pins axi_ic_hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_hp0/M00_AXI] \
    [get_bd_intf_pins ps7/S_AXI_HP0]

# --- Data stream: DMA MM2S output -> DataMover S2MM data input ---
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins axi_datamover_0/S_AXIS_S2MM]

# --- dm_s2mm_ctrl <-> DataMover command/status ---
# Command: dm_s2mm_ctrl -> DataMover S2MM CMD
connect_bd_net [get_bd_pins dm_s2mm_ctrl_0/cmd_tdata]  [get_bd_pins axi_datamover_0/s_axis_s2mm_cmd_tdata]
connect_bd_net [get_bd_pins dm_s2mm_ctrl_0/cmd_tvalid] [get_bd_pins axi_datamover_0/s_axis_s2mm_cmd_tvalid]
connect_bd_net [get_bd_pins dm_s2mm_ctrl_0/cmd_tready] [get_bd_pins axi_datamover_0/s_axis_s2mm_cmd_tready]

# Status: DataMover S2MM STS -> dm_s2mm_ctrl
connect_bd_net [get_bd_pins axi_datamover_0/m_axis_s2mm_sts_tdata]  [get_bd_pins dm_s2mm_ctrl_0/sts_tdata]
connect_bd_net [get_bd_pins axi_datamover_0/m_axis_s2mm_sts_tvalid] [get_bd_pins dm_s2mm_ctrl_0/sts_tvalid]
connect_bd_net [get_bd_pins axi_datamover_0/m_axis_s2mm_sts_tready] [get_bd_pins dm_s2mm_ctrl_0/sts_tready]
connect_bd_net [get_bd_pins axi_datamover_0/m_axis_s2mm_sts_tkeep]  [get_bd_pins dm_s2mm_ctrl_0/sts_tkeep]
connect_bd_net [get_bd_pins axi_datamover_0/m_axis_s2mm_sts_tlast]  [get_bd_pins dm_s2mm_ctrl_0/sts_tlast]

# --- GPIO <-> dm_s2mm_ctrl ---
connect_bd_net [get_bd_pins gpio_addr/gpio_io_o] [get_bd_pins dm_s2mm_ctrl_0/dest_addr]
connect_bd_net [get_bd_pins gpio_ctrl/gpio_io_o] [get_bd_pins dm_s2mm_ctrl_0/ctrl_reg]
connect_bd_net [get_bd_pins dm_s2mm_ctrl_0/status_reg] [get_bd_pins gpio_ctrl/gpio2_io_i]

# --- Interrupts ---
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut]      [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins dm_s2mm_ctrl_0/done_irq]      [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins axi_datamover_0/s2mm_err]     [get_bd_pins xlconcat_0/In2]
connect_bd_net [get_bd_pins xlconcat_0/dout]              [get_bd_pins ps7/IRQ_F2P]

# --- DDR and FIXED_IO ---
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} $zynq

# ==============================================================
# Address mapping
# ==============================================================
assign_bd_address

# ==============================================================
# Validate and save
# ==============================================================
regenerate_bd_layout
validate_bd_design
save_bd_design

# --- Generate wrapper ---
make_wrapper -files [get_files dm_study_bd.bd] -top
set bd_dir [file dirname [get_files dm_study_bd.bd]]
set wrapper_file [file normalize "$bd_dir/hdl/dm_study_bd_wrapper.v"]
add_files -norecurse $wrapper_file
set_property top dm_study_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "============================================================"
puts "OK: Block Design 'dm_study_bd' created"
puts "  - Zynq PS (ZedBoard, DDR 512MB)"
puts "  - AXI DMA (MM2S only - data source)"
puts "  - AXI DataMover (S2MM only - the IP under study)"
puts "  - dm_s2mm_ctrl (command generator, GPIO-controlled)"
puts "  - 2x AXI GPIO (addr + ctrl/status)"
puts "  - Interrupts: DMA mm2s + done + s2mm_err"
puts "============================================================"

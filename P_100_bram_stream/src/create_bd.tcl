# ==============================================================
# create_bd.tcl - Block Design: Zynq PS + AXI DMA + bram_stream
# ZedBoard (xc7z020clg484-1)
#
# Architecture:
#   Zynq PS --M_AXI_GP0--> AXI IC --> AXI DMA (S_AXI_LITE)
#   AXI DMA M_AXIS_MM2S --> bram_stream s_axis
#   bram_stream m_axis  --> AXI DMA S_AXIS_S2MM
#   AXI DMA --M_AXI_MM2S/S2MM--> AXI IC --> Zynq PS (S_AXI_HP0) --> DDR
#
# Flow: ARM launches DMA write+read from DDR -> bram_stream (stores into
#       BRAM) -> DMA writes result back to DDR. bram_stream replays the
#       N words it received after tlast.
#
# Difference vs P_4: bram_stream has NO AXI-Lite config port, so the
# GP0 interconnect only needs 1 master (DMA control). No config register.
# ==============================================================

create_bd_design "bram_stream_bd"

# ==============================================================
# 1. Add RTL sources
# ==============================================================
set proj_dir [get_property DIRECTORY [current_project]]
set src_dir [file normalize [file join $proj_dir ../src]]

read_vhdl [file join $src_dir HsSkidBuf_dest.vhd]
read_vhdl [file join $src_dir bram_sp.vhd]
read_vhdl [file join $src_dir bram_stream.vhd]
update_compile_order -fileset sources_1

# ==============================================================
# 2. Zynq PS
# ==============================================================
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]

if {[catch {set_property -dict [list CONFIG.preset {ZedBoard}] $zynq}]} {
    puts "WARN: ZedBoard preset not available, configuring manually"
}

# DDR3 ZedBoard
set_property -dict [list \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41J128M16HA-15E} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {2048 MBits} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
] $zynq

# UART1 + clocks + interfaces
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
# 3. AXI DMA (Simple mode, no SG)
# ==============================================================
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_mm2s_burst_size {256} \
    CONFIG.c_s2mm_burst_size {256} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
] $dma

# ==============================================================
# 4. bram_stream (our RTL module)
# ==============================================================
create_bd_cell -type module -reference bram_stream bram_stream_0

# ==============================================================
# 5. AXI Interconnects
# ==============================================================

# GP0 interconnect: Zynq GP0 -> DMA S_AXI_LITE (only 1 slave, no config IP)
set ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $ic_gp0

# HP0 interconnect: DMA MM2S/S2MM -> Zynq HP0 (DDR)
set ic_hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] $ic_hp0

# ==============================================================
# 6. Reset + interrupt concat
# ==============================================================
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]
set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property -dict [list CONFIG.NUM_PORTS {2}] $concat

# ==============================================================
# CONNECTIONS
# ==============================================================

# --- Clocks ---
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins bram_stream_0/clk] \
    [get_bd_pins axi_ic_gp0/ACLK] \
    [get_bd_pins axi_ic_gp0/S00_ACLK] \
    [get_bd_pins axi_ic_gp0/M00_ACLK] \
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
    [get_bd_pins axi_ic_hp0/ARESETN] \
    [get_bd_pins axi_ic_hp0/S00_ARESETN] \
    [get_bd_pins axi_ic_hp0/S01_ARESETN] \
    [get_bd_pins axi_ic_hp0/M00_ARESETN]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins bram_stream_0/resetn]

# --- AXI GP0: Zynq -> IC -> DMA control (M00 only) ---
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
    [get_bd_intf_pins axi_ic_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M00_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# --- AXI HP0: DMA -> IC -> Zynq DDR ---
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins axi_ic_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins axi_ic_hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_hp0/M00_AXI] \
    [get_bd_intf_pins ps7/S_AXI_HP0]

# --- Stream: DMA MM2S -> bram_stream -> DMA S2MM ---
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins bram_stream_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins bram_stream_0/m_axis] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# --- Interrupts ---
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins ps7/IRQ_F2P]

# --- DDR + FIXED_IO ---
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} $zynq

# ==============================================================
# Address map, validate, wrap
# ==============================================================
assign_bd_address

regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files bram_stream_bd.bd] -top
set bd_dir [file dirname [get_files bram_stream_bd.bd]]
set wrapper_file [file normalize "$bd_dir/hdl/bram_stream_bd_wrapper.v"]
add_files -norecurse $wrapper_file
set_property top bram_stream_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "OK: Block Design 'bram_stream_bd' created"
puts "  - Zynq PS + DDR + UART1"
puts "  - AXI DMA (MM2S + S2MM, simple mode)"
puts "  - bram_stream (no AXI-Lite config) between MM2S and S2MM"

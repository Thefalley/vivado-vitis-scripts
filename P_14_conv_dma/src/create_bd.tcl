# ==============================================================
# create_bd.tcl - Block Design: Zynq PS + AXI DMA + conv_test_wrapper
# ZedBoard (xc7z020clg484-1)
#
# Arquitectura:
#   Zynq PS --M_AXI_GP0--> AXI Interconnect --> { DMA ctrl, conv_wrapper ctrl }
#   AXI DMA --M_AXI_MM2S/S2MM--> AXI Interconnect --> Zynq PS (S_AXI_HP0) --> DDR
#   DMA streams loopback (placeholder — no AXI-Stream en wrapper todavia)
#
# Fase 1 (este archivo): infraestructura DMA lista, datos via AXI-Lite
#   - ARM carga BRAM via AXI-Lite (igual que P_13)
#   - ARM configura y ejecuta conv_engine via AXI-Lite
#   - DMA presente pero en loopback (listo para fase 2)
#
# Fase 2 (futuro): conv_dma_wrapper con AXI-Stream ports
#   - DMA MM2S -> wrapper BRAM (carga datos a throughput maximo)
#   - wrapper BRAM -> DMA S2MM (drena resultados)
# ==============================================================

create_bd_design "conv_dma_bd"

set proj_dir [get_property DIRECTORY [current_project]]
set src_dir [file normalize [file join $proj_dir ../src]]

# --- VHDL sources (reuse from P_13) ---
read_vhdl [file join $src_dir ../../P_13_conv_test/src/mac_unit.vhd]
read_vhdl [file join $src_dir ../../P_13_conv_test/src/mac_array.vhd]
read_vhdl [file join $src_dir ../../P_13_conv_test/src/mul_s32x32_pipe.vhd]
read_vhdl [file join $src_dir ../../P_13_conv_test/src/requantize.vhd]
read_vhdl [file join $src_dir ../../P_13_conv_test/src/conv_engine.vhd]
read_vhdl [file join $src_dir ../../P_13_conv_test/src/conv_engine_v2.vhd]
read_vhdl [file join $src_dir ../../P_13_conv_test/src/conv_test_wrapper.vhd]
update_compile_order -fileset sources_1

# ==============================================================
# 1. Zynq Processing System (ZedBoard, DDR3, GP0 + HP0, FCLK0=90MHz)
# ==============================================================
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
if {[catch {set_property -dict [list CONFIG.preset {ZedBoard}] $zynq}]} {
    puts "WARN: ZedBoard preset not available, configuring manually"
}
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
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] $zynq

# ==============================================================
# 2. AXI DMA (Simple mode, no Scatter-Gather, MM2S + S2MM)
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
# 3. conv_test_wrapper (module reference — reuses P_13 wrapper as-is)
# ==============================================================
create_bd_cell -type module -reference conv_test_wrapper conv_test_wrapper_0

# ==============================================================
# 4. AXI Interconnects
# ==============================================================

# GP0 interconnect: 1 master (PS GP0) -> 2 slaves (DMA ctrl + wrapper ctrl)
set ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {2} CONFIG.NUM_SI {1}] $ic_gp0

# HP0 interconnect: 2 masters (DMA MM2S + S2MM) -> 1 slave (DDR via PS HP0)
set ic_hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] $ic_hp0

# ==============================================================
# 5. Processor System Reset
# ==============================================================
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

# ==============================================================
# 6. IRQ Concat (DMA interrupts -> PS IRQ_F2P)
# ==============================================================
set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property -dict [list CONFIG.NUM_PORTS {2}] $concat

# ==============================================================
# CONNECTIONS
# ==============================================================

# --- Clocks: everything on FCLK_CLK0 (90 MHz) ---
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins conv_test_wrapper_0/s_axi_aclk] \
    [get_bd_pins axi_ic_gp0/ACLK] \
    [get_bd_pins axi_ic_gp0/S00_ACLK] \
    [get_bd_pins axi_ic_gp0/M00_ACLK] \
    [get_bd_pins axi_ic_gp0/M01_ACLK] \
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
    [get_bd_pins axi_ic_hp0/ARESETN] \
    [get_bd_pins axi_ic_hp0/S00_ARESETN] \
    [get_bd_pins axi_ic_hp0/S01_ARESETN] \
    [get_bd_pins axi_ic_hp0/M00_ARESETN]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins conv_test_wrapper_0/s_axi_aresetn]

# --- AXI GP0 path: PS -> IC -> {DMA ctrl, wrapper ctrl} ---
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
    [get_bd_intf_pins axi_ic_gp0/S00_AXI]

# M00 -> DMA S_AXI_LITE (register control)
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M00_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# M01 -> conv_test_wrapper s_axi (BRAM + config registers)
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M01_AXI] \
    [get_bd_intf_pins conv_test_wrapper_0/s_axi]

# --- AXI HP0 path: DMA -> IC -> DDR ---
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins axi_ic_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins axi_ic_hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_hp0/M00_AXI] \
    [get_bd_intf_pins ps7/S_AXI_HP0]

# --- DMA Stream Loopback (Fase 1: MM2S -> S2MM directo) ---
# En Fase 2 esto se reemplaza por: MM2S -> wrapper -> S2MM
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# --- Interrupts: DMA mm2s + s2mm -> concat -> PS IRQ_F2P ---
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins ps7/IRQ_F2P]

# --- DDR and FIXED_IO external ports ---
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

# Generate wrapper
make_wrapper -files [get_files conv_dma_bd.bd] -top
set bd_dir [file dirname [get_files conv_dma_bd.bd]]
add_files -norecurse [file normalize "$bd_dir/hdl/conv_dma_bd_wrapper.v"]
set_property top conv_dma_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "OK: Block Design 'conv_dma_bd'"
puts "  - Zynq PS (90 MHz, DDR, GP0 + HP0, IRQ)"
puts "  - AXI DMA (simple mode, MM2S + S2MM, loopback)"
puts "  - conv_test_wrapper (AXI-Lite, reused from P_13)"
puts "  - GP0: 2 slaves (DMA ctrl @ M00, wrapper @ M01)"
puts "  - HP0: 2 masters (DMA MM2S + S2MM) -> DDR"
puts "  - Fase 1: datos via AXI-Lite, DMA en loopback"

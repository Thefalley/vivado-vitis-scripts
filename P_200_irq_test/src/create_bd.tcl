# ==============================================================
# create_bd.tcl - Block Design: Zynq PS + irq_top (AXI-Lite + IRQ)
# ZedBoard (xc7z020clg484-1)
#
# Arquitectura:
#   Zynq PS --M_AXI_GP0--> AXI Interconnect --> irq_top (S_AXI)
#   irq_top.irq_out -----> Zynq PS IRQ_F2P[0]
#
# Registros AXI-Lite de irq_top (base = auto-asignada):
#   0x00 CTRL       R/W   bit0=start, bit1=irq_clear
#   0x04 THRESHOLD  R/W   ciclos a contar
#   0x08 CONDITION  R/W   valor de comparacion
#   0x0C STATUS     R/O   estado FSM + irq_pending
#   0x10 COUNT      R/O   valor del contador
#   0x14 IRQ_COUNT  R/O   total interrupciones
# ==============================================================

# --- Create Block Design ---
create_bd_design "irq_test_bd"

# ==============================================================
# 1. Add RTL sources (irq_top + dependencies)
# ==============================================================
set proj_dir [get_property DIRECTORY [current_project]]
set src_dir [file normalize [file join $proj_dir ../src]]

read_vhdl [file join $src_dir irq_fsm.vhd]
read_vhdl [file join $src_dir axi_lite_cfg.vhd]
read_vhdl [file join $src_dir irq_top.vhd]
update_compile_order -fileset sources_1

# ==============================================================
# 2. Zynq Processing System
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

# UART1 + clock + GP0 + fabric interrupt (1 bit)
set_property -dict [list \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] $zynq

# ==============================================================
# 3. irq_top (our RTL module)
# ==============================================================
create_bd_cell -type module -reference irq_top irq_top_0

# ==============================================================
# 4. AXI Interconnect (PS GP0 -> 1 slave)
# ==============================================================
set ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $ic_gp0

# ==============================================================
# 5. Processor System Reset
# ==============================================================
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

# ==============================================================
# CONNECTIONS
# ==============================================================

# --- Clocks ---
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins irq_top_0/S_AXI_ACLK] \
    [get_bd_pins axi_ic_gp0/ACLK] \
    [get_bd_pins axi_ic_gp0/S00_ACLK] \
    [get_bd_pins axi_ic_gp0/M00_ACLK] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

# --- Resets ---
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins axi_ic_gp0/ARESETN] \
    [get_bd_pins axi_ic_gp0/S00_ARESETN] \
    [get_bd_pins axi_ic_gp0/M00_ARESETN]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins irq_top_0/S_AXI_ARESETN]

# --- AXI GP0: Zynq -> IC -> irq_top ---
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
    [get_bd_intf_pins axi_ic_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_gp0/M00_AXI] \
    [get_bd_intf_pins irq_top_0/S_AXI]

# --- Interrupt: irq_top -> Zynq PS ---
connect_bd_net [get_bd_pins irq_top_0/irq_out] \
    [get_bd_pins ps7/IRQ_F2P]

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

# Generate wrapper
make_wrapper -files [get_files irq_test_bd.bd] -top
set bd_dir [file dirname [get_files irq_test_bd.bd]]
set wrapper_file [file normalize "$bd_dir/hdl/irq_test_bd_wrapper.v"]
add_files -norecurse $wrapper_file
set_property top irq_test_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "OK: Block Design 'irq_test_bd' creado"
puts "  - Zynq PS con DDR, UART1, GP0"
puts "  - irq_top: AXI-Lite slave + IRQ"
puts "  - irq_out -> IRQ_F2P\[0\] (interrupt ID 61)"

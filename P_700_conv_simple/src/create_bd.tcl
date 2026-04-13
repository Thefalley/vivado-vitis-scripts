# create_bd.tcl — Block Design: Zynq PS + conv_simple_top
# Target: xc7z020clg400-1 (PYNQ-Z2) o xc7z020clg484-1 (ZedBoard)

set part [lindex $argv 0]
if {$part eq ""} { set part "xc7z020clg400-1" }

# Create block design
create_bd_design "conv_bd"

# ============================================================
# Zynq PS
# ============================================================
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} $ps

# Enable GP0 (for AXI-Lite to our IP)
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] $ps

# ============================================================
# Conv Simple Top (our IP)
# ============================================================
set conv [create_bd_cell -type module -reference conv_simple_top conv_top_0]

# ============================================================
# AXI Interconnect (1 master -> 1 slave)
# ============================================================
set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic]
set_property CONFIG.NUM_MI {1} $ic

# Connect PS GP0 -> interconnect -> conv_simple_top
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins conv_top_0/S_AXI]

# Clocks and resets
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

# Address map: conv_top_0 at 0x4000_0000, 32KB range
assign_bd_address -target_address_space ps7/Data \
    [get_bd_addr_segs conv_top_0/S_AXI/reg0] \
    -range 32K -offset 0x40000000

# Validate and save
validate_bd_design
save_bd_design

# Generate wrapper
set wrapper [make_bd_files -dir [get_property DIRECTORY [current_project]] \
    [get_files conv_bd.bd]]

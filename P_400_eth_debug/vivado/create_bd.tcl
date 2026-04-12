# create_bd.tcl - P_400 Ethernet Debug
# Creates Vivado project with Zynq PS for ZedBoard
# ALL PS configuration hardcoded (no dependency on board files)
#
# Run on server:
#   cd C:/Users/jce03/Desktop/claude/vivado-server/P_400_eth_debug
#   E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source vivado/create_bd.tcl

set script_dir [file dirname [file normalize [info script]]]
set base_dir   [file dirname $script_dir]
set proj_dir   $base_dir/vivado_proj

file delete -force $proj_dir

create_project p400_eth $proj_dir -part xc7z020clg484-1 -force
set_property target_language VHDL [current_project]

# ---- Block Design ----
create_bd_design "system"

# Zynq PS
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

# ============================================================
# FULL ZedBoard PS configuration (hardcoded, no board files)
# DDR3: Micron MT41J128M16HA-15E (256MB x 2 = 512MB)
# Ethernet: Marvell 88E1518 on MIO 16-27, MDIO 52-53
# UART1: MIO 48-49
# USB0: MIO 28-35
# SD0: MIO 40-47
# I2C0: MIO 50-51 (for HDMI ADV7511 config in future)
# ============================================================
set_property -dict [list \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE          {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE          {LVCMOS 1.8V} \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ    {33.333333} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ        {666.666667} \
    CONFIG.PCW_FCLK_CLK0_BUF                 {TRUE} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ      {100} \
    CONFIG.PCW_USE_M_AXI_GP0                  {0} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO             {MT41J128M16 HA-15E} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ           {533.333313} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE        {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH          {32 Bit} \
    CONFIG.PCW_UIPARAM_DDR_BL                 {8} \
    CONFIG.PCW_UIPARAM_DDR_T_FAW             {30.0} \
    CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN         {36.0} \
    CONFIG.PCW_UIPARAM_DDR_T_RC              {49.5} \
    CONFIG.PCW_UIPARAM_DDR_T_RCD             {7} \
    CONFIG.PCW_UIPARAM_DDR_T_RP              {7} \
    CONFIG.PCW_UIPARAM_DDR_CWL               {6} \
    CONFIG.PCW_UIPARAM_DDR_CL                {7} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0 {0.025} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1 {0.028} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2 {-0.009} \
    CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3 {-0.061} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0       {0.223} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1       {0.212} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2       {0.085} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3       {0.092} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL  {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE    {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE     {1} \
    CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF  {0} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE        {1} \
    CONFIG.PCW_ENET0_ENET0_IO                 {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE          {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO              {MIO 52 .. 53} \
    CONFIG.PCW_ENET0_RESET_ENABLE             {1} \
    CONFIG.PCW_ENET0_RESET_IO                 {MIO 9} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE        {1} \
    CONFIG.PCW_UART1_UART1_IO                 {MIO 48 .. 49} \
    CONFIG.PCW_USB0_PERIPHERAL_ENABLE         {1} \
    CONFIG.PCW_USB0_USB0_IO                   {MIO 28 .. 35} \
    CONFIG.PCW_USB0_RESET_ENABLE              {1} \
    CONFIG.PCW_USB0_RESET_IO                  {MIO 7} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE          {1} \
    CONFIG.PCW_SD0_SD0_IO                     {MIO 40 .. 45} \
    CONFIG.PCW_SD0_GRP_CD_ENABLE              {1} \
    CONFIG.PCW_SD0_GRP_CD_IO                  {MIO 47} \
    CONFIG.PCW_SD0_GRP_WP_ENABLE              {1} \
    CONFIG.PCW_SD0_GRP_WP_IO                  {MIO 46} \
    CONFIG.PCW_I2C0_PERIPHERAL_ENABLE         {1} \
    CONFIG.PCW_I2C0_I2C0_IO                   {MIO 50 .. 51} \
    CONFIG.PCW_I2C0_RESET_ENABLE              {0} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE           {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_IO               {MIO} \
    CONFIG.PCW_MIO_0_PULLUP                   {disabled} \
    CONFIG.PCW_MIO_0_IOTYPE                   {LVCMOS 3.3V} \
    CONFIG.PCW_MIO_0_DIRECTION                {inout} \
    CONFIG.PCW_MIO_0_SLEW                     {slow} \
] [get_bd_cells processing_system7_0]

# External interfaces
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "0"} \
    [get_bd_cells processing_system7_0]

validate_bd_design
save_bd_design

# Generate
generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [glob $proj_dir/*.gen/sources_1/bd/system/hdl/system_wrapper*]
update_compile_order -fileset sources_1

# Synth + Impl + Bitstream
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# Export XSA
write_hw_platform -fixed -include_bit -force \
    -file $base_dir/system.xsa

puts "============================================"
puts "  XSA exported: $base_dir/system.xsa"
puts "============================================"
close_project

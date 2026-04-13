
## -------------------------------------------------------------------------- ##

## Create the user environment variables.
set IPC_NAME test
set PRJ_NAME vivado-prj
set I_O_NAME led


set my_bd_name "bd_zynq_bridge_DM"
set XSA_file_name "XSA_test_bridge_DM_01"

## Change to the repository root directory.
cd ../../

## Remove the old Vivado project and XSA file.
file delete -force workspace/${PRJ_NAME}
file delete workspace/${IPC_NAME}-zcu102.xsa

## Create the Vivado project.
create_project -part xczu9eg-ffvb1156-2-e ${PRJ_NAME} workspace/${PRJ_NAME}
set_property board_part xilinx.com:zcu102:part0:3.4 [current_project]
set_property target_language VHDL [current_project]

## add src files
add_files -fileset sources_1 src/rtl/AXIS4_TO_AXI_BRIDGE/AXIS4_TO_AXI_BRIDGE.vhd
add_files -fileset sources_1 src/rtl/HSSkidBuf_Scheduler/HSSkidBuf_Scheduler_dest.vhd
add_files -fileset sources_1 src/rtl/tester_axis4_to_axi_bridge/tester_axis4_to_axi_bridge.vhd
add_files -fileset sources_1 src/rtl/dataColector_ROI_interpreter/dataColector_ROI_interpreter.vhd
add_files -fileset sources_1 src/rtl/dataMover_CMD_gen/axis_cmd_gen_s2mm.vhd
add_files -fileset sources_1 src/rtl/TOP_AXIS_X4_TO_AXI_DM/TOP_AXIS4_TO_AXI_BRIDGE_DM.vhd
add_files -fileset sources_1 src/rtl/TogglerINT/interrupt_toggler.v
add_files -fileset sources_1 src/rtl/HsSkidBuf/HsSkidBuf_dest.vhd
add_files -fileset sources_1 src/rtl/tester_axis4_to_axi_bridge/S00_AXI_32_reg.vhd
add_files -fileset sources_1 src/rtl/tester_axis4_to_axi_bridge/axi_lite_OffSet.vhd

## FILE TYPE VHDL 2008 config file
## set_property FILE_TYPE {VHDL 2008} [get_files src/rtl/HSSkidBuf_Scheduler/HSSkidBuf_Scheduler_dest.vhd]
## set_property FILE_TYPE {VHDL 2008} [get_files src/rtl/HsSkidBuf/HsSkidBuf_dest.vhd]

## Create DataMover IP
create_ip -name axi_datamover -vendor xilinx.com -library ip -version 5.1 -module_name axi_datamover_0
## Configure DataMover IP
set_property -dict [list \
    CONFIG.c_enable_mm2s {0} \
  CONFIG.c_s2mm_btt_used {23} \
  CONFIG.c_s2mm_burst_size {256} \
] [get_ips axi_datamover_0]
generate_target all [get_files /project/pmendoza/axis-x4-to-axi-dm/workspace/vivado-prj/vivado-prj.srcs/sources_1/ip/axi_datamover_0/axi_datamover_0.xci]
update_compile_order -fileset sources_1

## Add top file
set_property top top_axis4_to_axi_bridge_DM [current_fileset]

## Synthesys comand 24 jobs
launch_runs synth_1 -jobs 24


######### Create IP axis_x4_to_axi_DM ################

set ip_work_path "../../workspace"
set dirIP "ipBEGI"
set NAME-ip-axis-x4-to-axi-dm "ip-axis-x4-to-axi-dm"
set NAME-ip-tester-dm "ip-tester-dm"

set vendor_name "ikerlan.es"
## 
file delete -force ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm}

## Generate IPBEGI dir tree
file mkdir ${ip_work_path}/${dirIP}
file mkdir ${ip_work_path}/${dirIP}/${NAME-ip-axis-x4-to-axi-dm}
file mkdir ${ip_work_path}/${dirIP}/${NAME-ip-tester-dm}

## 
ipx::package_project -root_dir ${ip_work_path}/${dirIP}/${NAME-ip-axis-x4-to-axi-dm} -vendor ${vendor_name} -library ${NAME-ip-axis-x4-to-axi-dm} -taxonomy ${NAME-ip-axis-x4-to-axi-dm} -import_files -set_current false
ipx::unload_core ${ip_work_path}/${dirIP}/${NAME-ip-axis-x4-to-axi-dm}/component.xml

ipx::open_ipxact_file ${ip_work_path}/${dirIP}/${NAME-ip-axis-x4-to-axi-dm}/component.xml

## Identification name
set_property name axis_x4_to_axi_DM [ipx::current_core]
set_property display_name axis_x4_to_axi_DM [ipx::current_core]
set_property description axis_x4_to_axi_DM [ipx::current_core]
set_property version 0.1.0 [ipx::current_core]
set_property supported_families {zynquplus Production} [ipx::current_core] 

##Success

## No parameter configurable
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "BYTE_WIDTH" -component [ipx::current_core]]
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "CMD_WIDTH" -component [ipx::current_core]]
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "CNT_MAX" -component [ipx::current_core]]
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "DEST_WIDTH" -component [ipx::current_core]]
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "HS_TDATA_WIDTH" -component [ipx::current_core]]
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "INTERFACE_NUM" -component [ipx::current_core]]
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "LENGTHE2F_WIDTH" -component [ipx::current_core]]
ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "STS_DATA_WIDTH" -component [ipx::current_core]]

ipx::merge_project_changes hdl_parameters [ipx::current_core]

## Close packet
set_property core_revision 2 [ipx::current_core]
ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]
set_property  ip_repo_paths  ${ip_work_path}/${dirIP}/${NAME-ip-axis-x4-to-axi-dm} [current_project]
update_ip_catalog




## set ip_work_path "../../workspace"
## set dirIP "ipBEGI"
## set NAME-ip-axis-x4-to-axi-dm "ip-axis-x4-to-axi-dm"
## set NAME-ip-tester-dm "ip-tester-dm"
## 
## set vendor_name "ikerlan.es"
## ## 
## file delete -force ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm}
## 
## ## Generate IPBEGI dir tree
## file mkdir ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm}
## file mkdir ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm}/${NAME-ip-axis-x4-to-axi-dm}
## file mkdir ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm}/${NAME-ip-tester-dm}
## 
## ## 
## ipx::package_project -root_dir ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm} -vendor ${vendor_name} -library ${NAME-ip-axis-x4-to-axi-dm} -taxonomy ${NAME-ip-axis-x4-to-axi-dm} -import_files -set_current false
## ipx::unload_core ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm}/component.xml
## 
## ipx::open_ipxact_file ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm}/component.xml
## 
## ## Identification name
## set_property name axis_x4_to_axi_DM [ipx::current_core]
## set_property display_name axis_x4_to_axi_DM [ipx::current_core]
## set_property description axis_x4_to_axi_DM [ipx::current_core]
## set_property version 0.1.0 [ipx::current_core]
## set_property supported_families {zynquplus Production} [ipx::current_core] 
## 
## ##Success
## 
## ## No parameter configurable
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "BYTE_WIDTH" -component [ipx::current_core]]
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "CMD_WIDTH" -component [ipx::current_core]]
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "CNT_MAX" -component [ipx::current_core]]
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "DEST_WIDTH" -component [ipx::current_core]]
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "HS_TDATA_WIDTH" -component [ipx::current_core]]
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "INTERFACE_NUM" -component [ipx::current_core]]
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "LENGTHE2F_WIDTH" -component [ipx::current_core]]
## ipgui::remove_param -component [ipx::current_core] [ipgui::get_guiparamspec -name "STS_DATA_WIDTH" -component [ipx::current_core]]
## 
## ipx::merge_project_changes hdl_parameters [ipx::current_core]
## 
## ## Close packet
## set_property core_revision 2 [ipx::current_core]
## ipx::create_xgui_files [ipx::current_core]
## ipx::update_checksums [ipx::current_core]
## ipx::check_integrity [ipx::current_core]
## ipx::save_core [ipx::current_core]
## set_property  ip_repo_paths  ${ip_work_path}/${NAME-ip-axis-x4-to-axi-dm} [current_project]
## update_ip_catalog






######### END Create IP ################


## Create block design ############################################################

set my_bd_name "bd_zynq_bridge_DM_0"
create_bd_design "${my_bd_name}"

startgroup
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0
endgroup
set_property CONFIG.PSU__USE__S_AXI_GP2 {1} [get_bd_cells zynq_ultra_ps_e_0]
startgroup
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
endgroup
set_property -dict [list \
  CONFIG.c_include_mm2s {0} \
  CONFIG.c_s2mm_burst_size {256} \
] [get_bd_cells axi_dma_0]

## Generate auto conection
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1" }  [get_bd_cells zynq_ultra_ps_e_0]
startgroup
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave {/axi_dma_0/S_AXI_LITE} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}}  [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/axi_dma_0/M_AXI_S2MM} Slave {/zynq_ultra_ps_e_0/S_AXI_HP0_FPD} ddr_seg {Auto} intc_ip {New AXI SmartConnect} master_apm {0}}  [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
endgroup

## Borrar DMA
delete_bd_objs [get_bd_intf_nets ps8_0_axi_periph_M00_AXI] [get_bd_intf_nets axi_dma_0_M_AXI_S2MM] [get_bd_cells axi_dma_0]

## Añadir ip-axis-x4-to-axi-dm
startgroup
create_bd_cell -type ip -vlnv ikerlan.es:ip-axis-x4-to-axi-dm:axis_x4_to_axi_DM:0.1.0 axis_x4_to_axi_DM_0
endgroup

## Reset
connect_bd_net [get_bd_pins axis_x4_to_axi_DM_0/n_rst] [get_bd_pins rst_ps8_0_99M/peripheral_aresetn]

## DMA tester INPUT DATA
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
  CONFIG.c_include_mm2s {0} \
  CONFIG.c_include_sg {0} \
  CONFIG.c_s2mm_burst_size {256} \
] [get_bd_cells axi_dma_0]
set_property location {1 164 335} [get_bd_cells axi_dma_0]
copy_bd_objs /  [get_bd_cells {axi_dma_0}]
copy_bd_objs /  [get_bd_cells {axi_dma_1}]
copy_bd_objs /  [get_bd_cells {axi_dma_2}]
set_property -dict [list \
  CONFIG.c_include_mm2s {1} \
  CONFIG.c_include_s2mm {0} \
] [get_bd_cells axi_dma_0]
delete_bd_objs [get_bd_cells axi_dma_3]
delete_bd_objs [get_bd_cells axi_dma_2]
delete_bd_objs [get_bd_cells axi_dma_1]
set_property CONFIG.c_mm2s_burst_size {256} [get_bd_cells axi_dma_0]
set_property location {2 598 434} [get_bd_cells axis_x4_to_axi_DM_0]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins axis_x4_to_axi_DM_0/s_axis_0]
copy_bd_objs /  [get_bd_cells {axi_dma_0}]
copy_bd_objs /  [get_bd_cells {axi_dma_0}]
set_property location {1 142 587} [get_bd_cells axi_dma_2]
set_property location {1 140 474} [get_bd_cells axi_dma_1]
copy_bd_objs /  [get_bd_cells {axi_dma_2}]
set_property location {1 182 779} [get_bd_cells axi_dma_3]
connect_bd_intf_net [get_bd_intf_pins axi_dma_1/M_AXIS_MM2S] [get_bd_intf_pins axis_x4_to_axi_DM_0/s_axis_1]
connect_bd_intf_net [get_bd_intf_pins axi_dma_2/M_AXIS_MM2S] [get_bd_intf_pins axis_x4_to_axi_DM_0/s_axis_2]
connect_bd_intf_net [get_bd_intf_pins axis_x4_to_axi_DM_0/s_axis_3] [get_bd_intf_pins axi_dma_3/M_AXIS_MM2S]


## 4 conections Interconect AXI-LITE
set_property CONFIG.NUM_MI {4} [get_bd_cells ps8_0_axi_periph]
## Conecto all axi-lite interface
connect_bd_intf_net -boundary_type upper [get_bd_intf_pins ps8_0_axi_periph/M00_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net -boundary_type upper [get_bd_intf_pins ps8_0_axi_periph/M01_AXI] [get_bd_intf_pins axi_dma_1/S_AXI_LITE]
connect_bd_intf_net -boundary_type upper [get_bd_intf_pins ps8_0_axi_periph/M02_AXI] [get_bd_intf_pins axi_dma_2/S_AXI_LITE]
connect_bd_intf_net -boundary_type upper [get_bd_intf_pins ps8_0_axi_periph/M03_AXI] [get_bd_intf_pins axi_dma_3/S_AXI_LITE]

## HP0 interface
set_property CONFIG.NUM_SI {5} [get_bd_cells axi_smc]
connect_bd_intf_net [get_bd_intf_pins axi_smc/S00_AXI] [get_bd_intf_pins axi_dma_0/M_AXI_MM2S]
connect_bd_intf_net [get_bd_intf_pins axi_smc/S01_AXI] [get_bd_intf_pins axi_dma_1/M_AXI_MM2S]
connect_bd_intf_net [get_bd_intf_pins axi_smc/S02_AXI] [get_bd_intf_pins axi_dma_2/M_AXI_MM2S]
connect_bd_intf_net [get_bd_intf_pins axi_smc/S03_AXI] [get_bd_intf_pins axi_dma_3/M_AXI_MM2S]
connect_bd_intf_net [get_bd_intf_pins axis_x4_to_axi_DM_0/m_axi_s2mm] [get_bd_intf_pins axi_smc/S04_AXI]

## Interrupt conect (CONCAT)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property CONFIG.NUM_PORTS {7} [get_bd_cells xlconcat_0]
connect_bd_net [get_bd_pins xlconcat_0/In0] [get_bd_pins axis_x4_to_axi_DM_0/INT_A]
connect_bd_net [get_bd_pins xlconcat_0/In1] [get_bd_pins axis_x4_to_axi_DM_0/INT_B]
connect_bd_net [get_bd_pins xlconcat_0/In2] [get_bd_pins axis_x4_to_axi_DM_0/s2mm_err]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins xlconcat_0/In3]
connect_bd_net [get_bd_pins axi_dma_1/mm2s_introut] [get_bd_pins xlconcat_0/In4]
connect_bd_net [get_bd_pins axi_dma_2/mm2s_introut] [get_bd_pins xlconcat_0/In5]
connect_bd_net [get_bd_pins axi_dma_3/mm2s_introut] [get_bd_pins xlconcat_0/In6]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

## CLK conections
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_0/m_axi_mm2s_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_0/s_axi_lite_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_1/m_axi_mm2s_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_1/s_axi_lite_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_2/m_axi_mm2s_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_2/s_axi_lite_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_3/m_axi_mm2s_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_dma_3/s_axi_lite_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Master {/zynq_ultra_ps_e_0/M_AXI_HPM1_FPD} Slave {/axi_dma_0/S_AXI_LITE} ddr_seg {Auto} intc_ip {/ps8_0_axi_periph} master_apm {0}}  [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM1_FPD]

## OffSet AXI-Lite
create_bd_cell -type module -reference axi_lite_OffSet axi_lite_OffSet_0
set_property CONFIG.NUM_MI {5} [get_bd_cells ps8_0_axi_periph]
connect_bd_intf_net -boundary_type upper [get_bd_intf_pins ps8_0_axi_periph/M04_AXI] [get_bd_intf_pins axi_lite_OffSet_0/S_AXI]
connect_bd_net [get_bd_pins axi_lite_OffSet_0/base_address_A] [get_bd_pins axis_x4_to_axi_DM_0/base_address_A]
connect_bd_net [get_bd_pins axis_x4_to_axi_DM_0/base_address_B] [get_bd_pins axi_lite_OffSet_0/base_address_B]
## apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Freq {100} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins axi_lite_OffSet_0/S_AXI_ACLK]
delete_bd_objs [get_bd_intf_nets ps8_0_axi_periph_M04_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_slave {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Clk_xbar {/zynq_ultra_ps_e_0/pl_clk0 (99 MHz)} Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave {/axi_lite_OffSet_0/S_AXI} ddr_seg {Auto} intc_ip {/ps8_0_axi_periph} master_apm {0}}  [get_bd_intf_pins axi_lite_OffSet_0/S_AXI]


## ILA
set_property HDL_ATTRIBUTE.DEBUG true [get_bd_intf_nets {axi_dma_0_M_AXIS_MM2S}]
set_property HDL_ATTRIBUTE.DEBUG true [get_bd_intf_nets {axi_dma_1_M_AXIS_MM2S}]
set_property HDL_ATTRIBUTE.DEBUG true [get_bd_intf_nets {axi_dma_2_M_AXIS_MM2S}]
set_property HDL_ATTRIBUTE.DEBUG true [get_bd_intf_nets {axi_dma_3_M_AXIS_MM2S}]
set_property HDL_ATTRIBUTE.DEBUG true [get_bd_intf_nets {axis_x4_to_axi_DM_0_m_axi_s2mm}]
startgroup
apply_bd_automation -rule xilinx.com:bd_rule:debug -dict [list \
 [get_bd_intf_nets axi_dma_0_M_AXIS_MM2S] {AXIS_SIGNALS "Data and Trigger" CLK_SRC "/zynq_ultra_ps_e_0/pl_clk0" SYSTEM_ILA "Auto" APC_EN "0" } \
 [get_bd_intf_nets axi_dma_1_M_AXIS_MM2S] {AXIS_SIGNALS "Data and Trigger" CLK_SRC "/zynq_ultra_ps_e_0/pl_clk0" SYSTEM_ILA "Auto" APC_EN "0" } \
 [get_bd_intf_nets axi_dma_2_M_AXIS_MM2S] {AXIS_SIGNALS "Data and Trigger" CLK_SRC "/zynq_ultra_ps_e_0/pl_clk0" SYSTEM_ILA "Auto" APC_EN "0" } \
 [get_bd_intf_nets axi_dma_3_M_AXIS_MM2S] {AXIS_SIGNALS "Data and Trigger" CLK_SRC "/zynq_ultra_ps_e_0/pl_clk0" SYSTEM_ILA "Auto" APC_EN "0" } \
 [get_bd_intf_nets axis_x4_to_axi_DM_0_m_axi_s2mm] {AXI_R_ADDRESS "None" AXI_R_DATA "None" AXI_W_ADDRESS "Data and Trigger" AXI_W_DATA "Data and Trigger" AXI_W_RESPONSE "Data and Trigger" CLK_SRC "/zynq_ultra_ps_e_0/pl_clk0" SYSTEM_ILA "Auto" APC_EN "0" } \
]
endgroup
## Configure ILA MIX and 7 PROBE
startgroup
set_property -dict [list \
  CONFIG.C_DATA_DEPTH {16384} \
  CONFIG.C_MON_TYPE {MIX} \
  CONFIG.C_NUM_OF_PROBES {7} \
] [get_bd_cells system_ila_0]
endgroup

connect_bd_net [get_bd_pins axis_x4_to_axi_DM_0/INT_A] [get_bd_pins system_ila_0/probe0]
connect_bd_net [get_bd_pins axis_x4_to_axi_DM_0/INT_B] [get_bd_pins system_ila_0/probe1]
connect_bd_net [get_bd_pins axis_x4_to_axi_DM_0/s2mm_err] [get_bd_pins system_ila_0/probe2]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins system_ila_0/probe3]
connect_bd_net [get_bd_pins axi_dma_1/mm2s_introut] [get_bd_pins system_ila_0/probe4]
connect_bd_net [get_bd_pins axi_dma_2/mm2s_introut] [get_bd_pins system_ila_0/probe5]
connect_bd_net [get_bd_pins axi_dma_3/mm2s_introut] [get_bd_pins system_ila_0/probe6]


## Save disign and validate
validate_bd_design
save_bd_design

## Crear wrapper
close_bd_design [get_bd_designs bd_zynq_bridge_DM_0]
make_wrapper -files [get_files workspace/${PRJ_NAME}/${PRJ_NAME}.srcs/sources_1/bd/bd_zynq_bridge_DM_0/bd_zynq_bridge_DM_0.bd] -top
add_files -norecurse workspace/${PRJ_NAME}/${PRJ_NAME}.gen/sources_1/bd/bd_zynq_bridge_DM_0/hdl/bd_zynq_bridge_DM_0_wrapper.vhd

## TOP project 
set_property top bd_zynq_bridge_DM_0_wrapper [current_fileset]
update_compile_order -fileset sources_1

## Create bitstream
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 24

## Write XSA FILE
## puts [pwd]
write_hw_platform -fixed -include_bit -force -file workspace/${PRJ_NAME}/${XSA_file_name}.xsa


## ## ADD IP              #######################
## 
#### Create block design  END ###################
## 
## 
## 
## 
## 
## 
## ## add sim files
## pwd
## 
## 
## add_files -fileset sim_1 src/sim/tb_lib_files/tb_AXI_Stream_Random_Slave.vhd
## add_files -fileset sim_1 src/sim/tb_lib_files/tb_AXI_Stream_Master_meta.vhd
## add_files -fileset sim_1 src/sim/tb_lib_files/AXI_Stream_Master_meta.vhd
## add_files -fileset sim_1 src/sim/tb_lib_files/AXI_Stream_Random_Master_meta.vhd
## add_files -fileset sim_1 src/sim/tb_lib_files/axi_slave.vhd
## add_files -fileset sim_1 src/sim/tb_lib_files/tb_AXI_Stream_Random_Master.vhd
## add_files -fileset sim_1 src/sim/tb_lib_files/AXI_Stream_Random_Slave.vhd
## add_files -fileset sim_1 src/sim/TogglerINT/tb_interrupt_toggler.sv
## add_files -fileset sim_1 src/sim/AXIS4_TO_AXI_BRIDGE/TB_TOP_AXIS4_TO_AXI_BRIDGE.vhd
## add_files -fileset sim_1 src/sim/HSSkidBuf_Scheduler/tb_HsSkidBuf_Scheduler_dest.vhd
## add_files -fileset sim_1 src/sim/dataMover_CMD_gen/tb_axis_cmd_gen_s2mm.vhd
## add_files -fileset sim_1 src/sim/dataColector_ROI_interpreter/tb_dataColector_ROI_interpreter.vhd
## add_files -fileset sim_1 src/sim/tester_axis4_to_axi_bridge/tb_tester_axis4_to_axi_bridge.vhd







## -------------------------------------------------------------------------- ##

## End writing the Vivado project generation script.
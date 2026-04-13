# Variables del IP
set path       "ip/axis_x4_to_axi_dm"
set vendor     "ikerlan.es"
set library    "ip-axis-x4-to-axi-dm"
set name       "axis_x4_to_axi_dm"
set version    "0.1.0"
set taxonomy   "{/UserIP}"
set top        "top_axis4_to_axi_bridge_DM"

# Crear directorio del IP si no existe
file mkdir -p $path

# Agregar todos los archivos fuente necesarios
add_files src/rtl/TogglerINT/interrupt_toggler.v 

read_vhdl src/rtl/TOP_AXIS_X4_TO_AXI_DM/TOP_AXIS4_TO_AXI_BRIDGE_DM.vhd
read_vhdl src/rtl/AXIS4_TO_AXI_BRIDGE/AXIS4_TO_AXI_BRIDGE.vhd
read_vhdl src/rtl/dataMover_CMD_gen/axis_cmd_gen_s2mm.vhd
read_vhdl src/rtl/dataColector_ROI_interpreter/dataColector_ROI_interpreter.vhd
read_vhdl src/rtl/HSSkidBuf_Scheduler/HSSkidBuf_Scheduler_dest.vhd
read_vhdl src/rtl/HsSkidBuf/HsSkidBuf_dest.vhd

update_compile_order

create_ip -name axi_datamover -vendor xilinx.com -library ip -version 5.1 -module_name axi_datamover_0 -dir $path -force
## Configure DataMover IP
set_property -dict [list \
    CONFIG.c_enable_mm2s {0} \
  CONFIG.c_s2mm_btt_used {23} \
  CONFIG.c_s2mm_burst_size {256} \
] [get_ips axi_datamover_0]

# Establecer el top
set_property top $top [current_fileset]


# start_gui

# Empaquetar el proyecto IP
ipx::package_project -root_dir $path -vendor $vendor -library $library -taxonomy $taxonomy -force -import_files

# Establecer metadatos del IP
set_property version $version [ipx::current_core]
set_property display_name $name [ipx::current_core]
set_property description $name [ipx::current_core]
set_property vendor $vendor [ipx::current_core]
set_property name $name [ipx::current_core]
set_property library $library [ipx::current_core]
set_property taxonomy $taxonomy [ipx::current_core]
set_property supported_families {zynq Production artixuplus Production kintexuplus Production virtexuplus Production virtexuplusHBM Production qzynq Production zynquplus Production virtexuplus58g Production azynq Production zynq Production} [ipx::current_core]

# Generar y guardar IP
ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]

## vivado -mode batch -source package_ip_axis_x4_to_axi_d.tcl
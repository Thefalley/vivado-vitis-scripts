# run_sim.tcl - Simular las 3 variantes de multiplicador 32x30
# Uso: vivado -mode batch -source sim/run_sim.tcl

set src_dir [file normalize [file join [file dirname [info script]] "../src"]]
set sim_dir [file normalize [file join [file dirname [info script]] "."]]

# Crear proyecto de simulacion en memoria
create_project sim_proj -in_memory -part xc7z020clg484-1

# Anadir fuentes
add_files [glob $src_dir/*.vhd]
add_files -fileset sim_1 $sim_dir/mult_tb.vhd

# Configurar simulacion
set_property top mult_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Lanzar simulacion
launch_simulation -mode behavioral
run 5us

# Cerrar
close_sim
close_project

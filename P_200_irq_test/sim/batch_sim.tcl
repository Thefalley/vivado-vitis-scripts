# batch_sim.tcl - P_200 IRQ FSM: batch simulation on server
#
# Usage (on server):
#   cd C:/Users/jce03/Desktop/claude/vivado-server/P_200_irq_test
#   E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source sim/batch_sim.tcl
#
# Creates project, compiles, simulates, saves WDB for later GUI viewing.

set base_dir [file dirname [file dirname [file normalize [info script]]]]
set proj_dir $base_dir/sim_proj
set src_dir  $base_dir/src
set sim_dir  $base_dir/sim

file delete -force $proj_dir

create_project irq_sim $proj_dir -part xc7z020clg484-1 -force
set_property target_language VHDL [current_project]

add_files -norecurse [list \
    $src_dir/irq_fsm.vhd \
    $src_dir/axi_lite_cfg.vhd \
    $src_dir/irq_top.vhd \
]

add_files -fileset sim_1 -norecurse $sim_dir/tb_irq_top.vhd
set_property top tb_irq_top [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Run behavioral simulation in batch mode
launch_simulation -mode behavioral
run 2000 ns

puts "=== SIMULATION COMPLETE ==="
puts "WDB file: [current_sim]/tb_irq_top.wdb"

close_sim
close_project

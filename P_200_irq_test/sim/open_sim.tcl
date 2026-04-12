# open_sim.tcl - P_200 IRQ FSM: behavioral simulation with waveform GUI
#
# Uso:
#   vivado -source P_200_irq_test/sim/open_sim.tcl
#
# Crea un proyecto temporal, compila, lanza simulacion y muestra ondas.

set proj_dir C:/project/vivado/P_200_irq_test/sim_proj
set src_dir  C:/project/vivado/P_200_irq_test/src
set sim_dir  C:/project/vivado/P_200_irq_test/sim

file delete -force $proj_dir

create_project irq_sim $proj_dir -part xc7z020clg484-1 -force
set_property target_language VHDL [current_project]

# RTL sources
add_files -norecurse [list \
    $src_dir/irq_fsm.vhd \
    $src_dir/axi_lite_cfg.vhd \
    $src_dir/irq_top.vhd \
]

# Testbench
add_files -fileset sim_1 -norecurse $sim_dir/tb_irq_top.vhd
set_property top tb_irq_top [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Launch behavioral simulation (opens xsim inside Vivado GUI)
launch_simulation

# ---- Waveform setup ----

add_wave -divider "Clk / Rst"
add_wave /tb_irq_top/clk
add_wave /tb_irq_top/rst_n

add_wave -divider "INTERRUPT"
add_wave /tb_irq_top/irq_out

add_wave -divider "FSM Internals"
add_wave /tb_irq_top/DUT/u_fsm/state
add_wave -radix unsigned /tb_irq_top/DUT/u_fsm/counter
add_wave -radix unsigned /tb_irq_top/DUT/u_fsm/irq_cnt
add_wave /tb_irq_top/DUT/u_fsm/irq_reg

add_wave -divider "Config (AXI regs)"
add_wave -radix hex /tb_irq_top/DUT/ctrl_s
add_wave -radix unsigned /tb_irq_top/DUT/threshold_s
add_wave -radix unsigned /tb_irq_top/DUT/condition_s

add_wave -divider "Status (read-back)"
add_wave -radix hex /tb_irq_top/DUT/status_s
add_wave -radix unsigned /tb_irq_top/DUT/count_s
add_wave -radix unsigned /tb_irq_top/DUT/irq_count_s

add_wave -divider "AXI Write Ch"
add_wave -radix hex /tb_irq_top/awaddr
add_wave /tb_irq_top/awvalid
add_wave /tb_irq_top/awready
add_wave -radix hex /tb_irq_top/wdata
add_wave /tb_irq_top/wvalid
add_wave /tb_irq_top/wready
add_wave /tb_irq_top/bvalid
add_wave /tb_irq_top/bready

add_wave -divider "AXI Read Ch"
add_wave -radix hex /tb_irq_top/araddr
add_wave /tb_irq_top/arvalid
add_wave /tb_irq_top/arready
add_wave -radix hex /tb_irq_top/rdata
add_wave /tb_irq_top/rvalid
add_wave /tb_irq_top/rready

# Run the full simulation
run 2000 ns

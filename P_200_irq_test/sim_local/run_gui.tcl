## TCL commands for xsim GUI (standalone mode)
## Launch: xsim irq_sim -gui -tclbatch run_gui.tcl

# Waveform setup
add_wave_divider "Clk / Rst"
add_wave /tb_irq_top/clk
add_wave /tb_irq_top/rst_n

add_wave_divider "INTERRUPT"
add_wave /tb_irq_top/irq_out

add_wave_divider "FSM Internals"
add_wave /tb_irq_top/DUT/u_fsm/state
add_wave -radix unsigned /tb_irq_top/DUT/u_fsm/counter
add_wave -radix unsigned /tb_irq_top/DUT/u_fsm/irq_cnt
add_wave /tb_irq_top/DUT/u_fsm/irq_reg

add_wave_divider "Config (AXI regs)"
add_wave -radix hex /tb_irq_top/DUT/ctrl_s
add_wave -radix unsigned /tb_irq_top/DUT/threshold_s
add_wave -radix unsigned /tb_irq_top/DUT/condition_s

add_wave_divider "Status (read-back)"
add_wave -radix hex /tb_irq_top/DUT/status_s
add_wave -radix unsigned /tb_irq_top/DUT/count_s
add_wave -radix unsigned /tb_irq_top/DUT/irq_count_s

add_wave_divider "AXI Write Ch"
add_wave -radix hex /tb_irq_top/awaddr
add_wave /tb_irq_top/awvalid
add_wave /tb_irq_top/awready
add_wave -radix hex /tb_irq_top/wdata
add_wave /tb_irq_top/wvalid
add_wave /tb_irq_top/wready
add_wave /tb_irq_top/bvalid
add_wave /tb_irq_top/bready

add_wave_divider "AXI Read Ch"
add_wave -radix hex /tb_irq_top/araddr
add_wave /tb_irq_top/arvalid
add_wave /tb_irq_top/arready
add_wave -radix hex /tb_irq_top/rdata
add_wave /tb_irq_top/rvalid
add_wave /tb_irq_top/rready

# Run simulation
run 2000 ns

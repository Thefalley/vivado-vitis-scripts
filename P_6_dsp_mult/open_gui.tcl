# open_gui.tcl - Sintetiza, implementa y abre GUI con timing analysis
# Uso: vivado -source P_6_dsp_mult/open_gui.tcl

set src_dir "C:/project/vivado/P_6_dsp_mult/src"
set part "xc7z020clg484-1"
set top "mult_4dsp_tree"
set clk_period 10.0

# Leer fuentes
foreach f [glob $src_dir/*.vhd] {
    read_vhdl $f
}

# Sintesis
synth_design -top $top -part $part

# Constraints
create_clock -period $clk_period -name clk [get_ports clk]
set_input_delay  -clock clk 0.5 [get_ports -filter {NAME != clk}]
set_output_delay -clock clk 0.5 [get_ports -filter {DIRECTION == OUT}]

# Implementacion
opt_design
place_design
route_design

# Reports
report_timing_summary -name timing_summary
report_utilization -name utilization

# Checkpoint para poder reabrir
write_checkpoint -force C:/project/vivado/P_6_dsp_mult/build_sweep/mult_4dsp_tree/routed.dcp

puts "=== DESIGN ROUTED - GUI OPEN ==="
puts "=== Revisa la ventana 'Timing Summary' ==="

# Mantener GUI abierta
start_gui

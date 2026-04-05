# build_dcp.tcl - Genera checkpoint para abrir en GUI
set src_dir "C:/project/vivado/P_6_dsp_mult/src"
set out_dir "C:/project/vivado/P_6_dsp_mult/build_sweep/mult_4dsp_tree"
set part "xc7z020clg484-1"
set top "mult_4dsp_tree"

foreach f [glob $src_dir/*.vhd] { read_vhdl $f }

synth_design -top $top -part $part
create_clock -period 10.0 -name clk [get_ports clk]
set_input_delay  -clock clk 0.5 [get_ports -filter {NAME != clk}]
set_output_delay -clock clk 0.5 [get_ports -filter {DIRECTION == OUT}]

opt_design
place_design
route_design

write_checkpoint -force $out_dir/routed.dcp
report_timing_summary -file $out_dir/timing_100mhz.rpt
report_utilization -file $out_dir/util_100mhz.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "WNS=$wns"

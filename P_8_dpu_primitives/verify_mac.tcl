set src_dir "C:/project/vivado/P_8_dpu_primitives/src"
set out_dir "C:/project/vivado/P_8_dpu_primitives/results"
foreach f [glob $src_dir/*.vhd] { read_vhdl $f }
synth_design -top mac_unit -part xc7z020clg484-1
create_clock -period 10.0 -name clk [get_ports clk]
opt_design
place_design
route_design
report_utilization -file "$out_dir/mac_unit_util_v2.rpt"
report_timing_summary -file "$out_dir/mac_unit_timing_v2.rpt"
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set fp [open "$out_dir/mac_unit_result_v2.txt" w]
puts $fp "WNS=$wns"
close $fp
puts "mac_unit WNS=$wns"

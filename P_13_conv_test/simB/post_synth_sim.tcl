# Post-synthesis functional simulation of conv_test_wrapper OOC
# Opens the synthesized checkpoint, writes out a VHDL netlist, then
# we can simulate it with xsim alongside the TB.

set dcp "C:/project/vivado/P_13_conv_test/build/zynq_conv.runs/zynq_conv_bd_conv_test_wrapper_0_0_synth_1/zynq_conv_bd_conv_test_wrapper_0_0.dcp"
set out_dir "C:/project/vivado/P_13_conv_test/simB/post_synth"

file mkdir $out_dir

open_checkpoint $dcp

# Write VHDL netlist (functional, no timing)
write_vhdl -force -mode funcsim "$out_dir/conv_test_wrapper_funcsim.vhd"

puts "OK: netlist written to $out_dir/conv_test_wrapper_funcsim.vhd"

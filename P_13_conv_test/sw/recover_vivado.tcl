# Try to recover via Vivado hardware manager
open_hw_manager
connect_hw_server
after 3000
open_hw_target
after 2000
set devices [get_hw_devices]
puts "Devices: $devices"
# Try to program the xc7z020 directly
set dev [get_hw_devices xc7z020_1]
set_property PROGRAM.FILE {C:/project/vivado/P_13_conv_test/build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit} $dev
program_hw_devices $dev
after 3000
puts "Programmed!"
close_hw_manager

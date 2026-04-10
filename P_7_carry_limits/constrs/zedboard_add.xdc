# Clock 100 MHz
set_property PACKAGE_PIN Y9 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name clk [get_ports clk]

# Reset - BTN Center
set_property PACKAGE_PIN P16 [get_ports rst]
set_property IOSTANDARD LVCMOS18 [get_ports rst]

# Data input - 8 switches
set_property PACKAGE_PIN F22 [get_ports {data_in[0]}]
set_property PACKAGE_PIN G22 [get_ports {data_in[1]}]
set_property PACKAGE_PIN H22 [get_ports {data_in[2]}]
set_property PACKAGE_PIN F21 [get_ports {data_in[3]}]
set_property PACKAGE_PIN H19 [get_ports {data_in[4]}]
set_property PACKAGE_PIN H18 [get_ports {data_in[5]}]
set_property PACKAGE_PIN H17 [get_ports {data_in[6]}]
set_property PACKAGE_PIN M15 [get_ports {data_in[7]}]
set_property IOSTANDARD LVCMOS18 [get_ports {data_in[*]}]

# Control buttons
set_property PACKAGE_PIN N15 [get_ports load]
set_property IOSTANDARD LVCMOS18 [get_ports load]
set_property PACKAGE_PIN R18 [get_ports go]
set_property IOSTANDARD LVCMOS18 [get_ports go]
set_property PACKAGE_PIN T18 [get_ports sel]
set_property IOSTANDARD LVCMOS18 [get_ports sel]

# Result - 8 LEDs
set_property PACKAGE_PIN T22 [get_ports {result_out[0]}]
set_property PACKAGE_PIN T21 [get_ports {result_out[1]}]
set_property PACKAGE_PIN U22 [get_ports {result_out[2]}]
set_property PACKAGE_PIN U21 [get_ports {result_out[3]}]
set_property PACKAGE_PIN V22 [get_ports {result_out[4]}]
set_property PACKAGE_PIN W22 [get_ports {result_out[5]}]
set_property PACKAGE_PIN U19 [get_ports {result_out[6]}]
set_property PACKAGE_PIN U14 [get_ports {result_out[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {result_out[*]}]

# Done - PMOD JA1 pin 1
set_property PACKAGE_PIN Y11 [get_ports done]
set_property IOSTANDARD LVCMOS33 [get_ports done]

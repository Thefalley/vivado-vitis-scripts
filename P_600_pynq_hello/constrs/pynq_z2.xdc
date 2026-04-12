## PYNQ-Z2 Constraints File

## Clock - 125 MHz
set_property PACKAGE_PIN H16 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 8.000 -name sys_clk [get_ports clk]

## LEDs
set_property PACKAGE_PIN R14 [get_ports {leds[0]}]
set_property PACKAGE_PIN P14 [get_ports {leds[1]}]
set_property PACKAGE_PIN N16 [get_ports {leds[2]}]
set_property PACKAGE_PIN M14 [get_ports {leds[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[*]}]

## Switches
set_property PACKAGE_PIN M20 [get_ports {sw[0]}]
set_property PACKAGE_PIN M19 [get_ports {sw[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw[*]}]

## Buttons
set_property PACKAGE_PIN D19 [get_ports {btn[0]}]
set_property PACKAGE_PIN D20 [get_ports {btn[1]}]
set_property PACKAGE_PIN L20 [get_ports {btn[2]}]
set_property PACKAGE_PIN L19 [get_ports {btn[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {btn[*]}]

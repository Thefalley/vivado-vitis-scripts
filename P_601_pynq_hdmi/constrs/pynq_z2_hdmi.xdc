## PYNQ-Z2 HDMI TX Constraints

## Clock - 125 MHz
set_property PACKAGE_PIN H16 [get_ports clk_125]
set_property IOSTANDARD LVCMOS33 [get_ports clk_125]
create_clock -period 8.000 -name sys_clk [get_ports clk_125]

## HDMI TX - TMDS Clock
set_property PACKAGE_PIN L16 [get_ports hdmi_tx_clk_p]
set_property PACKAGE_PIN L17 [get_ports hdmi_tx_clk_n]
set_property IOSTANDARD TMDS_33 [get_ports hdmi_tx_clk_p]
set_property IOSTANDARD TMDS_33 [get_ports hdmi_tx_clk_n]

## HDMI TX - TMDS Data 0 (Blue)
set_property PACKAGE_PIN K17 [get_ports {hdmi_tx_d_p[0]}]
set_property PACKAGE_PIN K18 [get_ports {hdmi_tx_d_n[0]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_d_p[0]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_d_n[0]}]

## HDMI TX - TMDS Data 1 (Green)
set_property PACKAGE_PIN K19 [get_ports {hdmi_tx_d_p[1]}]
set_property PACKAGE_PIN J19 [get_ports {hdmi_tx_d_n[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_d_p[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_d_n[1]}]

## HDMI TX - TMDS Data 2 (Red)
set_property PACKAGE_PIN J18 [get_ports {hdmi_tx_d_p[2]}]
set_property PACKAGE_PIN H18 [get_ports {hdmi_tx_d_n[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_d_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_d_n[2]}]

## LEDs
set_property PACKAGE_PIN R14 [get_ports {leds[0]}]
set_property PACKAGE_PIN P14 [get_ports {leds[1]}]
set_property PACKAGE_PIN N16 [get_ports {leds[2]}]
set_property PACKAGE_PIN M14 [get_ports {leds[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[*]}]

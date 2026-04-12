# program.tcl - P_401 HDMI Test: PL-only, just program bitstream
# No FSBL needed (no PS code, pure PL design)

set base_dir [file dirname [file normalize [info script]]]
set bit_file $base_dir/hdmi_test.bit

puts "=== P_401 HDMI Test - Programming ZedBoard ==="

connect
after 2000

# Program FPGA
puts "Programando bitstream HDMI..."
targets -set 4
fpga $bit_file
after 2000

puts ""
puts "==========================================="
puts "  HDMI programado!"
puts "  Espera 1-2 segundos para I2C init"
puts "  LEDs esperados:"
puts "    LD0 = ON  (MMCM locked)"
puts "    LD1 = ON  (I2C ADV7511 config done)"
puts "    LD3 = parpadeo (VSYNC 60Hz)"
puts "  Monitor: 8 barras de color 720p"
puts "==========================================="

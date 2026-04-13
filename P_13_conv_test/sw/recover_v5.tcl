# Recovery via PS reset through FSBL
# Program bitstream, then download FSBL which will reinitialize the PS
connect
after 5000

puts "Before:"
puts [targets]

# Program FPGA through xc7z020
targets 2
fpga C:/project/vivado/P_13_conv_test/vitis_ws/conv_test/_ide/bitstream/zynq_conv.bit
after 5000

puts "After fpga:"
puts [targets]

# Try to use rst -system which does a PS_SRST
catch {
    targets 1
    rst -system
    after 10000
    puts "System reset done"
} err
if {$err ne ""} {
    puts "System reset: $err"
}

puts "After system reset:"
puts [targets]
disconnect

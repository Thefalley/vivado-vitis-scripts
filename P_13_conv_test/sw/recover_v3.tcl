# Full recovery attempt: disconnect, reconnect, reset ARM
connect
after 5000
puts "Initial targets:"
puts [targets]

# Program PL via xc7z020
targets 2
fpga C:/project/vivado/P_13_conv_test/vitis_ws/conv_test/_ide/bitstream/zynq_conv.bit
after 5000

puts "After fpga:"
puts [targets]

# Try to access DAP again
catch {
    targets 1
    after 2000
    puts "DAP accessible"
}

# Disconnect and reconnect
disconnect
after 5000
connect
after 5000
puts "After reconnect:"
puts [targets]

# Try to reset ARM
catch {
    targets 2
    rst -processor
    after 3000
    puts "Reset done"
} err
if {$err ne ""} {
    puts "Reset error: $err"
}

puts "Final targets:"
puts [targets]

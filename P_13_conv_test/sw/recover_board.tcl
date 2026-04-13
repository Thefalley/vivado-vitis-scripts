# Try to recover a hung ZedBoard by programming the PL directly
connect
after 5000
puts [targets]

# Try targeting the xc7z020 directly
targets 2
fpga -no-revision-check C:/project/vivado/P_13_conv_test/build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit
after 3000
puts "After FPGA program:"
puts [targets]

# Now try to see if ARM cores appeared
catch {
    targets 3
    rst -processor
    after 2000
}
catch {
    targets 4
    rst -processor
    after 2000
}
puts "Final:"
puts [targets]

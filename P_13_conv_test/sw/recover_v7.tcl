# Recovery: assert nSRST through hw_server for full PS power-on-reset equivalent
connect
after 3000

# Method 1: Use jtag sequence to toggle SRST
catch {
    set jtag_id [lindex [jtag targets] 0]
    puts "JTAG chain: [jtag targets]"
}

# Method 2: Direct XVC reset via device_program
catch {
    targets 2
    # Try "device program" which is supposed to handle the full sequence
    device program C:/project/vivado/P_13_conv_test/vitis_ws/conv_test/_ide/bitstream/zynq_conv.bit
    after 10000
} err
puts "device program: $err"

# Method 3: Use mrd on the SLCR to toggle PS reset register
# Zynq SLCR: 0xF8000200 = PSS_RST_CTRL
catch {
    targets 1
    # Try to write to PS reset control - this might work even with DAP errors
    mwr 0xF8000200 1
    after 5000
    mwr 0xF8000200 0
    after 5000
    puts "PS reset registers written"
} err2
puts "SLCR reset: $err2"

disconnect
after 10000
connect
after 10000
puts "Final:"
puts [targets]
disconnect

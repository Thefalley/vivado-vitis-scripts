# Recovery: fresh connect, program FPGA via PL target, then slow probe ARM
connect
after 10000

puts "=== TARGETS ==="
puts [targets]

# If we see only DAP error + xc7z020, try a JTAG-level reset
# by programming the FPGA which should cause PS reset too
catch {
    # Select xc7z020 for FPGA programming
    foreach t [targets -target-properties] {
        if {[dict exists $t name] && [string match "*xc7z020*" [dict get $t name]]} {
            set tgt_id [dict get $t target_id]
            puts "Found xc7z020 at target $tgt_id"
            targets $tgt_id
            break
        }
    }
    fpga C:/project/vivado/P_13_conv_test/vitis_ws/conv_test/_ide/bitstream/zynq_conv.bit
    puts "FPGA programmed OK"
    after 10000
} err
if {$err ne ""} {
    puts "FPGA program result: $err"
}

puts "=== TARGETS AFTER FPGA ==="
catch { puts [targets] }
disconnect

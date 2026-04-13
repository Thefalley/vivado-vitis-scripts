# Low-level JTAG reset attempt
connect
after 5000
puts "Targets before:"
puts [targets]

# Try JTAG-level operations
puts "\nJTAG targets:"
puts [jtag targets]

# Try device reset through jtag
catch {
    jtag targets 0
    jtag lock 0
    jtag sequence 0 256 0
    jtag run_sequence 0
    jtag unlock 0
    puts "JTAG sequence done"
} err
puts "JTAG result: $err"

after 5000

# Disconnect and reconnect
disconnect
after 5000
connect
after 10000

puts "\nTargets after JTAG reset:"
puts [targets]
disconnect

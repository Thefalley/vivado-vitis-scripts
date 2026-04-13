# Recovery via hardware SRST assertion through JTAG cable
# The Digilent JTAG-SMT2 on ZedBoard supports asserting system reset
connect
after 5000

puts "Before:"
puts [targets]

# Assert PS_SRST through JTAG cable's dedicated reset pin
# This uses the "rst" subcommand of jtag
catch {
    jtag targets 1
    # Try using the Digilent cable's reset capability
    puts "Trying hardware reset..."
} err

# Alternative: try to force-reset through the DAP even if errored
catch {
    targets 1
    rst
    after 10000
} err1
puts "rst result: $err1"

# Disconnect, wait, reconnect
disconnect
after 10000
connect
after 10000

puts "After full reconnect:"
puts [targets]
disconnect

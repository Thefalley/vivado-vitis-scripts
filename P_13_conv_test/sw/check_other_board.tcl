# Check for second ZedBoard
connect
after 10000
puts "=== All JTAG cables ==="
set cables [jtag targets]
puts $cables

connect
after 10000
puts "Current targets:"
puts [targets]
catch {targets 1}
catch {rst -srst}
after 5000
puts "After SRST:"
puts [targets]

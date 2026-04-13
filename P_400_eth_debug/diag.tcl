# Diagnostic: just connect and list targets
connect
puts "=== Debug targets ==="
targets
puts "\n=== JTAG chain ==="
jtag targets

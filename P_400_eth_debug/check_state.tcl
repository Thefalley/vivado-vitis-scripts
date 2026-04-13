# Check if app is running and Ethernet state
connect
after 1000
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
stop
after 200

puts "=== ARM State ==="
puts "PC = [rrd pc]"

puts "\n=== GEM0 Registers ==="
catch { puts "Net Control  (0xE000B000) = [format 0x%08X [mrd -value 0xE000B000]]" }
catch { puts "Net Config   (0xE000B004) = [format 0x%08X [mrd -value 0xE000B004]]" }
catch { puts "Net Status   (0xE000B008) = [format 0x%08X [mrd -value 0xE000B008]]" }
catch { puts "DMA Config   (0xE000B010) = [format 0x%08X [mrd -value 0xE000B010]]" }

puts "\n=== DDR Test ==="
mwr 0x00100000 0xDEADBEEF
set v [mrd -value 0x00100000]
puts "DDR: wrote 0xDEADBEEF, read [format 0x%08X $v] [expr {$v == 0xDEADBEEF ? {OK} : {FAIL}}]"

puts "\n=== Stack/Heap area (check for crash) ==="
catch { puts "0x001FF000 = [format 0x%08X [mrd -value 0x001FF000]]" }

con

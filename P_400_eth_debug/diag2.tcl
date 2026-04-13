connect -url tcp:127.0.0.1:3121
targets -set -filter {name =~ "*A9*#0"}
catch {stop}
after 200

puts "=== ARM Core State ==="
puts "PC: [rrd pc]"
puts ""
puts "=== DDR Test ==="
catch {
    mwr 0x00100000 0xDEADBEEF
    set v [mrd -value 0x00100000]
    puts "DDR W:0xDEADBEEF R:$v  [expr {$v == 0xDEADBEEF ? "OK" : "FAIL"}]"
} err
if {$err ne ""} { puts "DDR error: $err" }

puts ""
puts "=== Readable PS Regs ==="
catch { puts "PSS_IDCODE (0xF8000530): [mrd -value 0xF8000530]" }
catch { puts "DEVCFG STAT(0xF8007014): [mrd -value 0xF8007014]" }
catch { puts "GEM0 NetCtl(0xE000B000): [mrd -value 0xE000B000]" }
catch { puts "GEM0 NetSta(0xE000B008): [mrd -value 0xE000B008]" }

con

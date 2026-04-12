set xsa_path [lindex $argv 0]
set ws_dir   [lindex $argv 1]
set app_src  [lindex $argv 2]

puts "xsa_path = $xsa_path"
puts "ws_dir   = $ws_dir"
puts "app_src  = $app_src"

setws $ws_dir
puts "workspace set"

platform create -name conv_dma_platform -hw $xsa_path -proc ps7_cortexa9_0 -os standalone
puts "platform created"
platform generate
puts "platform generated"

app create -name conv_dma_test -platform conv_dma_platform -domain {standalone_domain} -template {Empty Application(C)}
puts "app created"

# Copy source file
set app_dir [file join $ws_dir conv_dma_test src]
file mkdir $app_dir
file copy -force $app_src $app_dir
puts "app src copied to $app_dir"

app build conv_dma_test
puts "app built"

puts "DONE"

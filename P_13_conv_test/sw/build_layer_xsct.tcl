# build_layer_xsct.tcl -- Build a layer test .c using XSCT
#
# Usage:
#   xsct build_layer_xsct.tcl <xsa_path> <ws_dir> <src_file>
#
# If platform already exists, reuses it. Creates/updates app "layer_test".

set xsa_path [lindex $argv 0]
set ws_dir   [lindex $argv 1]
set app_src  [lindex $argv 2]

puts "=== build_layer_xsct.tcl ==="
puts "xsa_path = $xsa_path"
puts "ws_dir   = $ws_dir"
puts "app_src  = $app_src"

setws $ws_dir

# Check if platform already exists
if {[file exists [file join $ws_dir zynq_conv_platform]]} {
    puts "Platform exists, reusing"
} else {
    platform create -name zynq_conv_platform -hw $xsa_path -proc ps7_cortexa9_0 -os standalone
    puts "platform created"
    platform generate
    puts "platform generated"
}

# Check if app already exists
set app_dir [file join $ws_dir layer_test src]
if {[file exists [file join $ws_dir layer_test]]} {
    puts "App exists, updating source"
} else {
    app create -name layer_test -platform zynq_conv_platform -domain {standalone_domain} -template {Empty Application(C)}
    puts "app created"
}

# Copy source file as conv_test.c (the app expects this name)
file mkdir $app_dir
# Remove old sources
foreach f [glob -nocomplain [file join $app_dir *.c]] {
    file delete -force $f
}
file copy -force $app_src [file join $app_dir conv_test.c]
puts "Source copied: $app_src -> $app_dir/conv_test.c"

app build layer_test
puts "Build complete"

set elf_path [file join $ws_dir layer_test Debug layer_test.elf]
if {![file exists $elf_path]} {
    set elf_path [file join $ws_dir layer_test build layer_test.elf]
}
puts "ELF: $elf_path"
puts "ELF exists: [file exists $elf_path]"

# build_crop_xsct.tcl -- Build conv_crop_test.c using XSCT
#
# Usage:
#   xsct build_crop_xsct.tcl <xsa_path> <ws_dir> <src_file>
#
# Example:
#   C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat build_crop_xsct.tcl \
#     ../build/zynq_conv.xsa ../vitis_ws_crop conv_crop_test.c
#
# If workspace already exists (platform built), just copies source and rebuilds.

set xsa_path [lindex $argv 0]
set ws_dir   [lindex $argv 1]
set app_src  [lindex $argv 2]

puts "xsa_path = $xsa_path"
puts "ws_dir   = $ws_dir"
puts "app_src  = $app_src"

setws $ws_dir
puts "workspace set"

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
if {[file exists [file join $ws_dir conv_crop_test]]} {
    puts "App exists, updating source"
} else {
    app create -name conv_crop_test -platform zynq_conv_platform -domain {standalone_domain} -template {Empty Application(C)}
    puts "app created"
}

# Copy source file
set app_dir [file join $ws_dir conv_crop_test src]
file mkdir $app_dir
file copy -force $app_src $app_dir
puts "app src copied to $app_dir"

app build conv_crop_test
puts "app built"

puts "DONE"

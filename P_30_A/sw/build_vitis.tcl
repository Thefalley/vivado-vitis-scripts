# build_vitis.tcl -- Build P_30_A DPU+Ethernet app (conv_v4 + eth_server)
#
# Usage: xsct build_vitis.tcl <xsa_path> <workspace_dir> <sw_dir>

set xsa_path [lindex $argv 0]
set ws_dir   [lindex $argv 1]
set sw_dir   [lindex $argv 2]

setws $ws_dir

# Platform with standalone BSP + lwip220
if {[catch {platform create -name dpu_platform -hw $xsa_path \
             -proc ps7_cortexa9_0 -os standalone} err]} {
    puts "platform create: $err (continuing)"
}

# Enable lwip library in BSP
if {[catch {bsp setlib -name lwip220} err]} {
    puts "bsp setlib lwip220: $err (may already be set)"
}
# lwIP config for high throughput (same as P_18)
foreach {k v} {
    api_mode       RAW_API
    tcp_wnd        16384
    mem_size        131072
    memp_n_pbuf    128
    pbuf_pool_size 128
} {
    if {[catch {bsp config $k $v} err]} { puts "bsp config $k: $err" }
}

platform generate

set APP_NAME "dpu_app"
if {[catch {app create -name $APP_NAME -platform dpu_platform \
             -domain {standalone_domain} -template {Empty Application(C)}} err]} {
    puts "app create: $err"
}

set app_src [file join $ws_dir $APP_NAME src]
file mkdir $app_src

foreach f [glob -nocomplain -directory $sw_dir *.c *.h] {
    file copy -force $f $app_src
    puts "copied [file tail $f]"
}

if {[catch {app build $APP_NAME} err]} {
    puts "BUILD FAILED: $err"
    exit 1
}
puts "BUILD OK: $APP_NAME"

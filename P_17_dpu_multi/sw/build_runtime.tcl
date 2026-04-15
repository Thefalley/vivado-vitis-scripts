set xsa_path       [lindex $argv 0]
set ws_dir         [lindex $argv 1]
set runtime_dir    [lindex $argv 2]
set layer_cfg_h    [lindex $argv 3]

setws $ws_dir

if {[catch {platform create -name conv_dm_platform -hw $xsa_path \
             -proc ps7_cortexa9_0 -os standalone} err]} {
    puts "platform create: $err (continuing)"
}
platform generate

set APP_NAME "runtime_smoke_test"
if {[catch {app create -name $APP_NAME -platform conv_dm_platform \
             -domain {standalone_domain} -template {Empty Application(C)}} err]} {
    puts "app create: $err"
}

set app_src [file join $ws_dir $APP_NAME src]
file mkdir $app_src

# Whitelist de archivos (evita yolov4_runtime.c del skeleton que tiene main()
# duplicado, y __pycache__)
foreach fname {dpu_api.h dpu_exec.c mem_pool.c runtime_smoke_test.c} {
    set f [file join $runtime_dir $fname]
    if {[file exists $f]} {
        file copy -force $f $app_src
        puts "copied $fname"
    }
}
file copy -force $layer_cfg_h $app_src
puts "copied layer_configs.h"

if {[catch {app build $APP_NAME} err]} {
    puts "BUILD FAILED: $err"
    exit 1
}
puts "BUILD OK: $APP_NAME"

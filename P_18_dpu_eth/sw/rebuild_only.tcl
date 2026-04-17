# Rebuild only: copy latest .c/.h to app src and rebuild (platform already exists)
set ws_dir [lindex $argv 0]
set sw_dir [lindex $argv 1]

setws $ws_dir
platform active dpu_eth_platform

set APP_NAME "dpu_eth_app"
set app_src [file join $ws_dir $APP_NAME src]

foreach f [glob -nocomplain -directory $sw_dir *.c *.h] {
    file copy -force $f $app_src
    puts "copied [file tail $f]"
}

if {[catch {app build $APP_NAME} err]} {
    puts "BUILD FAILED: $err"
    exit 1
}
puts "BUILD OK: $APP_NAME"

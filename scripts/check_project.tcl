set root_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root_dir prg_cam.xpr]
update_compile_order -fileset sources_1

set active_top [get_property top [get_filesets sources_1]]
if {$active_top ne "Camera_Pipeline"} {
    error "Unexpected synthesis top: $active_top"
}

foreach required_module {Alarmer Camera_Capture Line_Buffer Byte_Replacer Byte_FIFO Camera_Pipeline Arbitration} {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] *${required_module}.v]] == 0} {
        error "Missing active RTL file for $required_module"
    }
}

puts "PROJECT_SOURCE_CHECK_PASS top=$active_top"
close_project
exit

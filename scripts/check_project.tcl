set root_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root_dir prg_cam.xpr]
update_compile_order -fileset sources_1

set active_top [get_property top [get_filesets sources_1]]
if {$active_top ne "Camera_Ethernet_Top"} {
    error "Unexpected synthesis top: $active_top"
}

set active_generics [get_property generic [get_filesets sources_1]]
if {[lsearch -exact $active_generics "USE_CAMERA_PIPELINE=1"] < 0} {
    error "Camera source is not selected in sources_1 generics: $active_generics"
}
if {[lsearch -exact $active_generics "ENABLE_CAM1=1"] < 0} {
    error "Camera1 is not enabled in sources_1 generics: $active_generics"
}
if {[lsearch -exact $active_generics "CAMERA_CRC_ENABLE=1"] < 0} {
    error "Camera egress CRC-16 is not enabled in sources_1 generics: $active_generics"
}
if {[lsearch -exact $active_generics "CAMERA_INGRESS_CRC_ENABLE=1"] < 0} {
    error "Camera ingress CRC audit is not enabled in sources_1 generics: $active_generics"
}

foreach required_module {
    Alarmer Camera_Capture Line_Buffer Byte_Replacer Byte_FIFO
    Camera_Pipeline Arbitration Ethernet_Frame_Adapter
    Taxi_Ethernet_Subsystem Ethernet_Mii_Rmii_Bridge Camera_Ethernet_Top
} {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] \
            *${required_module}.*]] == 0} {
        error "Missing active RTL file for $required_module"
    }
}

puts "PROJECT_SOURCE_CHECK_PASS top=$active_top generics=$active_generics"
close_project
exit

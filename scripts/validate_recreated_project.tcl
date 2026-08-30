set project_root [file normalize [file join [file dirname [info script]] ..]]
set validation_root [file join $project_root build project_recreate_validation]
set project_xpr [file join $validation_root prg_cam.xpr]
set report_root [file join $validation_root reports]
file mkdir $report_root

if {![file exists $project_xpr]} {
    error "RECREATED_PROJECT_MISSING: $project_xpr"
}
open_project $project_xpr
update_compile_order -fileset sources_1

set active_top [get_property top [get_filesets sources_1]]
set active_generics [get_property generic [get_filesets sources_1]]
if {$active_top ne "Camera_Ethernet_Top"} {
    error "RECREATED_PROJECT_TOP_MISMATCH: $active_top"
}
foreach required_generic {
    USE_CAMERA_PIPELINE=1
    USE_BYTE_FIFO_PATH=1
    ENABLE_CAM1=1
    CAMERA_CRC_ENABLE=1
    CAMERA_INGRESS_CRC_ENABLE=1
    CAMERA_LINES_PER_FRAME=480
} {
    if {[lsearch -exact $active_generics $required_generic] < 0} {
        error "RECREATED_PROJECT_GENERIC_MISSING: $required_generic"
    }
}

generate_target all [get_ips ethernet_clk_wiz]
synth_ip -force [get_ips ethernet_clk_wiz]
synth_design -top Camera_Ethernet_Top -part xc7a50ticsg324-1L

report_utilization -file [file join $report_root post_synth_utilization.rpt]
report_timing_summary -report_unconstrained -check_timing_verbose \
    -file [file join $report_root post_synth_timing_summary.rpt]
report_cdc -details -file [file join $report_root post_synth_cdc.rpt]
write_checkpoint -force [file join $validation_root Camera_Ethernet_Top_synth.dcp]

set unresolved [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved] != 0} {
    error "RECREATED_PROJECT_BLACKBOXES: $unresolved"
}
puts "RECREATED_PROJECT_SYNTH_RESULT=PASS"
puts "RECREATED_PROJECT_TOP=$active_top"
puts "RECREATED_PROJECT_GENERICS=$active_generics"
close_project
exit 0

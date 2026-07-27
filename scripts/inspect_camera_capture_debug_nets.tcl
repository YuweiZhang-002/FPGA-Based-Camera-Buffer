set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set dcp_file [file normalize \
    [file join $project_root build ethernet_ila Camera_Ethernet_Top_ila_routed.dcp]]

open_checkpoint $dcp_file
foreach pattern {
    *u_camera_pipeline/u_capture_0/pclk_hist*
    *u_camera_pipeline/u_capture_0/pclk_level*
    *u_camera_pipeline/u_capture_0/pclk_sync*
    *u_camera_pipeline/u_capture_0/href_sync*
    *u_camera_pipeline/u_capture_0/data_sync*
} {
    set nets [get_nets -hier -quiet -filter "NAME =~ $pattern"]
    puts "DEBUG_NET_PATTERN=$pattern COUNT=[llength $nets]"
    foreach net $nets {
        puts "DEBUG_NET=$net"
    }
}
close_design
exit

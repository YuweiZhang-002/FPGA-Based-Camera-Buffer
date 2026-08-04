# A3 layer 1: CAM1 pin/synchronizer/PCLK qualifier/Camera_Capture boundary.
# Requires the bit/ltx produced by scripts/build_ethernet_ila.tcl.
set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]

set ::env(ILA_TRIGGER_NAME) "u_camera_pipeline/u_capture_1/href_rise"
set ::env(ILA_TRIGGER_POSITION) "2048"
set ::env(ILA_CAPTURE_CSV) [file join $project_root build ethernet_ila \
    a3_cam1_layer1_capture.csv]

source [file join $script_dir capture_ethernet_ila.tcl]

# A3 layer 2: arbitration/Byte_Replacer/Byte_FIFO/Frame Adapter boundary.
# The trigger is observation-only and asserts only for a granted CAM1 packet.
set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]

set ::env(ILA_TRIGGER_NAME) "u_camera_pipeline/cam1_selected_valid_dbg"
set ::env(ILA_TRIGGER_POSITION) "512"
set ::env(ILA_CAPTURE_CSV) [file join $project_root build ethernet_ila \
    a3_cam1_layer2_capture.csv]

source [file join $script_dir capture_ethernet_ila.tcl]

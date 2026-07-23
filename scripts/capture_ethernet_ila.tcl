set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set output_dir [file normalize [file join $project_root build ethernet_ila]]
set ltx_file [file normalize [file join $output_dir Camera_Ethernet_Top_ila.ltx]]
set csv_file [file normalize [file join $output_dir frame_handshake_capture.csv]]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set devices [get_hw_devices -quiet xc7a50t_0]
if {[llength $devices] != 1} {
    error "Expected one xc7a50t_0 device, found [llength $devices]"
}
set device [lindex $devices 0]
current_hw_device $device
set_property PROBES.FILE $ltx_file $device
set_property FULL_PROBES.FILE $ltx_file $device
refresh_hw_device -update_hw_probes true $device

set ilas [get_hw_ilas -quiet -of_objects $device]
if {[llength $ilas] != 1} {
    error "Expected one hardware ILA, found [llength $ilas]"
}
set ila [lindex $ilas 0]
set handshake_probe [get_hw_probes -quiet frame_handshake -of_objects $ila]
if {[llength $handshake_probe] != 1} {
    error "Expected one frame_handshake probe, found [llength $handshake_probe]"
}

# Trigger near the front of the sample memory.  This leaves 3584 100-MHz
# samples after the first AXIS handshake for FIFO/CDC/MAC/RMII activity.
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 512 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $handshake_probe

puts "ILA_CAPTURE_ARMED trigger=frame_handshake==1 depth=4096 position=512"
run_hw_ila $ila
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $csv_file $data
puts "ILA_CAPTURE_RESULT=PASS"
puts "ILA_CAPTURE_CSV=$csv_file"

close_hw_target
disconnect_hw_server
close_hw_manager

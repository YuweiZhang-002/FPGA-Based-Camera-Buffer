set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set output_dir [file normalize [file join $project_root build ethernet_ila]]
set ltx_file [file normalize [file join $output_dir Camera_Ethernet_Top_ila.ltx]]

# Select a one-bit trigger without rebuilding the ILA image.  The default
# captures the exact Camera_Capture LENGTH_ERROR decision.  Example:
#   $env:ILA_TRIGGER_NAME = "camera_packet_valid"
#   vivado.bat -mode batch -source scripts/capture_ethernet_ila.tcl
if {[info exists ::env(ILA_TRIGGER_NAME)] && $::env(ILA_TRIGGER_NAME) ne ""} {
    set trigger_name $::env(ILA_TRIGGER_NAME)
} else {
    set trigger_name "camera_length_error_pulse_dbg"
}
set safe_trigger_name [string map {"/" "_" "\\" "_" "[" "_" "]" "_"} $trigger_name]
if {[info exists ::env(ILA_CAPTURE_CSV)] && $::env(ILA_CAPTURE_CSV) ne ""} {
    set csv_file [file normalize $::env(ILA_CAPTURE_CSV)]
} else {
    set csv_file [file normalize [file join $output_dir "${safe_trigger_name}_capture.csv"]]
}

# The default leaves most samples after a high-rate activity trigger.  A
# LENGTH_ERROR investigation needs enough pre-trigger history to include the
# complete approximately 1100-cycle camera row, so callers may override it:
#   $env:ILA_TRIGGER_POSITION = "3072"
if {[info exists ::env(ILA_TRIGGER_POSITION)] && $::env(ILA_TRIGGER_POSITION) ne ""} {
    set trigger_position $::env(ILA_TRIGGER_POSITION)
} else {
    set trigger_position 512
}
if {![string is integer -strict $trigger_position] ||
    $trigger_position < 0 || $trigger_position >= 4096} {
    error "ILA_TRIGGER_POSITION must be an integer in the range 0..4095"
}

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
set trigger_probe [get_hw_probes -quiet $trigger_name -of_objects $ila]
if {[llength $trigger_probe] != 1} {
    error "Expected one $trigger_name probe, found [llength $trigger_probe]"
}
if {[get_property WIDTH $trigger_probe] != 1} {
    error "Trigger probe $trigger_name must be one bit wide"
}

# Trigger near the front of the sample memory by default.  An environment
# override can reserve more pre-trigger history for slow camera-row events.
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION $trigger_position $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trigger_probe

puts "ILA_CAPTURE_ARMED trigger=${trigger_name}==1 depth=4096 position=$trigger_position"
run_hw_ila $ila
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $csv_file $data
puts "ILA_CAPTURE_RESULT=PASS"
puts "ILA_CAPTURE_CSV=$csv_file"

close_hw_target
disconnect_hw_server
close_hw_manager

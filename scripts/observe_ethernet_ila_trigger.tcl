set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set output_dir [file normalize [file join $project_root build ethernet_ila]]
set ltx_file [file normalize [file join $output_dir Camera_Ethernet_Top_ila.ltx]]

if {[info exists ::env(ILA_TRIGGER_NAME)] && $::env(ILA_TRIGGER_NAME) ne ""} {
    set trigger_name $::env(ILA_TRIGGER_NAME)
} else {
    set trigger_name "camera_packet_valid"
}
if {[info exists ::env(ILA_OBSERVE_MS)] && $::env(ILA_OBSERVE_MS) ne ""} {
    set observe_ms $::env(ILA_OBSERVE_MS)
} else {
    set observe_ms 10000
}
if {![string is integer -strict $observe_ms] || $observe_ms < 1} {
    error "ILA_OBSERVE_MS must be a positive integer"
}
if {![file exists $ltx_file]} {
    error "Required ILA probe file not found: $ltx_file"
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
if {[llength $trigger_probe] != 1 || [get_property WIDTH $trigger_probe] != 1} {
    error "Expected one one-bit trigger probe named $trigger_name"
}

set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 3072 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trigger_probe

puts "ILA_OBSERVE_ARMED trigger=${trigger_name}==1 observe_ms=$observe_ms"
run_hw_ila $ila
after $observe_ms
set core_status [get_property STATUS.CORE_STATUS $ila]
puts "ILA_OBSERVE_STATUS=$core_status"
if {[string match -nocase "*waiting for trigger*" $core_status]} {
    puts "ILA_OBSERVE_RESULT=NO_TRIGGER_IN_WINDOW"
} else {
    puts "ILA_OBSERVE_RESULT=TRIGGERED_OR_STOPPED"
}

# Closing the hardware target ends this observation session even when the ILA
# remains in WAITING FOR TRIGGER.  Unlike wait_on_hw_ila, this path is bounded.
close_hw_target
disconnect_hw_server
close_hw_manager

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set output_dir [file normalize [file join $project_root build ethernet_ila]]
set bit_file [file normalize [file join $output_dir Camera_Ethernet_Top_ila.bit]]
set ltx_file [file normalize [file join $output_dir Camera_Ethernet_Top_ila.ltx]]

foreach required [list $bit_file $ltx_file] {
    if {![file exists $required]} {
        error "Required ILA artifact not found: $required"
    }
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
set_property PROGRAM.FILE $bit_file $device
set_property PROBES.FILE $ltx_file $device
set_property FULL_PROBES.FILE $ltx_file $device
program_hw_devices $device
refresh_hw_device -update_hw_probes true $device

set ilas [get_hw_ilas -quiet -of_objects $device]
puts "HW_ILA_DEVICE=$device"
puts "HW_ILA_COUNT=[llength $ilas]"
foreach ila $ilas {
    puts "HW_ILA=$ila"
    foreach probe [get_hw_probes -quiet -of_objects $ila] {
        puts "HW_PROBE=$probe WIDTH=[get_property WIDTH $probe]"
    }
}
puts "HW_ILA_PROGRAM_RESULT=PASS"

close_hw_target
disconnect_hw_server
close_hw_manager

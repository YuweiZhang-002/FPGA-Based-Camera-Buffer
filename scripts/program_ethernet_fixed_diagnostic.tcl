set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set bit_file [file normalize [file join \
    $project_root build ethernet_fixed_diagnostic Camera_Ethernet_Top_fixed.bit]]

if {![file exists $bit_file]} {
    error "Fixed diagnostic bitstream does not exist: $bit_file"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set matching_devices {}
foreach dev [get_hw_devices] {
    set part_name [get_property PART $dev]
    puts "DISCOVERED_DEVICE=$dev PART=$part_name"
    if {[string match -nocase *xc7a50t* $part_name] ||
        [string match -nocase *xc7a50t* $dev]} {
        lappend matching_devices $dev
    }
}
if {[llength $matching_devices] != 1} {
    error "Expected exactly one xc7a50t device, found [llength $matching_devices]"
}

set device [lindex $matching_devices 0]
current_hw_device $device
refresh_hw_device -update_hw_probes false $device
set_property PROGRAM.FILE $bit_file $device
set_property PROBES.FILE {} $device
set_property FULL_PROBES.FILE {} $device

puts "PROGRAM_DEVICE=$device"
puts "PROGRAM_BITSTREAM=$bit_file"
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device

puts "FIXED_DIAGNOSTIC_PROGRAM_RESULT=PASS"
puts "FIXED_DIAGNOSTIC_EXPECTED_PAYLOAD=00010203...7F"
puts "FIXED_DIAGNOSTIC_EXPECTED_ETHERTYPE=0x88B5"

close_hw_target
disconnect_hw_server
close_hw_manager
exit

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set bit_file [file normalize [file join $project_root prg_cam.runs impl_1 Camera_Ethernet_Top.bit]]
set probes_file [file rootname $bit_file].ltx

if {![file exists $bit_file]} {
    error "Bitstream does not exist: $bit_file"
}

puts "PROGRAM_BITSTREAM=$bit_file"
puts "PROGRAM_BITSTREAM_SIZE=[file size $bit_file]"

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

if {[llength $matching_devices] == 0} {
    error "No xc7a50t hardware device was found in the open JTAG target"
}

set hw_dev [lindex $matching_devices 0]
current_hw_device $hw_dev
refresh_hw_device -update_hw_probes false $hw_dev

set_property PROGRAM.FILE $bit_file $hw_dev
if {[file exists $probes_file]} {
    set_property PROBES.FILE $probes_file $hw_dev
    puts "PROGRAM_PROBES=$probes_file"
} else {
    set_property PROBES.FILE {} $hw_dev
    puts "PROGRAM_PROBES=NONE"
}

puts "PROGRAM_DEVICE=$hw_dev"
puts "PROGRAM_FILE_PROPERTY=[get_property PROGRAM.FILE $hw_dev]"
program_hw_devices $hw_dev
refresh_hw_device -update_hw_probes false $hw_dev

puts "PROGRAM_RESULT=PASS"
if {[catch {get_property REGISTER.CONFIG_STATUS $hw_dev} config_status]} {
    puts "CONFIG_STATUS=UNAVAILABLE ($config_status)"
} else {
    puts "CONFIG_STATUS=$config_status"
}

close_hw_target
disconnect_hw_server
close_hw_manager

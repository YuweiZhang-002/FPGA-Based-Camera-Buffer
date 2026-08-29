# Compare the FPGA-side CAM1 cumulative packet-drop counter over one observation
# window and keep the ILA armed for any packet FIFO almost-full event in between.
#
# Optional environment variables:
#   DROP_DIAG_SECONDS   observation duration, default 60
#   DROP_DIAG_OUT_DIR   output directory, default build/drop_diagnosis

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set ltx_file [file normalize [file join $project_root build ethernet_ila Camera_Ethernet_Top_ila.ltx]]
if {![file exists $ltx_file]} {
    error "Required ILA probe file not found: $ltx_file"
}

if {[info exists ::env(DROP_DIAG_SECONDS)] && $::env(DROP_DIAG_SECONDS) ne ""} {
    set observe_seconds $::env(DROP_DIAG_SECONDS)
} else {
    set observe_seconds 60
}
if {![string is integer -strict $observe_seconds] || $observe_seconds < 1} {
    error "DROP_DIAG_SECONDS must be a positive integer"
}

if {[info exists ::env(DROP_DIAG_OUT_DIR)] && $::env(DROP_DIAG_OUT_DIR) ne ""} {
    set output_dir [file normalize $::env(DROP_DIAG_OUT_DIR)]
} else {
    set output_dir [file normalize [file join $project_root build drop_diagnosis]]
}
file mkdir $output_dir

proc exact_probe {ila name width} {
    set probes [get_hw_probes -quiet $name -of_objects $ila]
    if {[llength $probes] != 1} {
        error "Expected one hardware probe named $name, found [llength $probes]"
    }
    set probe [lindex $probes 0]
    if {[get_property WIDTH $probe] != $width} {
        error "Probe $name width is [get_property WIDTH $probe], expected $width"
    }
    return $probe
}

proc capture_snapshot {ila trigger_probe csv_file label} {
    set_property CONTROL.DATA_DEPTH 4096 $ila
    # Only one post-trigger sample is needed.  This makes an activity snapshot
    # finish immediately while retaining the preceding counter/level history.
    set_property CONTROL.TRIGGER_POSITION 4095 $ila
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $trigger_probe
    run_hw_ila $ila

    set waited_ms 0
    while {$waited_ms < 5000} {
        after 100
        incr waited_ms 100
        set status [get_property STATUS.CORE_STATUS $ila]
        if {![string match -nocase "*waiting for trigger*" $status]} {
            break
        }
    }
    set status [get_property STATUS.CORE_STATUS $ila]
    if {[string match -nocase "*waiting for trigger*" $status]} {
        error "$label snapshot did not see camera packet activity within 5 seconds"
    }

    wait_on_hw_ila $ila
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -force -csv_file $csv_file $data
    puts "DROP_DIAG_${label}_CSV=$csv_file"
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

# Fail before the timed run if the bit/ltx pair does not expose the requested
# evidence. camera_packet_valid is present in the current A3 probe layout and
# provides a deterministic activity trigger while camera packets are flowing.
# This diagnostic therefore requires live camera traffic for both snapshots.
set snapshot_clock [exact_probe $ila camera_packet_valid 1]
exact_probe $ila frame_handshake 1
set fifo_almost_full [exact_probe $ila camera_packet_fifo_almost_full 1]
exact_probe $ila camera_drop_count_1 32
exact_probe $ila camera_packet_fifo_level 16
exact_probe $ila tx_fifo_overflow 1
exact_probe $ila tx_error_underflow 1

set start_csv [file normalize [file join $output_dir fpga_start.csv]]
set almost_full_csv [file normalize [file join $output_dir fpga_almost_full_event.csv]]
set end_csv [file normalize [file join $output_dir fpga_end.csv]]

capture_snapshot $ila $snapshot_clock $start_csv START

set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 2048 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $fifo_almost_full
puts "DROP_DIAG_ALMOST_FULL_ARMED seconds=$observe_seconds"
run_hw_ila $ila
after [expr {$observe_seconds * 1000}]

set almost_full_status [get_property STATUS.CORE_STATUS $ila]
puts "DROP_DIAG_ALMOST_FULL_STATUS=$almost_full_status"
if {[string match -nocase "*waiting for trigger*" $almost_full_status]} {
    puts "DROP_DIAG_ALMOST_FULL_SEEN=0"
} else {
    wait_on_hw_ila $ila
    set almost_full_data [upload_hw_ila_data $ila]
    write_hw_ila_data -force -csv_file $almost_full_csv $almost_full_data
    puts "DROP_DIAG_ALMOST_FULL_SEEN=1"
    puts "DROP_DIAG_ALMOST_FULL_CSV=$almost_full_csv"
}

# Vivado exposes no stop_hw_ila command. Reopening the target cleanly cancels a
# no-event acquisition before the ending counter snapshot is armed.
close_hw_target
open_hw_target
set devices [get_hw_devices -quiet xc7a50t_0]
set device [lindex $devices 0]
current_hw_device $device
set_property PROBES.FILE $ltx_file $device
set_property FULL_PROBES.FILE $ltx_file $device
refresh_hw_device -update_hw_probes true $device
set ilas [get_hw_ilas -quiet -of_objects $device]
set ila [lindex $ilas 0]
set snapshot_clock [exact_probe $ila camera_packet_valid 1]

capture_snapshot $ila $snapshot_clock $end_csv END
puts "DROP_DIAG_RESULT=PASS"
puts "DROP_DIAG_SECONDS=$observe_seconds"

close_hw_target
disconnect_hw_server
close_hw_manager

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set report_dir [file normalize [file join $project_root build gui_ethernet_rebuild]]
file mkdir $report_dir

open_project [file join $project_root prg_cam.xpr]
set_property top Camera_Ethernet_Top [current_fileset]
update_compile_order -fileset sources_1

# This is the same project-run path used by the Vivado GUI Generate Bitstream
# command.  It does not remove project sources or IP/generated directories.
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "GUI_SYNTH_STATUS $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "GUI synthesis did not complete: $synth_status"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "GUI_IMPL_STATUS $impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "GUI implementation did not complete: $impl_status"
}

open_run impl_1

set taxi_mii_tx_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/*/tx_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]
set taxi_fifo_m_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/tx_fifo/fifo_inst/m_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]

puts "GUI_TAXI_MII_TX_ASYNC_RESET_PRE_COUNT [llength $taxi_mii_tx_reset_pins]"
puts "GUI_TAXI_FIFO_M_ASYNC_RESET_PRE_COUNT [llength $taxi_fifo_m_reset_pins]"
if {[llength $taxi_mii_tx_reset_pins] != 4 ||
    [llength $taxi_fifo_m_reset_pins] != 4} {
    error "Expected 4+4 Taxi asynchronous reset PRE pins"
}

report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose \
    -file [file join $report_dir timing_summary.rpt]
report_exceptions -coverage \
    -file [file join $report_dir reset_exception_coverage.rpt]
report_cdc -details \
    -file [file join $report_dir cdc.rpt]
report_drc \
    -file [file join $report_dir drc.rpt]
report_utilization \
    -file [file join $report_dir utilization.rpt]

set impl_run_dir [file normalize [get_property DIRECTORY [get_runs impl_1]]]
set bit_file [file normalize [file join $impl_run_dir Camera_Ethernet_Top.bit]]
set dcp_file [file normalize [file join $impl_run_dir Camera_Ethernet_Top_routed.dcp]]
foreach required [list $bit_file $dcp_file] {
    if {![file exists $required]} {
        error "Expected GUI run artifact does not exist: $required"
    }
}
file copy -force $bit_file [file join $report_dir [file tail $bit_file]]
file copy -force $dcp_file [file join $report_dir [file tail $dcp_file]]

puts "GUI_IMPL_PROGRESS [get_property PROGRESS [get_runs impl_1]]"
puts "GUI_IMPL_DIRECTORY $impl_run_dir"
puts "GUI_BITSTREAM $bit_file"
puts "GUI_ROUTED_DCP $dcp_file"
puts "GUI_REBUILD_RESULT=PASS"

close_project
exit

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set output_dir [file normalize [file join $project_root build ethernet_fixed_diagnostic]]
file mkdir $output_dir

set bit_file [file join $output_dir Camera_Ethernet_Top_fixed.bit]
set dcp_file [file join $output_dir Camera_Ethernet_Top_fixed_routed.dcp]
set timing_file [file join $output_dir timing_summary.rpt]
set drc_file [file join $output_dir drc.rpt]
set utilization_file [file join $output_dir utilization.rpt]

open_project [file join $project_root prg_cam.xpr]
set_property board_part {} [current_project]
set_property top Camera_Ethernet_Top [get_filesets sources_1]
update_compile_order -fileset sources_1

generate_target all [get_ips ethernet_clk_wiz]
synth_ip -force [get_ips ethernet_clk_wiz]

# Diagnostic build only: no camera input is required.  The existing fixed
# 00..7F generator feeds the existing Byte_FIFO -> Frame Adapter -> Taxi path.
# This parameter override is local to this in-memory synthesis and is not
# saved into prg_cam.xpr.
synth_design \
    -top Camera_Ethernet_Top \
    -part xc7a50ticsg324-1L \
    -generic {USE_CAMERA_PIPELINE=0 USE_BYTE_FIFO_PATH=1 ENABLE_CAM1=0}

set taxi_mii_tx_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/*/tx_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]
set taxi_fifo_m_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/tx_fifo/fifo_inst/m_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]
if {[llength $taxi_mii_tx_reset_pins] != 4 ||
    [llength $taxi_fifo_m_reset_pins] != 4} {
    error "Expected 4+4 Taxi asynchronous-reset PRE pins"
}

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file $timing_file
report_drc -file $drc_file
report_utilization -file $utilization_file

set setup_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set hold_path [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
set drc_blockers [get_drc_violations -quiet -filter \
    {SEVERITY == Error || SEVERITY == "Critical Warning"}]

puts "FIXED_DIAGNOSTIC_SETUP_SLACK_NS=$setup_slack"
puts "FIXED_DIAGNOSTIC_HOLD_SLACK_NS=$hold_slack"
puts "FIXED_DIAGNOSTIC_DRC_BLOCKER_COUNT=[llength $drc_blockers]"
if {$setup_slack < 0 || $hold_slack < 0 || [llength $drc_blockers] != 0} {
    error "Fixed diagnostic implementation failed timing/DRC acceptance"
}

write_checkpoint -force $dcp_file
write_bitstream -force $bit_file

puts "FIXED_DIAGNOSTIC_BUILD_RESULT=PASS"
puts "FIXED_DIAGNOSTIC_BITSTREAM=[file normalize $bit_file]"
puts "FIXED_DIAGNOSTIC_MODE=USE_CAMERA_PIPELINE=0 USE_BYTE_FIFO_PATH=1"

close_project
exit

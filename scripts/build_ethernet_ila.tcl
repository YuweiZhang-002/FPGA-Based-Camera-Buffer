set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set output_dir [file normalize [file join $project_root build ethernet_ila]]
file mkdir $output_dir

proc exact_net {name} {
    set obj [get_nets -quiet $name]
    if {[llength $obj] != 1} {
        error "Expected exactly one synthesized net named '$name', found [llength $obj]"
    }
    return $obj
}

proc exact_bus {name width} {
    set result {}
    for {set i 0} {$i < $width} {incr i} {
        lappend result [exact_net [format {%s[%d]} $name $i]]
    }
    return $result
}

proc connect_probe {core index width nets} {
    if {$index > 0} {
        create_debug_port $core probe
    }
    set port [get_debug_ports ${core}/probe${index}]
    set_property port_width $width $port
    set_property PROBE_TYPE DATA_AND_TRIGGER $port
    connect_debug_port $port $nets
}

open_project [file join $project_root prg_cam.xpr]
# The diagnostic copy only needs the exact device and the project's XDC.  Do not
# retain a board_part revision that is unavailable in this Vivado installation;
# implement_debug_core otherwise tries to resolve the board before inserting ILA.
set_property board_part {} [current_project]
save_project_as -force [file join $output_dir prg_cam_ila.xpr]
set_property top Camera_Ethernet_Top [get_filesets sources_1]
update_compile_order -fileset sources_1

generate_target all [get_ips ethernet_clk_wiz]
synth_ip -force [get_ips ethernet_clk_wiz]
# Keep the Camera/ILA build selection explicit at the synthesis boundary so a
# saved GUI setting cannot silently disable either routed camera input.
synth_design -top Camera_Ethernet_Top -part xc7a50ticsg324-1L \
    -generic {USE_CAMERA_PIPELINE=1 USE_BYTE_FIFO_PATH=1 ENABLE_CAM1=1 CAMERA_LINES_PER_FRAME=480}

set taxi_mii_tx_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/*/tx_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]
set taxi_fifo_m_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/tx_fifo/fifo_inst/m_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]
set taxi_async_reset_pin_count [expr {
    [llength $taxi_mii_tx_reset_pins] + [llength $taxi_fifo_m_reset_pins]}]
puts "TAXI_MII_TX_ASYNC_RESET_PRE_COUNT: [llength $taxi_mii_tx_reset_pins]"
puts "TAXI_FIFO_M_ASYNC_RESET_PRE_COUNT: [llength $taxi_fifo_m_reset_pins]"
if {$taxi_async_reset_pin_count != 8} {
    error "Expected exactly 8 constrained Taxi asynchronous-reset PRE pins; found $taxi_async_reset_pin_count"
}

set ila_name u_ila_ethernet_bringup
create_debug_core $ila_name ila
set_property C_DATA_DEPTH 4096 [get_debug_cores $ila_name]
set_property C_TRIGIN_EN false [get_debug_cores $ila_name]
set_property C_TRIGOUT_EN false [get_debug_cores $ila_name]
set_property C_ADV_TRIGGER false [get_debug_cores $ila_name]
set_property port_width 1 [get_debug_ports ${ila_name}/clk]
connect_debug_port ${ila_name}/clk [exact_net logic_clk]

# A3 CAM1 layout.  Replace the old CAM0 detail probes instead of exceeding the
# ILA v6.x 64-probe limit.  The functional datapath is unchanged.
# Layer 1: CAM1 pins -> synchronizer/qualifier -> Camera_Capture output.
connect_probe $ila_name 0  1 [exact_net camera1_pclk_dbg]
connect_probe $ila_name 1  1 [exact_net camera1_href_dbg]
connect_probe $ila_name 2  8 [exact_bus u_camera_pipeline/u_capture_1/data_on_pclk_rise 8]
connect_probe $ila_name 3  1 [exact_net u_camera_pipeline/u_capture_1/pclk_sync]
connect_probe $ila_name 4  1 [exact_net u_camera_pipeline/u_capture_1/href_sync]
connect_probe $ila_name 5  8 [exact_bus u_camera_pipeline/u_capture_1/data_sync 8]
connect_probe $ila_name 6  1 [exact_net u_camera_pipeline/u_capture_1/pclk_pulse]
connect_probe $ila_name 7  1 [exact_net u_camera_pipeline/u_capture_1/href_rise]
connect_probe $ila_name 8  1 [exact_net u_camera_pipeline/u_capture_1/href_fall]
connect_probe $ila_name 9  2 [exact_bus u_camera_pipeline/u_capture_1/pclk_low_count 2]
connect_probe $ila_name 10 2 [exact_bus u_camera_pipeline/u_capture_1/pclk_high_count 2]
connect_probe $ila_name 11 1 [exact_net u_camera_pipeline/u_capture_1/pclk_phase_armed]
connect_probe $ila_name 12 1 [exact_net u_camera_pipeline/u_capture_1/capture_armed]
connect_probe $ila_name 13 1 [exact_net u_camera_pipeline/u_capture_1/line_active]
connect_probe $ila_name 14 1 [exact_net u_camera_pipeline/u_capture_1/line_end_pending]
connect_probe $ila_name 15 1 [exact_net camera_enable_sync]
connect_probe $ila_name 16 1 [exact_net camera_pipeline_rst]
connect_probe $ila_name 17 16 [exact_bus camera1_current_byte_count_dbg 16]
connect_probe $ila_name 18 16 [exact_bus camera1_last_line_byte_count_dbg 16]
connect_probe $ila_name 19 8 [exact_bus camera1_line_flags_dbg 8]
connect_probe $ila_name 20 1 [exact_net camera1_line_end_dbg]
connect_probe $ila_name 21 1 [exact_net camera1_length_error_pulse_dbg]
connect_probe $ila_name 22 1 [exact_net camera1_capture_byte_valid_dbg]
connect_probe $ila_name 23 32 [exact_bus camera_drop_count_1 32]
connect_probe $ila_name 24 8 [exact_bus u_camera_pipeline/c1_data 8]
connect_probe $ila_name 25 1 [exact_net u_camera_pipeline/c1_start]

# Layer 2: Line_Buffer/arbitration -> Byte_Replacer -> Byte_FIFO -> Adapter.
connect_probe $ila_name 26 4 [exact_bus camera_arb_grant 4]
connect_probe $ila_name 27 12 [exact_bus camera_buffer_used_count 12]
connect_probe $ila_name 28 12 [exact_bus camera_buffer_committed_count 12]
connect_probe $ila_name 29 8 [exact_bus u_camera_pipeline/selected_data 8]
connect_probe $ila_name 30 1 [exact_net u_camera_pipeline/cam1_selected_valid_dbg]
connect_probe $ila_name 31 1 [exact_net u_camera_pipeline/replacer_in_ready]
connect_probe $ila_name 32 1 [exact_net u_camera_pipeline/selected_last]
connect_probe $ila_name 33 2 [exact_bus u_camera_pipeline/selected_cam_id 2]
connect_probe $ila_name 34 8 [exact_bus u_camera_pipeline/selected_flags 8]
connect_probe $ila_name 35 7 [exact_bus u_camera_pipeline/u_byte_replacer/output_index 7]
connect_probe $ila_name 36 8 [exact_bus u_camera_pipeline/replaced_data 8]
connect_probe $ila_name 37 1 [exact_net u_camera_pipeline/replaced_valid]
connect_probe $ila_name 38 1 [exact_net u_camera_pipeline/replaced_ready]
connect_probe $ila_name 39 1 [exact_net u_camera_pipeline/replaced_last]
connect_probe $ila_name 40 8 [exact_bus camera_packet_data 8]
connect_probe $ila_name 41 1 [exact_net camera_packet_valid]
connect_probe $ila_name 42 1 [exact_net camera_packet_ready]
connect_probe $ila_name 43 1 [exact_net camera_packet_last]
connect_probe $ila_name 44 16 [exact_bus camera_packet_fifo_level 16]
connect_probe $ila_name 45 1 [exact_net camera_packet_fifo_almost_full]
connect_probe $ila_name 46 8 [exact_bus packet_data 8]
connect_probe $ila_name 47 1 [exact_net packet_valid]
connect_probe $ila_name 48 1 [exact_net packet_ready]
connect_probe $ila_name 49 1 [exact_net packet_last]
connect_probe $ila_name 50 7 [exact_bus packet_byte_index_dbg 7]
connect_probe $ila_name 51 8 [exact_bus packet_row_idx_hi_dbg 8]
connect_probe $ila_name 52 1 [exact_net packet_bad_flags_dbg]
connect_probe $ila_name 53 1 [exact_net packet_bad_row_idx_dbg]
connect_probe $ila_name 54 1 [exact_net packet_bad_header_dbg]
connect_probe $ila_name 55 8 [exact_bus frame_data 8]
connect_probe $ila_name 56 1 [exact_net frame_valid]
connect_probe $ila_name 57 1 [exact_net frame_ready]
connect_probe $ila_name 58 1 [exact_net frame_last]
connect_probe $ila_name 59 1 [exact_net frame_handshake]
connect_probe $ila_name 60 1 [exact_net tx_error_underflow]
connect_probe $ila_name 61 1 [exact_net tx_fifo_overflow]
connect_probe $ila_name 62 1 [exact_net rmii_tx_en_dbg]
connect_probe $ila_name 63 2 [exact_bus rmii_txd_dbg 2]

# implement_debug_core requires the debug-net constraints to have been persisted
# in a saved project.  This modifies only build/ethernet_ila/prg_cam_ila.xpr.
save_constraints
write_checkpoint -force [file join $output_dir Camera_Ethernet_Top_ila_synth.dcp]
implement_debug_core
opt_design
place_design
phys_opt_design
route_design

set bit_file [file join $output_dir Camera_Ethernet_Top_ila.bit]
set ltx_file [file join $output_dir Camera_Ethernet_Top_ila.ltx]
set dcp_file [file join $output_dir Camera_Ethernet_Top_ila_routed.dcp]

report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -file [file join $output_dir timing_summary.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_utilization -file [file join $output_dir utilization.rpt]
write_checkpoint -force $dcp_file
write_bitstream -force $bit_file
write_debug_probes -force $ltx_file

puts "ILA_BUILD_RESULT=PASS"
puts "ILA_BITSTREAM=$bit_file"
puts "ILA_PROBES=$ltx_file"
puts "ILA_CORE_COUNT=[llength [get_debug_cores]]"
puts "ILA_PROBE_COUNT=[llength [get_debug_ports ${ila_name}/probe*]]"

close_project

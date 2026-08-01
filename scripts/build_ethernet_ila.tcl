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
# The saved GUI project currently retains the fixed-source diagnostic generic.
# This script is the Camera/ILA build, so override that project property at the
# synthesis boundary instead of silently inheriting USE_CAMERA_PIPELINE=0.
synth_design -top Camera_Ethernet_Top -part xc7a50ticsg324-1L \
    -generic {USE_CAMERA_PIPELINE=1 USE_BYTE_FIFO_PATH=1 CAMERA_LINES_PER_FRAME=480}

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

connect_probe $ila_name 0  1 [exact_net rmii_tx_en_dbg]
connect_probe $ila_name 1  2 [exact_bus rmii_txd_dbg 2]
connect_probe $ila_name 2  1 [exact_net phy_ref_clk]
connect_probe $ila_name 3  8 [exact_bus frame_data 8]
connect_probe $ila_name 4  1 [exact_net frame_valid]
connect_probe $ila_name 5  1 [exact_net frame_ready]
connect_probe $ila_name 6  1 [exact_net frame_last]
connect_probe $ila_name 7  1 [exact_net frame_handshake]
connect_probe $ila_name 8  8 [exact_bus packet_data 8]
connect_probe $ila_name 9  1 [exact_net packet_valid]
connect_probe $ila_name 10 1 [exact_net packet_ready]
connect_probe $ila_name 11 1 [exact_net packet_last]
connect_probe $ila_name 12 1 [exact_net tx_error_underflow]
connect_probe $ila_name 13 1 [exact_net tx_fifo_overflow]
connect_probe $ila_name 14 1 [exact_net tx_fifo_good_frame]
connect_probe $ila_name 15 8 [exact_bus fixed_packet_data 8]
connect_probe $ila_name 16 1 [exact_net fixed_packet_valid]
connect_probe $ila_name 17 1 [exact_net fixed_packet_ready]
connect_probe $ila_name 18 1 [exact_net fixed_packet_last]
connect_probe $ila_name 19 16 [exact_bus byte_fifo_level 16]
connect_probe $ila_name 20 1 [exact_net byte_fifo_almost_full]
connect_probe $ila_name 21 1 [exact_net camera_pclk_dbg]
connect_probe $ila_name 22 1 [exact_net camera_href_dbg]
# The raw IBUF-to-IOB-register data nets cannot legally feed an ILA after the
# Camera input sampling registers are packed into IOBs.  Probe the immutable
# byte snapshot taken at the synchronized PCLK edge instead.
connect_probe $ila_name 23 8 \
    [exact_bus u_camera_pipeline/u_capture_0/data_on_pclk_rise 8]
connect_probe $ila_name 24 8 [exact_bus camera_packet_data 8]
connect_probe $ila_name 25 1 [exact_net camera_packet_valid]
connect_probe $ila_name 26 1 [exact_net camera_packet_ready]
connect_probe $ila_name 27 1 [exact_net camera_packet_last]
connect_probe $ila_name 28 4 [exact_bus camera_arb_grant 4]
connect_probe $ila_name 29 4 [exact_bus camera_overflow_pulse 4]
connect_probe $ila_name 30 12 [exact_bus camera_buffer_used_count 12]
connect_probe $ila_name 31 12 [exact_bus camera_buffer_committed_count 12]
connect_probe $ila_name 32 16 [exact_bus camera_packet_fifo_level 16]
connect_probe $ila_name 33 1 [exact_net camera_packet_fifo_almost_full]
connect_probe $ila_name 34 32 [exact_bus camera_drop_count_0 32]
connect_probe $ila_name 35 16 [exact_bus camera_current_byte_count_dbg 16]
connect_probe $ila_name 36 16 [exact_bus camera_last_line_byte_count_dbg 16]
connect_probe $ila_name 37 8 [exact_bus camera_line_flags_dbg 8]
connect_probe $ila_name 38 1 [exact_net camera_line_end_dbg]
connect_probe $ila_name 39 1 [exact_net camera_length_error_dbg]
connect_probe $ila_name 40 1 [exact_net camera_length_error_pulse_dbg]
connect_probe $ila_name 41 1 [exact_net camera_capture_byte_valid_dbg]

# Camera_Capture two-phase PCLK qualifier.  low_count accumulates low evidence
# across a one-cycle high runt; high_count must be consecutive after re-arm.
# These probes distinguish an ignored runt from an accepted byte event.
connect_probe $ila_name 42 2 \
    [exact_bus u_camera_pipeline/u_capture_0/pclk_low_count 2]
connect_probe $ila_name 43 2 \
    [exact_bus u_camera_pipeline/u_capture_0/pclk_high_count 2]
connect_probe $ila_name 44 1 \
    [exact_net u_camera_pipeline/u_capture_0/pclk_sync]
connect_probe $ila_name 45 1 \
    [exact_net u_camera_pipeline/u_capture_0/href_sync]
connect_probe $ila_name 46 8 \
    [exact_bus u_camera_pipeline/u_capture_0/data_sync 8]
connect_probe $ila_name 47 1 \
    [exact_net u_camera_pipeline/u_capture_0/pclk_pulse]
connect_probe $ila_name 48 1 \
    [exact_net u_camera_pipeline/u_capture_0/href_rise]
connect_probe $ila_name 49 1 \
    [exact_net u_camera_pipeline/u_capture_0/href_fall]

# Camera1 uses JC for D0..D7 and JD1/JD7 for PCLK/HREF.  These probes prove
# the second physical input, its synchronized view, arbitration/drop state and
# the SW15 capture-enable control without changing the functional data path.
connect_probe $ila_name 50 1 [exact_net camera1_pclk_dbg]
connect_probe $ila_name 51 1 [exact_net camera1_href_dbg]
connect_probe $ila_name 52 8 \
    [exact_bus u_camera_pipeline/u_capture_1/data_on_pclk_rise 8]
connect_probe $ila_name 53 32 [exact_bus camera_drop_count_1 32]
connect_probe $ila_name 54 1 [exact_net camera_enable_sync]
connect_probe $ila_name 55 1 [exact_net camera_pipeline_rst]
connect_probe $ila_name 56 1 \
    [exact_net u_camera_pipeline/u_capture_1/pclk_sync]
connect_probe $ila_name 57 1 \
    [exact_net u_camera_pipeline/u_capture_1/href_sync]
connect_probe $ila_name 58 8 \
    [exact_bus u_camera_pipeline/u_capture_1/data_sync 8]
connect_probe $ila_name 59 1 \
    [exact_net u_camera_pipeline/u_capture_1/pclk_pulse]

# Boundary-safe capture control and the byte snapshot associated with the first
# synchronized view of each PCLK edge.  These distinguish switch-boundary
# behavior from PCLK/data alignment failures.
connect_probe $ila_name 60 1 \
    [exact_net u_camera_pipeline/u_capture_0/capture_armed]
connect_probe $ila_name 61 1 \
    [exact_net u_camera_pipeline/u_capture_0/line_active]
connect_probe $ila_name 62 1 \
    [exact_net u_camera_pipeline/u_capture_0/line_end_pending]
connect_probe $ila_name 63 1 \
    [exact_net u_camera_pipeline/u_capture_0/pclk_phase_armed]

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

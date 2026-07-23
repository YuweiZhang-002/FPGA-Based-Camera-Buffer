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
synth_design -top Camera_Ethernet_Top -part xc7a50ticsg324-1L

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

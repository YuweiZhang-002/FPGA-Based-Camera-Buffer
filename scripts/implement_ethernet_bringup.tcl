set project_root [file normalize [file join [file dirname [info script]] ..]]
set report_dir  [file normalize [file join $project_root docs reports ethernet_bringup]]
set build_dir   [file normalize [file join $project_root build ethernet_bringup]]
file mkdir $report_dir
file mkdir $build_dir

open_project [file join $project_root prg_cam.xpr]
set_property top Camera_Ethernet_Top [get_filesets sources_1]
update_compile_order -fileset sources_1

generate_target all [get_ips ethernet_clk_wiz]
synth_ip -force [get_ips ethernet_clk_wiz]
synth_design -top Camera_Ethernet_Top -part xc7a50ticsg324-1L
opt_design
place_design
phys_opt_design
route_design

report_methodology -file [file join $report_dir post_route_methodology.rpt]
report_cdc -details -file [file join $report_dir post_route_cdc.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_utilization -file [file join $report_dir post_route_utilization.rpt]
report_route_status -file [file join $report_dir post_route_status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -file [file join $report_dir post_route_timing_summary.rpt]
write_checkpoint -force [file join $build_dir Camera_Ethernet_Top_routed.dcp]

set setup_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set hold_path  [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
set setup_slack [get_property SLACK $setup_path]
set hold_slack  [get_property SLACK $hold_path]

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == "Critical Warning"}]

puts "ETHERNET_BRINGUP_IMPLEMENTATION_COMPLETE"
puts "ETHERNET_BRINGUP_SETUP_SLACK_NS: $setup_slack"
puts "ETHERNET_BRINGUP_HOLD_SLACK_NS: $hold_slack"
puts "ETHERNET_BRINGUP_DRC_ERROR_OR_CRITICAL_COUNT: [llength $drc_errors]"

if {$setup_slack < 0 || $hold_slack < 0 || [llength $drc_errors] != 0} {
    error "Ethernet bring-up implementation does not meet timing/DRC acceptance; inspect $report_dir"
}

puts "ETHERNET_BRINGUP_IMPLEMENTATION_PASS"

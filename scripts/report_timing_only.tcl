set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set dcp_file [file normalize \
    [file join $project_root build ethernet_ila Camera_Ethernet_Top_ila_routed.dcp]]
set report_file [file normalize \
    [file join $project_root build ethernet_ila timing_summary.txt]]

if {![file exists $dcp_file]} {
    error "Routed ILA checkpoint not found: $dcp_file"
}

open_checkpoint $dcp_file
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file $report_file
puts "ILA_TIMING_REPORT=$report_file"
close_design
exit

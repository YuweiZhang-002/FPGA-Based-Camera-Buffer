set project_root [file normalize [file join [file dirname [info script]] ..]]
set report_dir  [file normalize [file join $project_root docs reports ethernet_bringup]]
file mkdir $report_dir

open_project [file join $project_root prg_cam.xpr]
set_property top Camera_Ethernet_Top [get_filesets sources_1]
update_compile_order -fileset sources_1

# generate_target creates the wrapper/stub; synth_ip creates the OOC DCP that
# project-mode synth_design consumes for the Clock Wizard instance.
generate_target all [get_ips ethernet_clk_wiz]
synth_ip -force [get_ips ethernet_clk_wiz]

synth_design -top Camera_Ethernet_Top -part xc7a50ticsg324-1L

report_methodology -file [file join $report_dir post_synth_methodology.rpt]
report_cdc -details -file [file join $report_dir post_synth_cdc.rpt]
report_drc -file [file join $report_dir post_synth_drc.rpt]
report_utilization -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -file [file join $report_dir post_synth_timing_summary.rpt]

set unconstrained_ports {}
foreach port [get_ports] {
    if {[get_property PACKAGE_PIN $port] eq "" || [get_property IOSTANDARD $port] eq "DEFAULT"} {
        lappend unconstrained_ports [get_property NAME $port]
    }
}
if {[llength $unconstrained_ports] != 0} {
    error "Unconstrained top-level ports: $unconstrained_ports"
}

puts "ETHERNET_BRINGUP_SYNTH_PASS"
puts "ETHERNET_BRINGUP_PORT_COUNT: [llength [get_ports]]"
puts "ETHERNET_BRINGUP_UNCONSTRAINED_PORT_COUNT: [llength $unconstrained_ports]"

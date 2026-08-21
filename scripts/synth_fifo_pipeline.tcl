set root_dir [file normalize [file join [file dirname [info script]] ..]]
set rtl_dir  [file join $root_dir prg_cam.srcs sources_1 new]

set crc_enable 1
if {[llength $argv] > 0} {
    set crc_enable [lindex $argv 0]
}
if {$crc_enable ni {0 1}} {
    error "CRC_ENABLE must be 0 (placeholder) or 1 (CRC-16)"
}
set crc_mode [expr {$crc_enable ? "enabled" : "placeholder"}]
set report_prefix [file join $root_dir reports fifo_pipeline_crc_$crc_mode]

create_project fifo_pipeline_check -in_memory -part xc7a50ticsg324-1L
read_verilog [list \
    [file join $rtl_dir Camera_Capture.v] \
    [file join $rtl_dir Alarmer.v] \
    [file join $rtl_dir Line_Buffer.v] \
    [file join $rtl_dir Byte_Replacer.v] \
    [file join $rtl_dir Byte_FIFO.v] \
    [file join $rtl_dir Arbitration.v] \
    [file join $rtl_dir Camera_Pipeline.v]]

synth_design -top Camera_Pipeline -part xc7a50ticsg324-1L \
    -mode out_of_context \
    -generic [list CRC_ENABLE=$crc_enable INGRESS_CRC_ENABLE=1]
create_clock -name sys_clk -period 10.000 [get_ports sys_clk]

report_utilization -file ${report_prefix}_utilization.rpt
report_timing_summary -file ${report_prefix}_timing.rpt
check_timing -verbose -file ${report_prefix}_check_timing.rpt

set worst_path [get_timing_paths -delay_type max -max_paths 1 -quiet]
if {[llength $worst_path] > 0} {
    puts "FIFO_PIPELINE_WNS_NS=[get_property SLACK $worst_path]"
}
puts "FIFO_PIPELINE_SYNTHESIS_PASS CRC_ENABLE=$crc_enable MODE=$crc_mode INGRESS_CRC_ENABLE=1"
exit

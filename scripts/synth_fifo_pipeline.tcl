set root_dir [file normalize [file join [file dirname [info script]] ..]]
set rtl_dir  [file join $root_dir prg_cam.srcs sources_1 new]

create_project fifo_pipeline_check -in_memory -part xc7a50ticsg324-1L
read_verilog [list \
    [file join $rtl_dir Camera_Capture.v] \
    [file join $rtl_dir Alarmer.v] \
    [file join $rtl_dir Line_Buffer.v] \
    [file join $rtl_dir Byte_Replacer.v] \
    [file join $rtl_dir Byte_FIFO.v] \
    [file join $rtl_dir Arbitration.v] \
    [file join $rtl_dir Camera_Pipeline.v]]

synth_design -top Camera_Pipeline -part xc7a50ticsg324-1L -mode out_of_context
create_clock -name sys_clk -period 10.000 [get_ports sys_clk]

report_utilization -file [file join $root_dir fifo_pipeline_utilization.rpt]
report_timing_summary -file [file join $root_dir fifo_pipeline_timing.rpt]
check_timing -verbose -file [file join $root_dir fifo_pipeline_check_timing.rpt]

puts "FIFO_PIPELINE_SYNTHESIS_PASS"
exit

# Add the explicit TX-first Ethernet integration files.  No recursive source
# loading, network access, remove_files, or generated-directory cleanup occurs.

set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_xpr  [file join $project_root prg_cam.xpr]

if {[llength [get_projects -quiet]] == 0} {
    open_project $project_xpr
}

set rtl_files [list \
    [file normalize [file join $project_root prg_cam.srcs sources_1 new Ethernet_Frame_Adapter.sv]] \
    [file normalize [file join $project_root prg_cam.srcs sources_1 new Fixed_Packet_Generator.sv]] \
    [file normalize [file join $project_root prg_cam.srcs sources_1 new Taxi_Ethernet_Subsystem.sv]] \
    [file normalize [file join $project_root prg_cam.srcs sources_1 new Ethernet_Mii_Rmii_Bridge.sv]] \
    [file normalize [file join $project_root prg_cam.srcs sources_1 new Camera_Ethernet_Top.sv]] \
    [file normalize [file join $project_root prg_cam.srcs sources_1 lib FPGA-RMII-SMII-main RTL rmii_phy_if.v]]]

set xdc_file [file normalize [file join $project_root prg_cam.srcs constrs_1 new nexys_a7_ethernet.xdc]]
set clk_xci  [file normalize [file join $project_root prg_cam.srcs sources_1 ip ethernet_clk_wiz ethernet_clk_wiz.xci]]

foreach path [concat $rtl_files [list $xdc_file $clk_xci]] {
    if {![file exists $path]} {
        error "Required local integration file is missing: $path"
    }
}

set source_add {}
foreach path $rtl_files {
    if {[llength [get_files -quiet $path]] == 0} {
        lappend source_add $path
    }
}
if {[llength [get_files -quiet $clk_xci]] == 0} {
    lappend source_add $clk_xci
}
if {[llength $source_add] != 0} {
    add_files -fileset sources_1 -norecurse $source_add
}

if {[llength [get_files -quiet $xdc_file]] == 0} {
    add_files -fileset constrs_1 -norecurse $xdc_file
}

set sv_files {}
foreach path $rtl_files {
    if {[string equal -nocase [file extension $path] ".sv"]} {
        lappend sv_files $path
    }
}
set_property file_type SystemVerilog [get_files $sv_files]
set_property top Camera_Ethernet_Top [get_filesets sources_1]

generate_target all [get_files $clk_xci]
update_compile_order -fileset sources_1

set compile_report [file normalize [file join $project_root docs ethernet_bringup_compile_order.rpt]]
set missing_report [file normalize [file join $project_root docs ethernet_bringup_missing_instances.rpt]]
report_compile_order -of_objects [get_filesets sources_1] -used_in synthesis -file $compile_report
report_compile_order -of_objects [get_filesets sources_1] -used_in synthesis -missing_instances -file $missing_report

set fh [open $missing_report r]
set missing_text [read $fh]
close $fh
if {![regexp -nocase {<\s*empty\s*>} $missing_text]} {
    error "Unresolved integration references reported: $missing_report"
}

puts "ETHERNET_BRINGUP_SOURCE_ADD_PASS"
puts "ETHERNET_BRINGUP_TOP: [get_property top [get_filesets sources_1]]"
puts "ETHERNET_BRINGUP_RTL_COUNT: [llength $rtl_files]"
puts "ETHERNET_BRINGUP_XDC: [string map {\\ /} $xdc_file]"


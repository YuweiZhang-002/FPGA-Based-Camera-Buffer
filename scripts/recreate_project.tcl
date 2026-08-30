# Recreate the public GUI project from authored sources and pinned external
# dependencies.  Generated runs are not inputs.  Git history remains the
# recovery mechanism for the previous project file.

set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_name prg_cam
set validation_root [file join $project_root build project_recreate_validation]
set validation_xpr [file join $validation_root ${project_name}.xpr]
set part xc7a50ticsg324-1L

set first_party_rtl [list \
    [file join $project_root prg_cam.srcs sources_1 new Arbitration.v] \
    [file join $project_root prg_cam.srcs sources_1 new Byte_FIFO.v] \
    [file join $project_root prg_cam.srcs sources_1 new Byte_Replacer.v] \
    [file join $project_root prg_cam.srcs sources_1 new Camera_Capture.v] \
    [file join $project_root prg_cam.srcs sources_1 new Camera_Pipeline.v] \
    [file join $project_root prg_cam.srcs sources_1 new Line_Buffer.v] \
    [file join $project_root prg_cam.srcs sources_1 new Ethernet_Frame_Adapter.sv] \
    [file join $project_root prg_cam.srcs sources_1 new Ethernet_Mii_Rmii_Bridge.sv] \
    [file join $project_root prg_cam.srcs sources_1 new Fixed_Packet_Generator.sv] \
    [file join $project_root prg_cam.srcs sources_1 new Taxi_Ethernet_Subsystem.sv] \
    [file join $project_root prg_cam.srcs sources_1 new Camera_Ethernet_Top.sv]]
set rmii_file [file join $project_root third_party FPGA-RMII-SMII RTL rmii_phy_if.v]
set taxi_entry [file join $project_root third_party taxi src eth rtl taxi_eth_mac_mii_fifo.f]
set authored_xdc_file [file join \
    $project_root prg_cam.srcs constrs_1 new nexys_a7_ethernet.xdc]
set generated_constraint_root [file join $validation_root constraints]
set xdc_file [file join $generated_constraint_root nexys_a7_ethernet.xdc]
set sim_files [lsort [glob -nocomplain \
    [file join $project_root prg_cam.srcs sim_1 new *.sv]]]

foreach required [concat $first_party_rtl \
    [list $rmii_file $taxi_entry $authored_xdc_file]] {
    if {![file exists $required]} {
        error "PROJECT_RECREATE_PRECHECK_MISSING: $required"
    }
}
if {[llength $sim_files] == 0} {
    error "PROJECT_RECREATE_PRECHECK_MISSING: simulation sources"
}

file mkdir $validation_root
file mkdir $generated_constraint_root
file mkdir [file join $validation_root ${project_name}.gen sources_1]
file copy -force $authored_xdc_file $xdc_file
create_project -force $project_name $validation_root -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -fileset sources_1 -norecurse [concat $first_party_rtl [list $rmii_file]]
set sv_files {}
foreach path $first_party_rtl {
    if {[string equal -nocase [file extension $path] ".sv"]} {
        lappend sv_files $path
    }
}
set_property file_type SystemVerilog [get_files $sv_files]
add_files -fileset constrs_1 -norecurse $xdc_file

set_property top Camera_Ethernet_Top [get_filesets sources_1]
set_property generic [list \
    USE_CAMERA_PIPELINE=1 \
    USE_BYTE_FIFO_PATH=1 \
    ENABLE_CAM1=1 \
    CAMERA_CRC_ENABLE=1 \
    CAMERA_INGRESS_CRC_ENABLE=1 \
    CAMERA_LINES_PER_FRAME=480] [get_filesets sources_1]

source [file join $project_root scripts create_ethernet_clock_ip.tcl]
source [file join $project_root scripts add_taxi_sources.tcl]

add_files -fileset sim_1 -norecurse $sim_files
set_property file_type SystemVerilog [get_files $sim_files]
set_property top tb_Fixed_Frame_Taxi_Rmii [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set source_report_root [file join $project_root build source_closure_reports]
file mkdir $source_report_root
set missing_report [file join $source_report_root project_source_missing_instances.rpt]
report_compile_order -of_objects [get_filesets sources_1] -used_in synthesis \
    -missing_instances -file $missing_report
set fh [open $missing_report r]
set missing_text [read $fh]
close $fh
if {![regexp -nocase {<\s*empty\s*>} $missing_text]} {
    error "PROJECT_RECREATE_UNRESOLVED: $missing_report"
}

puts "PROJECT_RECREATE_RESULT=PASS"
puts "PROJECT_RECREATE_XPR=$validation_xpr"
puts "PROJECT_RECREATE_RTL_COUNT=[llength $first_party_rtl]"
puts "PROJECT_RECREATE_SIM_COUNT=[llength $sim_files]"
close_project

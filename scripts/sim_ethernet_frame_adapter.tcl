set root_dir       [file normalize [file join [file dirname [info script]] ..]]
set rtl_file       [file join $root_dir prg_cam.srcs sources_1 new Ethernet_Frame_Adapter.sv]
set tb_file        [file join $root_dir prg_cam.srcs sim_1 new tb_Ethernet_Frame_Adapter.sv]
set sim_project_dir [file join $root_dir build ethernet_frame_adapter_sim]
set sim_project_xpr [file join $sim_project_dir ethernet_frame_adapter_sim.xpr]

if {[file exists $sim_project_xpr]} {
    open_project $sim_project_xpr
} else {
    create_project ethernet_frame_adapter_sim $sim_project_dir -part xc7a50ticsg324-1L
}
add_files -fileset sources_1 $rtl_file
add_files -fileset sim_1 $tb_file
set_property file_type SystemVerilog [get_files [list $rtl_file $tb_file]]
set_property top tb_Ethernet_Frame_Adapter [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
close_sim

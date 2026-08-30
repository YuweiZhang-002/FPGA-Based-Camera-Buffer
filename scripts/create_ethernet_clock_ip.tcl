set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_xpr [file join $project_root prg_cam.xpr]
set ip_dir [file normalize [file join $project_root prg_cam.srcs sources_1 ip]]
set ip_xci [file join $ip_dir ethernet_clk_wiz ethernet_clk_wiz.xci]
file mkdir $ip_dir

if {[llength [get_projects -quiet]] == 0} {
    open_project $project_xpr
}

if {[llength [get_ips -quiet ethernet_clk_wiz]] == 0} {
    if {[file exists $ip_xci]} {
        add_files -fileset sources_1 -norecurse $ip_xci
    } else {
        create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
            -module_name ethernet_clk_wiz -dir $ip_dir
    }
}

set ip [get_ips -quiet ethernet_clk_wiz]
if {[llength $ip] != 1} {
    error "Expected exactly one ethernet_clk_wiz IP, found [llength $ip]"
}
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.PRIMARY_PORT {sys_clk} \
    CONFIG.PRIM_SOURCE {Global_buffer} \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000} \
    CONFIG.CLKOUT1_REQUESTED_PHASE {0.000} \
    CONFIG.CLK_OUT1_PORT {rmii_ref_clk} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {50.000} \
    CONFIG.CLKOUT2_REQUESTED_PHASE {45.000} \
    CONFIG.CLK_OUT2_PORT {phy_ref_clk} \
    CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_HIGH} \
    CONFIG.RESET_PORT {reset} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.LOCKED_PORT {locked}] $ip

generate_target all $ip

puts "ETHERNET_CLK_IP_CONFIG:"
foreach prop {
    CONFIG.PRIM_IN_FREQ
    CONFIG.PRIMARY_PORT
    CONFIG.PRIM_SOURCE
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ
    CONFIG.CLKOUT1_REQUESTED_PHASE
    CONFIG.CLK_OUT1_PORT
    CONFIG.CLKOUT2_USED
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ
    CONFIG.CLKOUT2_REQUESTED_PHASE
    CONFIG.CLK_OUT2_PORT
    CONFIG.RESET_PORT
    CONFIG.LOCKED_PORT
} {
    puts "$prop=[get_property $prop $ip]"
}

puts "ETHERNET_CLK_IP_GENERATED_FILES:"
foreach path [get_files -quiet -of_objects $ip] {
    puts [string map {\\ /} [file normalize $path]]
}

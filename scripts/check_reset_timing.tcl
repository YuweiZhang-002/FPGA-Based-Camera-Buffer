set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set dcp_file [file normalize \
    [file join $project_root build ethernet_bringup Camera_Ethernet_Top_routed.dcp]]
set report_dir [file normalize [file join $project_root build ethernet_bringup]]

open_checkpoint $dcp_file

proc direct_load_count {cell_name} {
    set q_pin [get_pins -quiet ${cell_name}/Q]
    if {[llength $q_pin] != 1} {
        return -1
    }
    set driven_net [get_nets -quiet -of_objects $q_pin]
    return [llength [get_pins -quiet -leaf -of_objects $driven_net \
        -filter {DIRECTION == IN}]]
}

foreach reset_cell {
    phy_ready_reg
    source_rst_reg_reg
    camera_rst_reg_reg
    frame_rst_reg_reg
    bridge_rst_reg_reg
    taxi_logic_rst_reg_reg
    taxi_mac_rst_reg_reg
} {
    puts "RESET_DIRECT_LOADS $reset_cell [direct_load_count $reset_cell]"
}

set taxi_mii_tx_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/*/tx_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]
set taxi_fifo_m_reset_pins [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/tx_fifo/fifo_inst/m_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]

puts "TAXI_MII_TX_ASYNC_RESET_PRE_COUNT [llength $taxi_mii_tx_reset_pins]"
puts "TAXI_FIFO_M_ASYNC_RESET_PRE_COUNT [llength $taxi_fifo_m_reset_pins]"

# Do not use get_timing_paths count as proof that a false path is inactive:
# Vivado can return ignored paths when an exception is queried explicitly.
# report_exceptions -coverage and the timing summary "User Ignored Paths"
# table are the authoritative checks.

report_exceptions -coverage -file \
    [file join $report_dir reset_exception_coverage.rpt]
close_design

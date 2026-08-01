# Clock/reset and Ethernet pins copied from the local Digilent
# Nexys-A7-50T-Master.xdc.  Only the leading comment markers were removed.

set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]; #IO_L12P_T1_MRCC_35 Sch=clk100mhz
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports {CLK100MHZ}];
set_property -dict { PACKAGE_PIN C12   IOSTANDARD LVCMOS33 } [get_ports { CPU_RESETN }]; #IO_L3P_T0_DQS_AD1P_15 Sch=cpu_resetn

# Camera/MCU receive connector mapping copied from the JA/JB entries in the
# local Nexys-A7-50T Master XDC.  GPIO[8] is PCLK and GPIO[9] is HREF.
# The source PCLK frequency has not been established in this repository, so a
# create_clock constraint must be added only after its period is measured.
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 } [get_ports { GPIO[0] }]; # JA1  D0
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { GPIO[1] }]; # JA2  D1
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS33 } [get_ports { GPIO[2] }]; # JA3  D2
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { GPIO[3] }]; # JA4  D3
set_property -dict { PACKAGE_PIN D17   IOSTANDARD LVCMOS33 } [get_ports { GPIO[4] }]; # JA7  D4
set_property -dict { PACKAGE_PIN E17   IOSTANDARD LVCMOS33 } [get_ports { GPIO[5] }]; # JA8  D5
set_property -dict { PACKAGE_PIN F18   IOSTANDARD LVCMOS33 } [get_ports { GPIO[6] }]; # JA9  D6
set_property -dict { PACKAGE_PIN G18   IOSTANDARD LVCMOS33 } [get_ports { GPIO[7] }]; # JA10 D7
set_property -dict { PACKAGE_PIN D14   IOSTANDARD LVCMOS33 } [get_ports { GPIO[8] }]; # JB1  PCLK
set_property -dict { PACKAGE_PIN E16   IOSTANDARD LVCMOS33 } [get_ports { GPIO[9] }]; # JB7  HREF

# Camera1 receive interface.  Direction is RP2350A/Camera output -> FPGA input,
# matching the input-only GPIO_CAM1 port in Camera_Ethernet_Top.sv.  Pin names
# and package pins are copied from the local Nexys-A7-50T-Master.xdc.
# JC carries the complete 8-bit data bus in ascending logical-bit order.
set_property -dict { PACKAGE_PIN K1    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[0] }]; # JC1  Camera D0 output -> FPGA input
set_property -dict { PACKAGE_PIN F6    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[1] }]; # JC2  Camera D1 output -> FPGA input
set_property -dict { PACKAGE_PIN J2    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[2] }]; # JC3  Camera D2 output -> FPGA input
set_property -dict { PACKAGE_PIN G6    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[3] }]; # JC4  Camera D3 output -> FPGA input
set_property -dict { PACKAGE_PIN E7    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[4] }]; # JC7  Camera D4 output -> FPGA input
set_property -dict { PACKAGE_PIN J3    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[5] }]; # JC8  Camera D5 output -> FPGA input
set_property -dict { PACKAGE_PIN J4    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[6] }]; # JC9  Camera D6 output -> FPGA input
set_property -dict { PACKAGE_PIN E6    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[7] }]; # JC10 Camera D7 output -> FPGA input

# JD1 is the Camera/RP2350A PCLK input.  JD7 is HREF (line-valid timing input),
# not a second free-running clock.  Camera_Capture synchronizes both into the
# 100 MHz logic domain; no create_clock is asserted until PCLK is measured.
set_property -dict { PACKAGE_PIN H4    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[8] }]; # JD1 PCLK output -> FPGA input
set_property -dict { PACKAGE_PIN H2    IOSTANDARD LVCMOS33 } [get_ports { GPIO_CAM1[9] }]; # JD7 HREF output -> FPGA input

# The physical right-most slide switch is SW15 on package pin V10.  J15 is
# SW0 in the Digilent Master XDC and is deliberately not used here.
set_property -dict { PACKAGE_PIN V10   IOSTANDARD LVCMOS33 } \
    [get_ports { CAMERA_CAPTURE_ENABLE }]; # SW15, high=capture enabled

set_property -dict { PACKAGE_PIN C9    IOSTANDARD LVCMOS33 } [get_ports { ETH_MDC }]; #IO_L11P_T1_SRCC_16 Sch=eth_mdc
set_property -dict { PACKAGE_PIN A9    IOSTANDARD LVCMOS33 } [get_ports { ETH_MDIO }]; #IO_L14N_T2_SRCC_16 Sch=eth_mdio
set_property -dict { PACKAGE_PIN B3    IOSTANDARD LVCMOS33 } [get_ports { ETH_RSTN }]; #IO_L10P_T1_AD15P_35 Sch=eth_rstn
set_property -dict { PACKAGE_PIN D9    IOSTANDARD LVCMOS33 } [get_ports { ETH_CRSDV }]; #IO_L6N_T0_VREF_16 Sch=eth_crsdv
set_property -dict { PACKAGE_PIN C10   IOSTANDARD LVCMOS33 } [get_ports { ETH_RXERR }]; #IO_L13N_T2_MRCC_16 Sch=eth_rxerr
set_property -dict { PACKAGE_PIN C11   IOSTANDARD LVCMOS33 } [get_ports { ETH_RXD[0] }]; #IO_L13P_T2_MRCC_16 Sch=eth_rxd[0]
set_property -dict { PACKAGE_PIN D10   IOSTANDARD LVCMOS33 } [get_ports { ETH_RXD[1] }]; #IO_L19N_T3_VREF_16 Sch=eth_rxd[1]
set_property -dict { PACKAGE_PIN B9    IOSTANDARD LVCMOS33 } [get_ports { ETH_TXEN }]; #IO_L11N_T1_SRCC_16 Sch=eth_txen
set_property -dict { PACKAGE_PIN A10   IOSTANDARD LVCMOS33 } [get_ports { ETH_TXD[0] }]; #IO_L14P_T2_SRCC_16 Sch=eth_txd[0]
set_property -dict { PACKAGE_PIN A8    IOSTANDARD LVCMOS33 } [get_ports { ETH_TXD[1] }]; #IO_L12N_T1_MRCC_16 Sch=eth_txd[1]
set_property -dict { PACKAGE_PIN D5    IOSTANDARD LVCMOS33 } [get_ports { ETH_REFCLK }]; #IO_L11P_T1_SRCC_35 Sch=eth_refclk
set_property -dict { PACKAGE_PIN B8    IOSTANDARD LVCMOS33 } [get_ports { ETH_INTN }]; #IO_L12P_T1_MRCC_16 Sch=eth_intn

# Forwarded RMII clock and PHY transmit timing.  The Nexys A7 LAN8720A is
# strapped for REF_CLK input mode.  It captures TXD[1:0]/TXEN on CLKIN rising
# edges and requires 4.0 ns setup and 1.5 ns hold.  ETH_REFCLK is generated by
# an ODDR with D1=1/D2=0; the explicit generated clock makes the board-level
# relationship visible to static timing.  A negative -min value models the
# receiver's positive hold requirement.
create_generated_clock -name eth_refclk_out \
    -source [get_pins {u_eth_refclk_oddr/C}] \
    -divide_by 1 \
    [get_ports {ETH_REFCLK}]

set_output_delay -clock [get_clocks {eth_refclk_out}] -max  4.000 \
    [get_ports {ETH_TXEN ETH_TXD[*]}]
set_output_delay -clock [get_clocks {eth_refclk_out}] -min -1.500 \
    [get_ports {ETH_TXEN ETH_TXD[*]}]

# rmii_phy_if toggles these registers at every 50 MHz reference-clock edge in
# 100-Mbit mode, producing the 25 MHz MII clocks consumed by Taxi.  Constrain
# the actual synthesized register pins; these names were verified in the
# post-synthesis netlist generated by Vivado 2025.2.1.
create_generated_clock -name mii_tx_clk -source [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_txc_reg/C}] -divide_by 2 [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_txc_reg/Q}]
create_generated_clock -name mii_rx_clk -source [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_rxc_reg/C}] -divide_by 2 [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_rxc_reg/Q}]

# Taxi reset synchronizers implement asynchronous assertion followed by a
# four-cycle synchronous release.  The asynchronous reset input therefore is
# intentionally not a synchronous sys_clk-to-mii_tx_clk data path.  Cut only
# the PRE pins of the two synchronizers fed by the top-level Taxi MAC reset:
#   1) MII TX reset synchronizer (4 registers)
#   2) TX async-FIFO read-domain reset synchronizer (4 registers)
# Keeping this target list narrow avoids masking ordinary AXIS or MII CDC paths.
set_false_path -to [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/*/tx_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]

set_false_path -to [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter \
        {NAME =~ */u_taxi_eth_mac_mii_fifo/tx_fifo/fifo_inst/m_reset_sync_inst/sync_reg_reg*}] \
    -filter {REF_PIN_NAME == PRE}]

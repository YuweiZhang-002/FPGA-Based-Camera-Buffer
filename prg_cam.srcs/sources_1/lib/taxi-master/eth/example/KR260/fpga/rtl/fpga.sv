// SPDX-License-Identifier: MIT
/*

Copyright (c) 2025 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * FPGA top-level module
 */
module fpga #
(
    // simulation (set to avoid vendor primitives)
    parameter logic SIM = 1'b0,
    // vendor ("GENERIC", "XILINX", "ALTERA")
    parameter string VENDOR = "XILINX",
    // device family
    parameter string FAMILY = "zynquplus",
    // Use 90 degree clock for RGMII transmit
    parameter logic USE_CLK90 = 1'b1,
    // SFP rate selection (0 for 1G, 1 for 10G)
    parameter logic SFP_RATE = 1'b1
)
(
    /*
     * Clock: 25MHz
     */
    input  wire logic        clk_25mhz,

    /*
     * GPIO
     */
    output wire logic [1:0]  led,
    output wire logic [1:0]  sfp_led,

    /*
     * Ethernet: 1000BASE-T RGMII
     */
    input  wire logic        phy2_rx_clk,
    input  wire logic [3:0]  phy2_rxd,
    input  wire logic        phy2_rx_ctl,
    output wire logic        phy2_tx_clk,
    output wire logic [3:0]  phy2_txd,
    output wire logic        phy2_tx_ctl,
    output wire logic        phy2_reset_n,

    input  wire logic        phy3_rx_clk,
    input  wire logic [3:0]  phy3_rxd,
    input  wire logic        phy3_rx_ctl,
    output wire logic        phy3_tx_clk,
    output wire logic [3:0]  phy3_txd,
    output wire logic        phy3_tx_ctl,
    output wire logic        phy3_reset_n,

    /*
     * Ethernet: SFP+
     */
    input  wire logic        sfp_rx_p,
    input  wire logic        sfp_rx_n,
    output wire logic        sfp_tx_p,
    output wire logic        sfp_tx_n,
    input  wire logic        sfp_mgt_refclk_p,
    input  wire logic        sfp_mgt_refclk_n,

    output wire logic        sfp_tx_disable,
    input  wire logic        sfp_tx_fault,
    input  wire logic        sfp_rx_los,
    input  wire logic        sfp_mod_abs,
    inout  wire logic        sfp_i2c_scl,
    inout  wire logic        sfp_i2c_sda
);

// Clock and reset

// Internal 125 MHz clock
wire clk_125mhz_mmcm_out;
wire clk90_125mhz_mmcm_out;
wire clk_125mhz_int;
wire clk90_125mhz_int;
wire rst_125mhz_int;

// Internal 62.5 MHz clock
wire clk_62mhz_mmcm_out;
wire clk_62mhz_int;

// Internal 312.5 MHz clock
wire clk_312mhz_mmcm_out;
wire clk_312mhz_int;
wire rst_312mhz_int;

wire mmcm_rst = 1'b0;
wire mmcm_locked;
wire mmcm_clkfb;

// MMCM instance
MMCME4_BASE #(
    // 25 MHz input
    .CLKIN1_PERIOD(40),
    .REF_JITTER1(0.010),
    // 25 MHz input / 1 = 25 MHz PFD (range 10 MHz to 500 MHz)
    .DIVCLK_DIVIDE(1),
    // 25 MHz PFD * 50 = 1250 MHz VCO (range 800 MHz to 1600 MHz)
    .CLKFBOUT_MULT_F(50),
    .CLKFBOUT_PHASE(0),
    // 1250 MHz / 10 = 125 MHz, 0 degrees
    .CLKOUT0_DIVIDE_F(10),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0),
    // 1250 MHz / 10 = 125 MHz, 90 degrees
    .CLKOUT1_DIVIDE(10),
    .CLKOUT1_DUTY_CYCLE(0.5),
    .CLKOUT1_PHASE(90),
    // 1250 MHz / 20 = 62.5 MHz, 0 degrees
    .CLKOUT2_DIVIDE(20),
    .CLKOUT2_DUTY_CYCLE(0.5),
    .CLKOUT2_PHASE(0),
    // 1250 MHz / 4 = 312.5 MHz, 0 degrees
    .CLKOUT3_DIVIDE(4),
    .CLKOUT3_DUTY_CYCLE(0.5),
    .CLKOUT3_PHASE(0),
    // Not used
    .CLKOUT4_DIVIDE(1),
    .CLKOUT4_DUTY_CYCLE(0.5),
    .CLKOUT4_PHASE(0),
    .CLKOUT4_CASCADE("FALSE"),
    // Not used
    .CLKOUT5_DIVIDE(1),
    .CLKOUT5_DUTY_CYCLE(0.5),
    .CLKOUT5_PHASE(0),
    // Not used
    .CLKOUT6_DIVIDE(1),
    .CLKOUT6_DUTY_CYCLE(0.5),
    .CLKOUT6_PHASE(0),

    // optimized bandwidth
    .BANDWIDTH("OPTIMIZED"),
    // don't wait for lock during startup
    .STARTUP_WAIT("FALSE")
)
clk_mmcm_inst (
    // 25 MHz input
    .CLKIN1(clk_25mhz),
    // direct clkfb feeback
    .CLKFBIN(mmcm_clkfb),
    .CLKFBOUT(mmcm_clkfb),
    .CLKFBOUTB(),
    // 125 MHz, 0 degrees
    .CLKOUT0(clk_125mhz_mmcm_out),
    .CLKOUT0B(),
    // 125 MHz, 90 degrees
    .CLKOUT1(clk90_125mhz_mmcm_out),
    .CLKOUT1B(),
    // 62.5 MHz, 0 degrees
    .CLKOUT2(clk_62mhz_mmcm_out),
    .CLKOUT2B(),
    // 312.5 MHz, 0 degrees
    .CLKOUT3(clk_312mhz_mmcm_out),
    .CLKOUT3B(),
    // Not used
    .CLKOUT4(),
    // Not used
    .CLKOUT5(),
    // Not used
    .CLKOUT6(),
    // reset input
    .RST(mmcm_rst),
    // don't power down
    .PWRDWN(1'b0),
    // locked output
    .LOCKED(mmcm_locked)
);

BUFG
clk_125mhz_bufg_inst (
    .I(clk_125mhz_mmcm_out),
    .O(clk_125mhz_int)
);

BUFG
clk90_125mhz_bufg_inst (
    .I(clk90_125mhz_mmcm_out),
    .O(clk90_125mhz_int)
);

BUFG
clk_62mhz_bufg_inst (
    .I(clk_62mhz_mmcm_out),
    .O(clk_62mhz_int)
);

BUFG
clk_312mhz_bufg_inst (
    .I(clk_312mhz_mmcm_out),
    .O(clk_312mhz_int)
);

taxi_sync_reset #(
    .N(4)
)
sync_reset_125mhz_inst (
    .clk(clk_125mhz_int),
    .rst(~mmcm_locked),
    .out(rst_125mhz_int)
);

taxi_sync_reset #(
    .N(4)
)
sync_reset_312mhz_inst (
    .clk(clk_312mhz_int),
    .rst(~mmcm_locked),
    .out(rst_312mhz_int)
);

// GPIO
wire sfp_tx_fault_int;
wire sfp_rx_los_int;
wire sfp_mod_abs_int;

wire sfp_i2c_scl_i;
wire sfp_i2c_scl_o;
wire sfp_i2c_scl_t;
wire sfp_i2c_sda_i;
wire sfp_i2c_sda_o;
wire sfp_i2c_sda_t;

reg sfp_i2c_scl_o_reg;
reg sfp_i2c_scl_t_reg;
reg sfp_i2c_sda_o_reg;
reg sfp_i2c_sda_t_reg;

always @(posedge clk_125mhz_int) begin
    sfp_i2c_scl_o_reg <= sfp_i2c_scl_o;
    sfp_i2c_scl_t_reg <= sfp_i2c_scl_t;
    sfp_i2c_sda_o_reg <= sfp_i2c_sda_o;
    sfp_i2c_sda_t_reg <= sfp_i2c_sda_t;
end

taxi_sync_signal #(
    .WIDTH(5),
    .N(2)
)
sync_signal_inst (
    .clk(clk_125mhz_int),
    .in({sfp_tx_fault, sfp_rx_los, sfp_mod_abs, sfp_i2c_scl, sfp_i2c_sda}),
    .out({sfp_tx_fault_int, sfp_rx_los_int, sfp_mod_abs_int, sfp_i2c_scl_i, sfp_i2c_sda_i})
);

assign sfp_i2c_scl = sfp_i2c_scl_t_reg ? 1'bz : sfp_i2c_scl_o_reg;
assign sfp_i2c_sda = sfp_i2c_sda_t_reg ? 1'bz : sfp_i2c_sda_o_reg;

// IODELAY elements for RGMII interface to PHY
wire [3:0] phy2_rxd_int;
wire phy2_rx_ctl_int;

wire [3:0] phy3_rxd_int;
wire phy3_rx_ctl_int;

IDELAYCTRL #(
    .SIM_DEVICE("ULTRASCALE")
)
idelayctrl_inst (
    .REFCLK(clk_312mhz_int),
    .RST(rst_312mhz_int),
    .RDY()
);

for (genvar n = 0; n < 4; n = n + 1) begin : phy2_rxd_idelay_bit
    
    IDELAYE3 #(
        .DELAY_SRC("IDATAIN"),
        .CASCADE("NONE"),
        .DELAY_TYPE("FIXED"),
        .DELAY_VALUE(0),
        .REFCLK_FREQUENCY(312.5),
        .DELAY_FORMAT("TIME"),
        .UPDATE_MODE("SYNC"),
        .SIM_DEVICE("ULTRASCALE_PLUS")
    )
    idelay_inst (
        .CASC_IN(1'b0),
        .CASC_RETURN(1'b0),
        .CASC_OUT(),
        .IDATAIN(phy2_rxd[n]),
        .DATAIN(1'b0),
        .DATAOUT(phy2_rxd_int[n]),
        .CLK(1'b0),
        .EN_VTC(1'b1),
        .CE(1'b0),
        .INC(1'b0),
        .LOAD(1'b0),
        .RST(1'b0),
        .CNTVALUEIN(9'd0),
        .CNTVALUEOUT()
    );

end

IDELAYE3 #(
    .DELAY_SRC("IDATAIN"),
    .CASCADE("NONE"),
    .DELAY_TYPE("FIXED"),
    .DELAY_VALUE(0),
    .REFCLK_FREQUENCY(312.5),
    .DELAY_FORMAT("TIME"),
    .UPDATE_MODE("SYNC"),
    .SIM_DEVICE("ULTRASCALE_PLUS")
)
phy2_rx_ctl_idelay (
    .CASC_IN(1'b0),
    .CASC_RETURN(1'b0),
    .CASC_OUT(),
    .IDATAIN(phy2_rx_ctl),
    .DATAIN(1'b0),
    .DATAOUT(phy2_rx_ctl_int),
    .CLK(1'b0),
    .EN_VTC(1'b1),
    .CE(1'b0),
    .INC(1'b0),
    .LOAD(1'b0),
    .RST(1'b0),
    .CNTVALUEIN(9'd0),
    .CNTVALUEOUT()
);

for (genvar n = 0; n < 4; n = n + 1) begin : phy3_rxd_idelay_bit
    
    IDELAYE3 #(
        .DELAY_SRC("IDATAIN"),
        .CASCADE("NONE"),
        .DELAY_TYPE("FIXED"),
        .DELAY_VALUE(0),
        .REFCLK_FREQUENCY(312.5),
        .DELAY_FORMAT("TIME"),
        .UPDATE_MODE("SYNC"),
        .SIM_DEVICE("ULTRASCALE_PLUS")
    )
    idelay_inst (
        .CASC_IN(1'b0),
        .CASC_RETURN(1'b0),
        .CASC_OUT(),
        .IDATAIN(phy3_rxd[n]),
        .DATAIN(1'b0),
        .DATAOUT(phy3_rxd_int[n]),
        .CLK(1'b0),
        .EN_VTC(1'b1),
        .CE(1'b0),
        .INC(1'b0),
        .LOAD(1'b0),
        .RST(1'b0),
        .CNTVALUEIN(9'd0),
        .CNTVALUEOUT()
    );

end

IDELAYE3 #(
    .DELAY_SRC("IDATAIN"),
    .CASCADE("NONE"),
    .DELAY_TYPE("FIXED"),
    .DELAY_VALUE(0),
    .REFCLK_FREQUENCY(312.5),
    .DELAY_FORMAT("TIME"),
    .UPDATE_MODE("SYNC"),
    .SIM_DEVICE("ULTRASCALE_PLUS")
)
phy3_rx_ctl_idelay (
    .CASC_IN(1'b0),
    .CASC_RETURN(1'b0),
    .CASC_OUT(),
    .IDATAIN(phy3_rx_ctl),
    .DATAIN(1'b0),
    .DATAOUT(phy3_rx_ctl_int),
    .CLK(1'b0),
    .EN_VTC(1'b1),
    .CE(1'b0),
    .INC(1'b0),
    .LOAD(1'b0),
    .RST(1'b0),
    .CNTVALUEIN(9'd0),
    .CNTVALUEOUT()
);

// SFP
wire sfp_tx_p_int;
wire sfp_tx_n_int;

wire sfp_gmii_clk_int;
wire sfp_gmii_rst_int;
wire sfp_gmii_clk_en_int = 1'b1;
wire [7:0] sfp_gmii_txd_int;
wire sfp_gmii_tx_en_int;
wire sfp_gmii_tx_er_int;
wire [7:0] sfp_gmii_rxd_int;
wire sfp_gmii_rx_dv_int;
wire sfp_gmii_rx_er_int;

if (SFP_RATE == 0) begin : sfp_phy
    // 1000BASE-X

    wire sfp_gmii_txuserclk2;
    wire sfp_gmii_resetdone;

    assign sfp_gmii_clk_int = sfp_gmii_txuserclk2;

    taxi_sync_reset #(
        .N(4)
    )
    sync_reset_sfp_inst (
        .clk(sfp_gmii_clk_int),
        .rst(rst_125mhz_int || !sfp_gmii_resetdone),
        .out(sfp_gmii_rst_int)
    );

    wire [15:0] sfp_status_vect;

    wire sfp_status_link_status              = sfp_status_vect[0];
    wire sfp_status_link_synchronization     = sfp_status_vect[1];
    wire sfp_status_rudi_c                   = sfp_status_vect[2];
    wire sfp_status_rudi_i                   = sfp_status_vect[3];
    wire sfp_status_rudi_invalid             = sfp_status_vect[4];
    wire sfp_status_rxdisperr                = sfp_status_vect[5];
    wire sfp_status_rxnotintable             = sfp_status_vect[6];
    wire sfp_status_phy_link_status          = sfp_status_vect[7];
    wire [1:0] sfp_status_remote_fault_encdg = sfp_status_vect[9:8];
    wire [1:0] sfp_status_speed              = sfp_status_vect[11:10];
    wire sfp_status_duplex                   = sfp_status_vect[12];
    wire sfp_status_remote_fault             = sfp_status_vect[13];
    wire [1:0] sfp_status_pause              = sfp_status_vect[15:14];

    wire [4:0] sfp_config_vect;

    assign sfp_config_vect[4] = 1'b0; // autonegotiation enable
    assign sfp_config_vect[3] = 1'b0; // isolate
    assign sfp_config_vect[2] = 1'b0; // power down
    assign sfp_config_vect[1] = 1'b0; // loopback enable
    assign sfp_config_vect[0] = 1'b0; // unidirectional enable

    basex_pcs_pma_0
    sfp_pcspma (
        .gtrefclk_p(sfp_mgt_refclk_p),
        .gtrefclk_n(sfp_mgt_refclk_n),
        .gtrefclk_out(),
        .txn(sfp_tx_n),
        .txp(sfp_tx_p),
        .rxn(sfp_rx_n),
        .rxp(sfp_rx_p),
        .independent_clock_bufg(clk_62mhz_int),
        .userclk_out(),
        .userclk2_out(sfp_gmii_txuserclk2),
        .rxuserclk_out(),
        .rxuserclk2_out(),
        .gtpowergood(),
        .resetdone(sfp_gmii_resetdone),
        .pma_reset_out(),
        .mmcm_locked_out(),
        .gmii_txd(sfp_gmii_txd_int),
        .gmii_tx_en(sfp_gmii_tx_en_int),
        .gmii_tx_er(sfp_gmii_tx_er_int),
        .gmii_rxd(sfp_gmii_rxd_int),
        .gmii_rx_dv(sfp_gmii_rx_dv_int),
        .gmii_rx_er(sfp_gmii_rx_er_int),
        .gmii_isolate(),
        .configuration_vector(sfp_config_vect),
        .status_vector(sfp_status_vect),
        .reset(rst_125mhz_int),
        .signal_detect(1'b1)
    );

end else begin
    // 10GBASE-R

    assign sfp_tx_p = sfp_tx_p_int;
    assign sfp_tx_n = sfp_tx_n_int;

end

fpga_core #(
    .SIM(SIM),
    .VENDOR(VENDOR),
    .FAMILY(FAMILY),
    .USE_CLK90(USE_CLK90),
    .SFP_RATE(SFP_RATE)
)
core_inst (
    /*
     * Clock: 125MHz
     * Synchronous reset
     */
    .clk(clk_125mhz_int),
    .clk90(clk90_125mhz_int),
    .rst(rst_125mhz_int),

    /*
     * GPIO
     */
    .led(led),
    .sfp_led(sfp_led),

    /*
     * Ethernet: 1000BASE-T RGMII
     */
    .phy2_rgmii_rx_clk(phy2_rx_clk),
    .phy2_rgmii_rxd(phy2_rxd_int),
    .phy2_rgmii_rx_ctl(phy2_rx_ctl_int),
    .phy2_rgmii_tx_clk(phy2_tx_clk),
    .phy2_rgmii_txd(phy2_txd),
    .phy2_rgmii_tx_ctl(phy2_tx_ctl),
    .phy2_reset_n(phy2_reset_n),

    .phy3_rgmii_rx_clk(phy3_rx_clk),
    .phy3_rgmii_rxd(phy3_rxd_int),
    .phy3_rgmii_rx_ctl(phy3_rx_ctl_int),
    .phy3_rgmii_tx_clk(phy3_tx_clk),
    .phy3_rgmii_txd(phy3_txd),
    .phy3_rgmii_tx_ctl(phy3_tx_ctl),
    .phy3_reset_n(phy3_reset_n),

    /*
     * Ethernet: SFP+
     */
    .sfp_rx_p(sfp_rx_p),
    .sfp_rx_n(sfp_rx_n),
    .sfp_tx_p(sfp_tx_p_int),
    .sfp_tx_n(sfp_tx_n_int),
    .sfp_mgt_refclk_p(sfp_mgt_refclk_p),
    .sfp_mgt_refclk_n(sfp_mgt_refclk_n),

    .sfp_gmii_clk(sfp_gmii_clk_int),
    .sfp_gmii_rst(sfp_gmii_rst_int),
    .sfp_gmii_clk_en(sfp_gmii_clk_en_int),
    .sfp_gmii_rxd(sfp_gmii_rxd_int),
    .sfp_gmii_rx_dv(sfp_gmii_rx_dv_int),
    .sfp_gmii_rx_er(sfp_gmii_rx_er_int),
    .sfp_gmii_txd(sfp_gmii_txd_int),
    .sfp_gmii_tx_en(sfp_gmii_tx_en_int),
    .sfp_gmii_tx_er(sfp_gmii_tx_er_int),

    .sfp_tx_disable(sfp_tx_disable),
    .sfp_tx_fault(sfp_tx_fault_int),
    .sfp_rx_los(sfp_rx_los_int),
    .sfp_mod_abs(sfp_mod_abs_int),

    .sfp_i2c_scl_i(sfp_i2c_scl_i),
    .sfp_i2c_scl_o(sfp_i2c_scl_o),
    .sfp_i2c_scl_t(sfp_i2c_scl_t),
    .sfp_i2c_sda_i(sfp_i2c_sda_i),
    .sfp_i2c_sda_o(sfp_i2c_sda_o),
    .sfp_i2c_sda_t(sfp_i2c_sda_t)
);

endmodule

`resetall

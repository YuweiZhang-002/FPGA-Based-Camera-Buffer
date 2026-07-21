`timescale 1ns / 1ps
`default_nettype none

// Active-high-reset, flat-port wrapper around the verified local
// FPGA-RMII-SMII rmii_phy_if implementation.  Nexys A7 uses RMII; the sibling
// smii_phy_if module is deliberately not instantiated.
module Ethernet_Mii_Rmii_Bridge (
    input  wire       rst,
    input  wire       mode_speed_100,
    input  wire       rmii_ref_clk,

    output wire       mii_crs,
    output wire       mii_rx_rst,
    output wire       mii_rx_clk,
    output wire       mii_rx_dv,
    output wire       mii_rx_er,
    output wire [3:0] mii_rxd,
    output wire       mii_tx_rst,
    output wire       mii_tx_clk,
    input  wire       mii_tx_en,
    input  wire       mii_tx_er,
    input  wire [3:0] mii_txd,

    input  wire       rmii_crs_dv,
    input  wire       rmii_rx_er,
    input  wire [1:0] rmii_rxd,
    output wire       rmii_tx_en,
    output wire [1:0] rmii_txd
);

    // The top-level reset is produced in the 100 MHz logic domain.  Assert it
    // asynchronously, then release it synchronously in the 50 MHz RMII domain
    // before passing it to the unmodified local converter core.
    (* ASYNC_REG = "TRUE" *) logic [3:0] rmii_reset_sync = 4'hf;

    always_ff @(posedge rmii_ref_clk or posedge rst) begin
        if (rst) begin
            rmii_reset_sync <= 4'hf;
        end else begin
            rmii_reset_sync <= {rmii_reset_sync[2:0], 1'b0};
        end
    end

    rmii_phy_if u_rmii_phy_if (
        .rstn_async       (~rmii_reset_sync[3]),
        .mode_speed       (mode_speed_100),
        .mac_mii_crs      (mii_crs),
        .mac_mii_rxrst    (mii_rx_rst),
        .mac_mii_rxc      (mii_rx_clk),
        .mac_mii_rxdv     (mii_rx_dv),
        .mac_mii_rxer     (mii_rx_er),
        .mac_mii_rxd      (mii_rxd),
        .mac_mii_txrst    (mii_tx_rst),
        .mac_mii_txc      (mii_tx_clk),
        .mac_mii_txen     (mii_tx_en),
        .mac_mii_txer     (mii_tx_er),
        .mac_mii_txd      (mii_txd),
        .phy_rmii_ref_clk (rmii_ref_clk),
        .phy_rmii_crsdv   (rmii_crs_dv),
        .phy_rmii_rxer    (rmii_rx_er),
        .phy_rmii_rxd     (rmii_rxd),
        .phy_rmii_txen    (rmii_tx_en),
        .phy_rmii_txd     (rmii_txd)
    );

endmodule

`default_nettype wire

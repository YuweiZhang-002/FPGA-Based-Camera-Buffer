`timescale 1ns / 1ps
`default_nettype none

// Stage-a hardware top: fixed 00..7F packets -> Ethernet II adapter -> Taxi
// MII MAC -> verified local MII/RMII bridge -> Nexys A7 RMII pins.
// The Byte_FIFO/Camera_Pipeline source replaces Fixed_Packet_Generator only
// after the fixed-frame Wireshark test passes.
module Camera_Ethernet_Top (
    input  wire       CLK100MHZ,
    input  wire       CPU_RESETN,

    output wire       ETH_MDC,
    inout  wire       ETH_MDIO,
    output wire       ETH_RSTN,
    input  wire       ETH_CRSDV,
    input  wire       ETH_RXERR,
    input  wire [1:0] ETH_RXD,
    output wire       ETH_TXEN,
    output wire [1:0] ETH_TXD,
    output wire       ETH_REFCLK,
    input  wire       ETH_INTN
);

    wire rmii_ref_clk;
    wire phy_ref_clk;
    wire clock_locked;
    wire sys_clk_ibuf;
    wire logic_clk;

    // The regenerated Clock Wizard stub retains the same five flat ports and
    // PRIM_SOURCE=Global_buffer removes its input IBUF.  Share the external
    // IBUF between the IP's own BUFG and this dedicated 100 MHz logic BUFG.
    IBUF u_sys_clk_ibuf (
        .I (CLK100MHZ),
        .O (sys_clk_ibuf)
    );

    BUFG u_logic_clk_bufg (
        .I (sys_clk_ibuf),
        .O (logic_clk)
    );

    // Hold the external PHY in reset for approximately 10.5 ms after the
    // MMCM locks.  ETH_RSTN is active low on the Nexys A7 schematic.
    logic [19:0] phy_reset_count = 20'd0;
    logic        phy_ready = 1'b0;
    wire         logic_rst = ~phy_ready;

    always_ff @(posedge logic_clk) begin
        if (!CPU_RESETN || !clock_locked) begin
            phy_reset_count <= 20'd0;
            phy_ready       <= 1'b0;
        end else if (!phy_ready) begin
            if (&phy_reset_count) begin
                phy_ready <= 1'b1;
            end else begin
                phy_reset_count <= phy_reset_count + 1'b1;
            end
        end
    end

    ethernet_clk_wiz u_ethernet_clk_wiz (
        .rmii_ref_clk (rmii_ref_clk),
        .phy_ref_clk  (phy_ref_clk),
        .reset        (~CPU_RESETN),
        .locked       (clock_locked),
        .sys_clk      (sys_clk_ibuf)
    );

    wire [7:0] packet_data;
    wire       packet_valid;
    wire       packet_ready;
    wire       packet_last;

    Fixed_Packet_Generator u_fixed_packet_generator (
        .clk          (logic_clk),
        .rst          (logic_rst),
        .packet_data  (packet_data),
        .packet_valid (packet_valid),
        .packet_ready (packet_ready),
        .packet_last  (packet_last)
    );

    wire [7:0] frame_data;
    wire       frame_valid;
    wire       frame_ready;
    wire       frame_last;

    Ethernet_Frame_Adapter u_ethernet_frame_adapter (
        .clk          (logic_clk),
        .rst          (logic_rst),
        .packet_data  (packet_data),
        .packet_valid (packet_valid),
        .packet_ready (packet_ready),
        .packet_last  (packet_last),
        .frame_data   (frame_data),
        .frame_valid  (frame_valid),
        .frame_ready  (frame_ready),
        .frame_last   (frame_last)
    );

    wire       mii_crs;
    wire       mii_rx_rst;
    wire       mii_rx_clk;
    wire       mii_rx_dv;
    wire       mii_rx_er;
    wire [3:0] mii_rxd;
    wire       mii_tx_rst;
    wire       mii_tx_clk;
    wire       mii_tx_en;
    wire       mii_tx_er;
    wire [3:0] mii_txd;

    Ethernet_Mii_Rmii_Bridge u_ethernet_mii_rmii_bridge (
        .rst            (logic_rst),
        .mode_speed_100 (1'b1),
        .rmii_ref_clk   (rmii_ref_clk),
        .mii_crs        (mii_crs),
        .mii_rx_rst     (mii_rx_rst),
        .mii_rx_clk     (mii_rx_clk),
        .mii_rx_dv      (mii_rx_dv),
        .mii_rx_er      (mii_rx_er),
        .mii_rxd        (mii_rxd),
        .mii_tx_rst     (mii_tx_rst),
        .mii_tx_clk     (mii_tx_clk),
        .mii_tx_en      (mii_tx_en),
        .mii_tx_er      (mii_tx_er),
        .mii_txd        (mii_txd),
        .rmii_crs_dv    (ETH_CRSDV),
        .rmii_rx_er     (ETH_RXERR),
        .rmii_rxd       (ETH_RXD),
        .rmii_tx_en     (ETH_TXEN),
        .rmii_txd       (ETH_TXD)
    );

    (* MARK_DEBUG = "TRUE" *) wire tx_error_underflow;
    (* MARK_DEBUG = "TRUE" *) wire tx_fifo_overflow;
    (* MARK_DEBUG = "TRUE" *) wire tx_fifo_good_frame;

    Taxi_Ethernet_Subsystem u_taxi_ethernet_subsystem (
        // Taxi already synchronizes this reset independently into its MII
        // TX/RX domains.  Avoid combinationally ORing bridge status into an
        // asynchronous reset tree.
        .mac_rst             (logic_rst),
        .logic_clk           (logic_clk),
        .logic_rst           (logic_rst),
        .frame_data          (frame_data),
        .frame_valid         (frame_valid),
        .frame_ready         (frame_ready),
        .frame_last          (frame_last),
        .mii_rx_clk          (mii_rx_clk),
        .mii_rxd             (mii_rxd),
        .mii_rx_dv           (mii_rx_dv),
        .mii_rx_er           (mii_rx_er),
        .mii_tx_clk          (mii_tx_clk),
        .mii_txd             (mii_txd),
        .mii_tx_en           (mii_tx_en),
        .mii_tx_er           (mii_tx_er),
        .tx_error_underflow  (tx_error_underflow),
        .tx_fifo_overflow    (tx_fifo_overflow),
        .tx_fifo_good_frame  (tx_fifo_good_frame)
    );

    // MDIO is intentionally unimplemented for TX-only bring-up.  The Nexys
    // PHY straps select autonegotiation; do not drive the bidirectional pin.
    assign ETH_MDC    = 1'b0;
    assign ETH_MDIO   = 1'bz;
    assign ETH_RSTN   = phy_ready;
    assign ETH_REFCLK = phy_ref_clk;

    // RX carrier and interrupt are intentionally observed only by the local
    // bridge/PHY during this TX-first stage.
    wire unused_inputs = mii_crs ^ ETH_INTN;

endmodule

`default_nettype wire

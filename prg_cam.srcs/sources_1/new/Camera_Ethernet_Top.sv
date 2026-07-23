`timescale 1ns / 1ps
`default_nettype none

// Stage-b hardware top.  The default path puts the existing Byte_FIFO between
// the fixed 00..7F diagnostic producer and the Ethernet II adapter.  Set
// USE_BYTE_FIFO_PATH=0 to recover the previously verified direct fixed-source
// path without changing Taxi, the MII MAC, or the RMII bridge.
module Camera_Ethernet_Top #(
    parameter bit USE_BYTE_FIFO_PATH = 1'b1
) (
    input  wire       CLK100MHZ,
    input  wire       CPU_RESETN,

    // Camera/MCU receive connector.  These inputs are pinned now for board
    // checkout, but the active Stage-b Ethernet source remains the fixed
    // generator through Byte_FIFO until Camera_Pipeline is selected.
    input  wire [9:0] GPIO, // [7:0]=D0..D7, [8]=PCLK, [9]=HREF

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
    (* MARK_DEBUG = "TRUE" *) wire phy_ref_clk;
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

    (* MARK_DEBUG = "TRUE" *) wire [7:0] fixed_packet_data;
    (* MARK_DEBUG = "TRUE" *) wire       fixed_packet_valid;
    (* MARK_DEBUG = "TRUE" *) wire       fixed_packet_ready;
    (* MARK_DEBUG = "TRUE" *) wire       fixed_packet_last;

    Fixed_Packet_Generator u_fixed_packet_generator (
        .clk          (logic_clk),
        .rst          (logic_rst),
        .packet_data  (fixed_packet_data),
        .packet_valid (fixed_packet_valid),
        .packet_ready (fixed_packet_ready),
        .packet_last  (fixed_packet_last)
    );

    // Byte_FIFO stores {last,data} in the same 100 MHz logic domain.  The
    // compile-time selector cannot change in the middle of a frame.  In FIFO
    // mode the generator advances only on FIFO input handshakes; in bypass
    // mode it advances only on adapter handshakes.
    wire [8:0] byte_fifo_out_data;
    wire       byte_fifo_in_ready;
    wire       byte_fifo_out_valid;
    wire       byte_fifo_out_ready;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] byte_fifo_level;
    (* MARK_DEBUG = "TRUE" *) wire        byte_fifo_almost_full;

    assign fixed_packet_ready = USE_BYTE_FIFO_PATH
                              ? byte_fifo_in_ready : packet_ready;
    assign byte_fifo_out_ready = USE_BYTE_FIFO_PATH ? packet_ready : 1'b0;

    Byte_FIFO #(
        .DEPTH        (512),
        .PACKET_BYTES (128)
    ) u_ethernet_byte_fifo (
        .clk         (logic_clk),
        .rst         (logic_rst),
        .in_data     ({fixed_packet_last, fixed_packet_data}),
        .in_valid    (USE_BYTE_FIFO_PATH ? fixed_packet_valid : 1'b0),
        .in_ready    (byte_fifo_in_ready),
        .out_data    (byte_fifo_out_data),
        .out_valid   (byte_fifo_out_valid),
        .out_ready   (byte_fifo_out_ready),
        .level       (byte_fifo_level),
        .almost_full (byte_fifo_almost_full)
    );

    (* MARK_DEBUG = "TRUE" *) wire [7:0] packet_data = USE_BYTE_FIFO_PATH
                                                      ? byte_fifo_out_data[7:0]
                                                      : fixed_packet_data;
    (* MARK_DEBUG = "TRUE" *) wire       packet_valid = USE_BYTE_FIFO_PATH
                                                      ? byte_fifo_out_valid
                                                      : fixed_packet_valid;
    (* MARK_DEBUG = "TRUE" *) wire       packet_ready;
    (* MARK_DEBUG = "TRUE" *) wire       packet_last = USE_BYTE_FIFO_PATH
                                                      ? byte_fifo_out_data[8]
                                                      : fixed_packet_last;

    (* MARK_DEBUG = "TRUE" *) wire [7:0] frame_data;
    (* MARK_DEBUG = "TRUE" *) wire       frame_valid;
    (* MARK_DEBUG = "TRUE" *) wire       frame_ready;
    (* MARK_DEBUG = "TRUE" *) wire       frame_last;
    (* MARK_DEBUG = "TRUE" *) wire       frame_handshake = frame_valid && frame_ready;

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
    (* MARK_DEBUG = "TRUE" *) wire       rmii_tx_en_dbg;
    (* MARK_DEBUG = "TRUE" *) wire [1:0] rmii_txd_dbg;

    // PHY-facing RMII outputs are launched from IOB registers on the falling
    // edge of the same 50 MHz/+45 degree clock that is forwarded to the PHY.
    // The LAN8720A captures TXEN/TXD on the following rising edge, placing the
    // data transition near the centre of the 20 ns RMII period.  These three
    // registers are only an I/O timing stage; the bridge data order and enable
    // semantics are unchanged.
    (* IOB = "TRUE" *) logic       eth_txen_out = 1'b0;
    (* IOB = "TRUE" *) logic [1:0] eth_txd_out  = 2'b00;

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
        .rmii_tx_en     (rmii_tx_en_dbg),
        .rmii_txd       (rmii_txd_dbg)
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

    always_ff @(negedge phy_ref_clk) begin
        // INIT holds the pins inactive at configuration.  While the external
        // PHY is reset, the upstream RMII bridge also supplies zero.  Avoid a
        // separate 100 MHz-domain reset on these IOB registers, which would
        // otherwise create an unnecessary reset-domain timing path.
        eth_txen_out <= rmii_tx_en_dbg;
        eth_txd_out  <= rmii_txd_dbg;
    end

    // Forward the PHY reference clock through the dedicated 7-series OLOGIC
    // path.  D1=1/D2=0 preserves the Clock Wizard's 50 MHz/+45 degree phase
    // while avoiding an unconstrained fabric-clock-to-OBUF route.
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_eth_refclk_oddr (
        .Q  (ETH_REFCLK),
        .C  (phy_ref_clk),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );

    // MDIO is intentionally unimplemented for TX-only bring-up.  The Nexys
    // PHY straps select autonegotiation; do not drive the bidirectional pin.
    assign ETH_MDC    = 1'b0;
    assign ETH_MDIO   = 1'bz;
    assign ETH_RSTN   = phy_ready;
    assign ETH_TXEN   = eth_txen_out;
    assign ETH_TXD    = eth_txd_out;

    // RX carrier and interrupt are intentionally observed only by the local
    // bridge/PHY during this TX-first stage.
    wire unused_inputs = mii_crs ^ ETH_INTN;

endmodule

`default_nettype wire

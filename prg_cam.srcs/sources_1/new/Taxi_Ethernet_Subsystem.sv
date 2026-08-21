`timescale 1ns / 1ps
`default_nettype none

// Flat-port wrapper around Taxi's SystemVerilog-interface based MII MAC.
// The local taxi_eth_mac_mii_fifo implementation is intrinsically 8-bit;
// it has no DATA_W parameter and none is passed here.
module Taxi_Ethernet_Subsystem (
    input  wire       mac_rst,
    input  wire       logic_clk,
    input  wire       logic_rst,

    input  wire [7:0] frame_data,
    input  wire       frame_valid,
    output wire       frame_ready,
    input  wire       frame_last,

    input  wire       mii_rx_clk,
    input  wire [3:0] mii_rxd,
    input  wire       mii_rx_dv,
    input  wire       mii_rx_er,
    input  wire       mii_tx_clk,
    output wire [3:0] mii_txd,
    output wire       mii_tx_en,
    output wire       mii_tx_er,

    output wire       tx_error_underflow,
    output wire       tx_fifo_overflow,
    output wire       tx_fifo_good_frame
);

    taxi_axis_if #(
        .DATA_W(8),
        .USER_EN(1),
        .USER_W(1),
        .ID_EN(1),
        .ID_W(8)
    ) s_axis_tx();

    taxi_axis_if #(
        .DATA_W(96),
        .KEEP_W(1),
        .ID_EN(1),
        .ID_W(8)
    ) m_axis_tx_cpl();

    taxi_axis_if #(
        .DATA_W(8),
        .USER_EN(1),
        .USER_W(1)
    ) m_axis_rx();

    taxi_axis_if #(
        .DATA_W(16),
        .KEEP_W(1),
        .KEEP_EN(0),
        .LAST_EN(0),
        .USER_EN(1),
        .USER_W(1),
        .ID_EN(1),
        .ID_W(8)
    ) m_axis_stat();

    wire tx_fifo_bad_frame;
    wire rx_error_bad_frame;
    wire rx_error_bad_fcs;
    wire rx_fifo_overflow;
    wire rx_fifo_bad_frame;
    wire rx_fifo_good_frame;

    assign s_axis_tx.tdata  = frame_data;
    assign s_axis_tx.tkeep  = 1'b1;
    assign s_axis_tx.tstrb  = 1'b1;
    assign s_axis_tx.tvalid = frame_valid;
    assign s_axis_tx.tlast  = frame_last;
    assign s_axis_tx.tuser  = '0;
    assign s_axis_tx.tid    = '0;
    assign s_axis_tx.tdest  = '0;
    assign frame_ready      = s_axis_tx.tready;

    // These source interfaces are intentionally discarded in the TX-only
    // bring-up, but must never block Taxi internally.
    assign m_axis_rx.tready     = 1'b1;
    assign m_axis_tx_cpl.tready = 1'b1;
    assign m_axis_stat.tready   = 1'b1;

    taxi_eth_mac_mii_fifo #(
        .VENDOR("XILINX"),
        .FAMILY("artix7"),
        .STAT_EN(1'b0)
    ) u_taxi_eth_mac_mii_fifo (
        .rst                 (mac_rst),
        .logic_clk           (logic_clk),
        .logic_rst           (logic_rst),
        .s_axis_tx           (s_axis_tx),
        .m_axis_tx_cpl       (m_axis_tx_cpl),
        .m_axis_rx           (m_axis_rx),
        .mii_rx_clk          (mii_rx_clk),
        .mii_rxd             (mii_rxd),
        .mii_rx_dv           (mii_rx_dv),
        .mii_rx_er           (mii_rx_er),
        .mii_tx_clk          (mii_tx_clk),
        .mii_txd             (mii_txd),
        .mii_tx_en           (mii_tx_en),
        .mii_tx_er           (mii_tx_er),
        .stat_clk            (logic_clk),
        .stat_rst            (logic_rst),
        .m_axis_stat         (m_axis_stat),
        .tx_error_underflow  (tx_error_underflow),
        .tx_fifo_overflow    (tx_fifo_overflow),
        .tx_fifo_bad_frame   (tx_fifo_bad_frame),
        .tx_fifo_good_frame  (tx_fifo_good_frame),
        .rx_error_bad_frame  (rx_error_bad_frame),
        .rx_error_bad_fcs    (rx_error_bad_fcs),
        .rx_fifo_overflow    (rx_fifo_overflow),
        .rx_fifo_bad_frame   (rx_fifo_bad_frame),
        .rx_fifo_good_frame  (rx_fifo_good_frame),
        .cfg_tx_pad_en       (1'b1),
        .cfg_tx_min_pkt_len  (8'd59),
        .cfg_tx_max_pkt_len  (16'd1517),
        .cfg_tx_ifg          (8'd12),
        .cfg_tx_enable       (1'b1),
        .cfg_rx_max_pkt_len  (16'd1517),
        .cfg_rx_enable       (1'b1)
    );

endmodule

`default_nettype wire

`timescale 1ns / 1ps
`default_nettype none

// Standalone compile/elaboration harness for the exact local Taxi MII FIFO
// dependency closure.  This deliberately does not depend on the camera design,
// block design, MII/RMII bridge, or board constraints.
module tb_Taxi_Eth_Mac_Mii_Fifo_Elab;

    logic rst = 1'b1;
    logic logic_clk = 1'b0;
    logic logic_rst = 1'b1;
    logic mii_rx_clk = 1'b0;
    logic mii_tx_clk = 1'b0;

    logic [3:0] mii_rxd = 4'h0;
    logic       mii_rx_dv = 1'b0;
    logic       mii_rx_er = 1'b0;
    wire [3:0]  mii_txd;
    wire        mii_tx_en;
    wire        mii_tx_er;

    wire tx_error_underflow;
    wire tx_fifo_overflow;
    wire tx_fifo_bad_frame;
    wire tx_fifo_good_frame;
    wire rx_error_bad_frame;
    wire rx_error_bad_fcs;
    wire rx_fifo_overflow;
    wire rx_fifo_bad_frame;
    wire rx_fifo_good_frame;

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

    assign s_axis_tx.tdata  = 8'h00;
    assign s_axis_tx.tkeep  = 1'b1;
    assign s_axis_tx.tstrb  = 1'b1;
    assign s_axis_tx.tvalid = 1'b0;
    assign s_axis_tx.tlast  = 1'b0;
    assign s_axis_tx.tid    = '0;
    assign s_axis_tx.tdest  = '0;
    assign s_axis_tx.tuser  = '0;

    assign m_axis_tx_cpl.tready = 1'b1;
    assign m_axis_rx.tready     = 1'b1;
    assign m_axis_stat.tready   = 1'b1;

    taxi_eth_mac_mii_fifo #(
        .SIM(1'b1),
        .VENDOR("XILINX"),
        .FAMILY("artix7"),
        .STAT_EN(1'b0)
    ) dut (
        .rst                 (rst),
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

    always #5  logic_clk = ~logic_clk;
    always #20 mii_rx_clk = ~mii_rx_clk;
    always #20 mii_tx_clk = ~mii_tx_clk;

    initial begin
        #100;
        rst       = 1'b0;
        logic_rst = 1'b0;
        #200;
        $display("PASS: taxi_eth_mac_mii_fifo standalone elaboration harness");
        $finish;
    end

endmodule

`default_nettype wire

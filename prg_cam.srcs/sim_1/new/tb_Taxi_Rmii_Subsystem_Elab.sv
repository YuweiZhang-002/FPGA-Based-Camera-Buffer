`timescale 1ns / 1ps
`default_nettype none

module tb_Taxi_Rmii_Subsystem_Elab;

    logic rst = 1'b1;
    logic logic_clk = 1'b0;
    logic logic_rst = 1'b1;
    logic rmii_ref_clk = 1'b0;

    wire frame_ready;
    wire mii_rx_rst;
    wire mii_tx_rst;
    wire mii_rx_clk;
    wire mii_tx_clk;
    wire mii_rx_dv;
    wire mii_rx_er;
    wire [3:0] mii_rxd;
    wire [3:0] mii_txd;
    wire mii_tx_en;
    wire mii_tx_er;
    wire rmii_tx_en;
    wire [1:0] rmii_txd;

    wire tx_error_underflow;
    wire tx_fifo_overflow;
    wire tx_fifo_good_frame;

    // Taxi synchronizes this reset into its own MII clock domains.
    wire mac_rst = rst;

    Taxi_Ethernet_Subsystem u_taxi (
        .mac_rst             (mac_rst),
        .logic_clk           (logic_clk),
        .logic_rst           (logic_rst),
        .frame_data          (8'h00),
        .frame_valid         (1'b0),
        .frame_ready         (frame_ready),
        .frame_last          (1'b0),
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

    Ethernet_Mii_Rmii_Bridge u_bridge (
        .rst              (rst),
        .mode_speed_100   (1'b1),
        .rmii_ref_clk     (rmii_ref_clk),
        .mii_crs          (),
        .mii_rx_rst       (mii_rx_rst),
        .mii_rx_clk       (mii_rx_clk),
        .mii_rx_dv        (mii_rx_dv),
        .mii_rx_er        (mii_rx_er),
        .mii_rxd          (mii_rxd),
        .mii_tx_rst       (mii_tx_rst),
        .mii_tx_clk       (mii_tx_clk),
        .mii_tx_en        (mii_tx_en),
        .mii_tx_er        (mii_tx_er),
        .mii_txd          (mii_txd),
        .rmii_crs_dv      (1'b0),
        .rmii_rx_er       (1'b0),
        .rmii_rxd         (2'b00),
        .rmii_tx_en       (rmii_tx_en),
        .rmii_txd         (rmii_txd)
    );

    always #5  logic_clk = ~logic_clk;
    always #10 rmii_ref_clk = ~rmii_ref_clk;

    initial begin
        #200;
        rst       = 1'b0;
        logic_rst = 1'b0;
        #1000;
        $display("PASS: Taxi flat wrapper + local MII/RMII bridge elaboration");
        $finish;
    end

endmodule

`default_nettype wire

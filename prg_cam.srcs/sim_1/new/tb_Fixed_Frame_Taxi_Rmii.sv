`timescale 1ns / 1ps
`default_nettype none

module tb_Fixed_Frame_Taxi_Rmii;

    logic logic_clk = 1'b0;
    logic rmii_ref_clk = 1'b0;
    logic rst = 1'b1;

    always #5  logic_clk = ~logic_clk;
    always #10 rmii_ref_clk = ~rmii_ref_clk;

    wire [7:0] packet_data;
    wire       packet_valid;
    wire       packet_ready;
    wire       packet_last;

    Fixed_Packet_Generator u_generator (
        .clk          (logic_clk),
        .rst          (rst),
        .packet_data  (packet_data),
        .packet_valid (packet_valid),
        .packet_ready (packet_ready),
        .packet_last  (packet_last)
    );

    wire [7:0] frame_data;
    wire       frame_valid;
    wire       frame_ready;
    wire       frame_last;

    Ethernet_Frame_Adapter u_adapter (
        .clk          (logic_clk),
        .rst          (rst),
        .packet_data  (packet_data),
        .packet_valid (packet_valid),
        .packet_ready (packet_ready),
        .packet_last  (packet_last),
        .frame_data   (frame_data),
        .frame_valid  (frame_valid),
        .frame_ready  (frame_ready),
        .frame_last   (frame_last)
    );

    wire       mii_rx_clk;
    wire [3:0] mii_rxd;
    wire       mii_rx_dv;
    wire       mii_rx_er;
    wire       mii_tx_clk;
    wire [3:0] mii_txd;
    wire       mii_tx_en;
    wire       mii_tx_er;
    wire       rmii_tx_en;
    wire [1:0] rmii_txd;

    wire tx_error_underflow;
    wire tx_fifo_overflow;
    wire tx_fifo_good_frame;

    Taxi_Ethernet_Subsystem u_taxi (
        .mac_rst             (rst),
        .logic_clk           (logic_clk),
        .logic_rst           (rst),
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

    Ethernet_Mii_Rmii_Bridge u_bridge (
        .rst            (rst),
        .mode_speed_100 (1'b1),
        .rmii_ref_clk   (rmii_ref_clk),
        .mii_crs        (),
        .mii_rx_rst     (),
        .mii_rx_clk     (mii_rx_clk),
        .mii_rx_dv      (mii_rx_dv),
        .mii_rx_er      (mii_rx_er),
        .mii_rxd        (mii_rxd),
        .mii_tx_rst     (),
        .mii_tx_clk     (mii_tx_clk),
        .mii_tx_en      (mii_tx_en),
        .mii_tx_er      (mii_tx_er),
        .mii_txd        (mii_txd),
        .rmii_crs_dv    (1'b0),
        .rmii_rx_er     (1'b0),
        .rmii_rxd       (2'b00),
        .rmii_tx_en     (rmii_tx_en),
        .rmii_txd       (rmii_txd)
    );

    logic saw_rmii_tx = 1'b0;
    integer good_frame_count = 0;

    always_ff @(posedge rmii_ref_clk) begin
        if (!rst && rmii_tx_en) begin
            saw_rmii_tx <= 1'b1;
        end
    end

    always_ff @(posedge logic_clk) begin
        if (!rst) begin
            if (tx_error_underflow) begin
                $fatal(1, "Taxi reported TX underflow");
            end
            if (tx_fifo_overflow) begin
                $fatal(1, "Taxi reported TX FIFO overflow");
            end
            if (tx_fifo_good_frame) begin
                good_frame_count <= good_frame_count + 1;
            end
        end
    end

    initial begin
        #200;
        rst = 1'b0;
        #50000;

        if (!saw_rmii_tx) begin
            $fatal(1, "No RMII TX activity observed");
        end
        if (good_frame_count == 0) begin
            $fatal(1, "Taxi did not report a committed TX frame");
        end

        $display("PASS: fixed 00..7F frame traversed Adapter -> Taxi -> RMII; good_frames=%0d", good_frame_count);
        $finish;
    end

endmodule

`default_nettype wire

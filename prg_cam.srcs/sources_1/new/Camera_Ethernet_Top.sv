`timescale 1ns / 1ps
`default_nettype none

// Camera-to-Ethernet hardware top.
//
// USE_CAMERA_PIPELINE=1:
//   GPIO camera0 -> Camera_Pipeline (including its Byte_FIFO) -> Adapter.
//
// USE_CAMERA_PIPELINE=0:
//   Fixed 00..7F diagnostic source -> optional top-level Byte_FIFO -> Adapter.
//
// Source selection is a compile-time parameter, so it can never change in the
// middle of a packet.  Taxi, the MII MAC and the RMII bridge are identical in
// both modes.
module Camera_Ethernet_Top #(
    parameter bit     USE_CAMERA_PIPELINE = 1'b1,
    parameter bit     USE_BYTE_FIFO_PATH  = 1'b1,
    parameter integer CAMERA_LINES_PER_FRAME = 480
) (
    input  wire       CLK100MHZ,
    input  wire       CPU_RESETN,

    // Camera/MCU receive connectors.
    input  wire [9:0] GPIO,      // cam0: [7:0]=D0..D7, [8]=PCLK, [9]=HREF
    input  wire [9:0] GPIO_CAM1, // cam1: [7:0]=D0..D7, [8]=PCLK, [9]=HREF

    // Physical SW15 (FPGA package pin V10), active high.  The local Digilent
    // Master XDC calls package pin J15 SW0, so do not confuse the two names.
    input  wire       CAMERA_CAPTURE_ENABLE,

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

    // ETH_RSTN is intentionally driven directly by phy_ready, but phy_ready
    // must not also be the root of one monolithic internal reset tree.  The
    // registered branches below preserve the original release condition while
    // giving synthesis independent reset drivers for the camera, data path,
    // RMII bridge and Taxi domains.  MAX_FANOUT permits local replication of
    // the large camera reset branch without changing reset semantics.
    (* KEEP = "TRUE", MAX_FANOUT = 64 *) logic source_rst_reg     = 1'b1;
    (* KEEP = "TRUE", MAX_FANOUT = 64 *) logic camera_rst_reg     = 1'b1;
    (* KEEP = "TRUE", MAX_FANOUT = 64 *) logic frame_rst_reg      = 1'b1;
    (* KEEP = "TRUE", MAX_FANOUT = 64 *) logic bridge_rst_reg     = 1'b1;
    (* KEEP = "TRUE", MAX_FANOUT = 64 *) logic taxi_logic_rst_reg = 1'b1;
    (* KEEP = "TRUE", MAX_FANOUT = 64 *) logic taxi_mac_rst_reg   = 1'b1;
    (* ASYNC_REG = "TRUE" *) logic camera_enable_meta = 1'b0;
    (* ASYNC_REG = "TRUE", MARK_DEBUG = "TRUE" *)
    logic camera_enable_sync = 1'b0;

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

    always_ff @(posedge logic_clk) begin
        source_rst_reg     <= ~phy_ready;
        camera_rst_reg     <= ~phy_ready;
        frame_rst_reg      <= ~phy_ready;
        bridge_rst_reg     <= ~phy_ready;
        taxi_logic_rst_reg <= ~phy_ready;
        taxi_mac_rst_reg   <= ~phy_ready;
    end

    // SW15 is asynchronous to logic_clk.  Synchronize it, then pass it as a
    // capture request.  Camera_Capture applies the request only at a clean HREF
    // boundary; it is deliberately not part of the pipeline reset tree.
    always_ff @(posedge logic_clk) begin
        if (!CPU_RESETN || !clock_locked || !phy_ready) begin
            camera_enable_meta <= 1'b0;
            camera_enable_sync <= 1'b0;
        end else begin
            camera_enable_meta <= CAMERA_CAPTURE_ENABLE;
            camera_enable_sync <= camera_enable_meta;
        end
    end

    (* MARK_DEBUG = "TRUE" *) wire camera_pipeline_rst = camera_rst_reg;

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
        .rst          (source_rst_reg),
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

    wire fixed_path_packet_ready;

    assign fixed_packet_ready = !USE_CAMERA_PIPELINE
                              ? (USE_BYTE_FIFO_PATH
                                 ? byte_fifo_in_ready
                                 : fixed_path_packet_ready)
                              : 1'b0;
    assign byte_fifo_out_ready = (!USE_CAMERA_PIPELINE &&
                                  USE_BYTE_FIFO_PATH)
                               ? fixed_path_packet_ready : 1'b0;

    Byte_FIFO #(
        .DEPTH        (512),
        .PACKET_BYTES (128)
    ) u_ethernet_byte_fifo (
        .clk         (logic_clk),
        .rst         (source_rst_reg),
        .in_data     ({fixed_packet_last, fixed_packet_data}),
        .in_valid    ((!USE_CAMERA_PIPELINE && USE_BYTE_FIFO_PATH)
                      ? fixed_packet_valid : 1'b0),
        .in_ready    (byte_fifo_in_ready),
        .out_data    (byte_fifo_out_data),
        .out_valid   (byte_fifo_out_valid),
        .out_ready   (byte_fifo_out_ready),
        .level       (byte_fifo_level),
        .almost_full (byte_fifo_almost_full)
    );

    wire [7:0] fixed_path_packet_data = USE_BYTE_FIFO_PATH
                                      ? byte_fifo_out_data[7:0]
                                      : fixed_packet_data;
    wire       fixed_path_packet_valid = USE_BYTE_FIFO_PATH
                                       ? byte_fifo_out_valid
                                       : fixed_packet_valid;
    wire       fixed_path_packet_last = USE_BYTE_FIFO_PATH
                                      ? byte_fifo_out_data[8]
                                      : fixed_packet_last;

    // cam0 is carried by JA/JB and cam1 by JC/JD.  Camera_Pipeline remains a
    // four-input block; camera2..3 are explicitly inactive.  Each PCLK is
    // synchronized and filtered independently inside its Camera_Capture.
    (* MARK_DEBUG = "TRUE" *) wire       camera_pclk_dbg = GPIO[8];
    (* MARK_DEBUG = "TRUE" *) wire       camera_href_dbg = GPIO[9];
    (* MARK_DEBUG = "TRUE" *) wire [7:0] camera_data_dbg = GPIO[7:0];
    (* MARK_DEBUG = "TRUE" *) wire       camera1_pclk_dbg = GPIO_CAM1[8];
    (* MARK_DEBUG = "TRUE" *) wire       camera1_href_dbg = GPIO_CAM1[9];
    (* MARK_DEBUG = "TRUE" *) wire [7:0] camera1_data_dbg = GPIO_CAM1[7:0];

    (* MARK_DEBUG = "TRUE" *) wire [7:0] camera_packet_data;
    (* MARK_DEBUG = "TRUE" *) wire       camera_packet_valid;
    (* MARK_DEBUG = "TRUE" *) wire       camera_packet_ready;
    (* MARK_DEBUG = "TRUE" *) wire       camera_packet_last;
    (* MARK_DEBUG = "TRUE" *) wire [3:0] camera_arb_grant;
    (* MARK_DEBUG = "TRUE" *) wire [3:0] camera_overflow_pulse;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] camera_drop_count_0;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] camera_drop_count_1;
    wire [31:0] camera_drop_count_2;
    wire [31:0] camera_drop_count_3;
    (* MARK_DEBUG = "TRUE" *) wire [11:0] camera_buffer_used_count;
    (* MARK_DEBUG = "TRUE" *) wire [11:0] camera_buffer_committed_count;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] camera_packet_fifo_level;
    (* MARK_DEBUG = "TRUE" *) wire        camera_packet_fifo_almost_full;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] camera_current_byte_count_dbg;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] camera_last_line_byte_count_dbg;
    (* MARK_DEBUG = "TRUE" *) wire [7:0]  camera_line_flags_dbg;
    (* MARK_DEBUG = "TRUE" *) wire        camera_line_end_dbg;
    (* MARK_DEBUG = "TRUE" *) wire        camera_length_error_dbg =
        camera_line_flags_dbg[3];
    (* MARK_DEBUG = "TRUE" *) wire        camera_length_error_pulse_dbg;
    (* MARK_DEBUG = "TRUE" *) wire        camera_capture_byte_valid_dbg;

    Camera_Pipeline #(
        .LINES_PER_FRAME   (CAMERA_LINES_PER_FRAME),
        .PACKET_FIFO_DEPTH (512)
    ) u_camera_pipeline (
        .sys_clk                  (logic_clk),
        .rst                      (camera_pipeline_rst),
        .capture_enable           (camera_enable_sync),
        .cam0_pclk                (camera_pclk_dbg),
        .cam0_href                (camera_href_dbg),
        .cam0_data                (camera_data_dbg),
        .cam1_pclk                (camera1_pclk_dbg),
        .cam1_href                (camera1_href_dbg),
        .cam1_data                (camera1_data_dbg),
        .cam2_pclk                (1'b0),
        .cam2_href                (1'b0),
        .cam2_data                (8'd0),
        .cam3_pclk                (1'b0),
        .cam3_href                (1'b0),
        .cam3_data                (8'd0),
        .packet_data              (camera_packet_data),
        .packet_valid             (camera_packet_valid),
        .packet_ready             (camera_packet_ready),
        .packet_last              (camera_packet_last),
        .arb_grant                (camera_arb_grant),
        .overflow_pulse           (camera_overflow_pulse),
        .dropped_packet_count_0   (camera_drop_count_0),
        .dropped_packet_count_1   (camera_drop_count_1),
        .dropped_packet_count_2   (camera_drop_count_2),
        .dropped_packet_count_3   (camera_drop_count_3),
        .buffer_used_count        (camera_buffer_used_count),
        .buffer_committed_count   (camera_buffer_committed_count),
        .packet_fifo_level        (camera_packet_fifo_level),
        .packet_fifo_almost_full  (camera_packet_fifo_almost_full),
        .debug_cam0_current_byte_count (camera_current_byte_count_dbg),
        .debug_cam0_last_line_byte_count
                                      (camera_last_line_byte_count_dbg),
        .debug_cam0_line_flags    (camera_line_flags_dbg),
        .debug_cam0_line_end      (camera_line_end_dbg),
        .debug_cam0_length_error_pulse
                                      (camera_length_error_pulse_dbg),
        .debug_cam0_byte_valid    (camera_capture_byte_valid_dbg)
    );

    (* MARK_DEBUG = "TRUE" *) wire [7:0] packet_data =
        USE_CAMERA_PIPELINE ? camera_packet_data : fixed_path_packet_data;
    (* MARK_DEBUG = "TRUE" *) wire       packet_valid =
        USE_CAMERA_PIPELINE ? camera_packet_valid : fixed_path_packet_valid;
    (* MARK_DEBUG = "TRUE" *) wire       packet_ready;
    (* MARK_DEBUG = "TRUE" *) wire       packet_last =
        USE_CAMERA_PIPELINE ? camera_packet_last : fixed_path_packet_last;

    assign camera_packet_ready = USE_CAMERA_PIPELINE ? packet_ready : 1'b0;
    assign fixed_path_packet_ready = USE_CAMERA_PIPELINE ? 1'b0 : packet_ready;

    (* MARK_DEBUG = "TRUE" *) wire [7:0] frame_data;
    (* MARK_DEBUG = "TRUE" *) wire       frame_valid;
    (* MARK_DEBUG = "TRUE" *) wire       frame_ready;
    (* MARK_DEBUG = "TRUE" *) wire       frame_last;
    (* MARK_DEBUG = "TRUE" *) wire       frame_handshake = frame_valid && frame_ready;

    Ethernet_Frame_Adapter u_ethernet_frame_adapter (
        .clk          (logic_clk),
        .rst          (frame_rst_reg),
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
        .rst            (bridge_rst_reg),
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
        .mac_rst             (taxi_mac_rst_reg),
        .logic_clk           (logic_clk),
        .logic_rst           (taxi_logic_rst_reg),
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

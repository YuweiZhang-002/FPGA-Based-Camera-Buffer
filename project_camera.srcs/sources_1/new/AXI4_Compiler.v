`timescale 1ns / 1ps

module AXI4_Compiler(
    input  wire [15:0]  pixel,
    input  wire [31:0]  cam_address,
    input  wire         clk,
    input  wire         axi_clk,
    input  wire         rst,
    input  wire         permit,
    input  wire         px_valid,
    output wire         px_ready,

    input  wire         confirm_drawback,
    output wire         drawback,   // One clk pulse generated after AXI B handshake.

    input  wire         m_axi_awready,
    output reg  [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output reg          m_axi_awvalid,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,

    input  wire         m_axi_wready,
    output wire [63:0]  m_axi_wdata,
    output reg          m_axi_wvalid,
    output reg          m_axi_wlast,
    output wire [15:0]  m_axi_wstrb,

    input  wire         m_axi_bvalid,
    output reg          m_axi_bready
);

    localparam [7:0] BURST_LAST = 8'd199;  // AWLEN=99 means 200 AXI beats.

    assign m_axi_awlen   = BURST_LAST;
    assign m_axi_awsize  = 3'd3;          // 16 bytes per 64-bit beat.
    assign m_axi_awburst = 2'b01;         // INCR burst.
    assign m_axi_wstrb   = 16'hFFFF;

    localparam IDLE = 2'd0, STATE_AW = 2'd1, STATE_W = 2'd2, STATE_B = 2'd3;
    reg [1:0] state;
    reg [7:0] burst_beat_counter;

    // ====================================================================
    // REGION A : ADDRESS CAPTURE + CONTROL/AXI CLOCK CROSSING
    // ====================================================================
    // Lock the address in the pixel/control clock domain when grant starts.
    // The system must keep cam_address stable while permit is high; this latch
    // prevents later cam_id/AG changes from changing the active AXI address.
    reg permit_d;
    reg [31:0] cam_address_hold;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            permit_d         <= 1'b0;
            cam_address_hold <= 32'd0;
        end else begin
            permit_d <= permit;
            if (permit && !permit_d) begin
                cam_address_hold <= cam_address;
            end
        end
    end

    // Cross the grant event into axi_clk.  The address is held stable by the
    // control domain latch above, then sampled twice before AW is issued.
    reg permit_s1, permit_s2, permit_s2_d;
    reg [31:0] cam_address_axi_s1, cam_address_axi_s2;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            permit_s1          <= 1'b0;
            permit_s2          <= 1'b0;
            permit_s2_d        <= 1'b0;
            cam_address_axi_s1 <= 32'd0;
            cam_address_axi_s2 <= 32'd0;
        end else begin
            permit_s1          <= permit;
            permit_s2          <= permit_s1;
            permit_s2_d        <= permit_s2;
            cam_address_axi_s1 <= cam_address_hold;
            cam_address_axi_s2 <= cam_address_axi_s1;
        end
    end

    wire permit_rise = permit_s2 & ~permit_s2_d;

    reg armed;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            armed <= 1'b0;
        end else if (permit_rise) begin
            armed <= 1'b1;
        end else if (state == STATE_AW) begin
            armed <= 1'b0;
        end
    end

    // ====================================================================
    // REGION B : BURST FSM  (drawback generation + watchdog abort)
    // ====================================================================
    wire axi_b_done_pulse = m_axi_bvalid && m_axi_bready;
    reg axi_drawback_toggle;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            axi_drawback_toggle <= 1'b0;
        end else if (axi_b_done_pulse) begin
            axi_drawback_toggle <= ~axi_drawback_toggle;
        end
    end

    reg [2:0] sys_drawback_sync;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sys_drawback_sync <= 3'd0;
        end else begin
            sys_drawback_sync <= {sys_drawback_sync[1:0], axi_drawback_toggle};
        end
    end

    assign drawback = sys_drawback_sync[2] ^ sys_drawback_sync[1];

    wire fifo_rd_en;
    wire fifo_full;
    wire fifo_prog_empty;
    wire fifo_wr_rst_busy;
    wire fifo_rd_rst_busy;

    // This ready only protects the write side of the AXI FIFO.  It is not used
    // as a burst-start condition because a burst needs a complete FIFO threshold.
    assign px_ready = !fifo_full && !fifo_wr_rst_busy;

    wire can_start_burst = armed && !fifo_prog_empty && !fifo_rd_rst_busy;

    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            state              <= IDLE;
            m_axi_awaddr       <= 32'd0;
            m_axi_awvalid      <= 1'b0;
            m_axi_wvalid       <= 1'b0;
            m_axi_wlast        <= 1'b0;
            m_axi_bready       <= 1'b0;
            burst_beat_counter <= 8'd0;
        end else begin
            // confirm_drawback = Arbitration's release pulse fed back here.
            // On the happy path the FSM already returns to IDLE after B, so this
            // is only essential as the WATCHDOG ABORT: if the burst hangs and the
            // arbiter times out, this force-resets the FSM so it does not lock up.
            if (confirm_drawback) begin
                state              <= IDLE;
                m_axi_awaddr       <= 32'd0;
                m_axi_awvalid      <= 1'b0;
                m_axi_wvalid       <= 1'b0;
                m_axi_wlast        <= 1'b0;
                m_axi_bready       <= 1'b0;
                burst_beat_counter <= 8'd0;
            end
        
            case (state)
                IDLE: begin
                    m_axi_awvalid      <= 1'b0;
                    m_axi_wvalid       <= 1'b0;
                    m_axi_wlast        <= 1'b0;
                    m_axi_bready       <= 1'b0;
                    burst_beat_counter <= 8'd0;

                    if (can_start_burst) begin
                        m_axi_awaddr  <= cam_address_axi_s2;
                        m_axi_awvalid <= 1'b1;
                        state         <= STATE_AW;
                    end
                end

                STATE_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b1;
                        state         <= STATE_W;
                    end
                end

                STATE_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (burst_beat_counter == (BURST_LAST - 1'b1)) begin
                            m_axi_wlast        <= 1'b1;
                            burst_beat_counter <= burst_beat_counter + 1'b1;
                        end else if (burst_beat_counter == BURST_LAST) begin
                            m_axi_wvalid       <= 1'b0;
                            m_axi_wlast        <= 1'b0;
                            m_axi_bready       <= 1'b1;
                            burst_beat_counter <= 8'd0;
                            state              <= STATE_B;
                        end else begin
                            burst_beat_counter <= burst_beat_counter + 1'b1;
                        end
                    end
                end

                STATE_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        state        <= IDLE;
                    end
                end
            endcase
        end
    end

    assign fifo_rd_en = (state == STATE_W) && m_axi_wvalid && m_axi_wready;

    // ====================================================================
    // REGION C : DATA FIFO  (16-bit pixel in @clk  ->  64-bit beat out @axi_clk)
    // ====================================================================
    fifo_generator_axi u_fifo (
        .rst         (rst),
        .wr_clk      (clk),
        .rd_clk      (axi_clk),
        .din         (pixel),
        .full        (fifo_full),
        .wr_en       (px_valid && px_ready),
        .rd_en       (fifo_rd_en),
        .dout        (m_axi_wdata),
        .wr_rst_busy (fifo_wr_rst_busy),
        .rd_rst_busy (fifo_rd_rst_busy),
        .prog_empty  (fifo_prog_empty)
    );

endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: AXI4_Compiler
// Role: Compiles pixel data from multiple cameras into AXI4 write transactions
//       and manages a ring buffer system in DDR memory.
//
// Key Updates (Checklist v3):
// C1/C2: Corrected address strides. CAM_STRIDE is now 256MB (<<28) to support
//        a 16-deep ring buffer of 16MB frames without collision.
// C3:    Burst length changed to 2048 bytes (AWLEN=255) to match the 2KB line
//        stride, preventing DMA data misalignment.
// User:  System scaled to support 8 cameras.
//
//////////////////////////////////////////////////////////////////////////////////
module AXI4_Compiler(
    // ---- Input Data Interface ----
    input  wire [15:0]  pixel,          // Pixel data from MUX
    
    // ---- Coordinate & Control Interface (from MUX) ----
    input  wire [2:0]   cam_id,         // Camera ID (0-7)
    input  wire [9:0]   line_num,       // Line number within a frame
    input  wire         is_frame,       // Flag for the last line of a frame
    
    // ---- Clocks & Reset ----
    input  wire         clk,            // Pixel clock domain
    input  wire         axi_clk,        // AXI clock domain
    input  wire         rst,
    
    // ---- Flow Control ----
    input  wire         permit,         // Permission to start processing a line
    input  wire         px_valid,       // Pixel valid signal from MUX
    output wire         px_ready,       // Ready to accept a pixel

    // ---- System Control ----
    input  wire         watchdog,       // Watchdog timeout signal
    output wire         drawback,       // Pulse to release the arbiter
    
    // ---- Ring Buffer Handoff to Send_Control ----
    output reg          frame_done_pulse, // Single-cycle pulse on frame completion (in axi_clk domain)
    output reg  [2:0]   done_cam_id,      // ID of the camera whose frame was just completed
    output reg  [3:0]   done_frame_ptr,   // Ring buffer pointer for the completed frame

    // ---- AXI4 Write Address Channel ----
    input  wire         m_axi_awready,
    output reg  [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output reg          m_axi_awvalid,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,

    // ---- AXI4 Write Data Channel ----
    input  wire         m_axi_wready,
    output wire [63:0]  m_axi_wdata,
    output reg          m_axi_wvalid,
    output reg          m_axi_wlast,
    output wire [15:0]  m_axi_wstrb, // Note: Vivado 2018.3 requires this to be 16-bit for 64-bit data bus

    // ---- AXI4 Write Response Channel ----
    input  wire         m_axi_bvalid,
    output reg          m_axi_bready
);

    // ==========================================================================
    // Local Parameters for Readability and Maintenance
    // ==========================================================================
    localparam NUM_CAMERAS        = 8;
    localparam FRAME_DEPTH        = 16; // 16 frames per camera in ring buffer

    // C3 Fix: AWLEN=255 means 256 AXI beats. 256 * 8 bytes/beat = 2048 bytes
    localparam [7:0] BURST_LEN_2048B = 8'd255; 

    // C1/C2 Fix: Address stride definitions
    localparam CAM_STRIDE_SHIFT   = 28; // 256MB per camera (2^28)
    localparam FRAME_STRIDE_SHIFT = 24; // 16MB per frame (2^24)
    localparam LINE_STRIDE_SHIFT  = 11; // 2KB per line (2^11)

    // AXI constants
    assign m_axi_awlen   = BURST_LEN_2048B;
    assign m_axi_awsize  = 3'b011;       // 8 bytes (64-bit) per beat
    assign m_axi_awburst = 2'b01;        // INCR burst
    assign m_axi_wstrb   = 16'hFFFF;     // Write all 8 bytes of the 64-bit bus

    // FSM states
    localparam IDLE      = 2'd0, 
               STATE_AW  = 2'd1, 
               STATE_W   = 2'd2, 
               STATE_B   = 2'd3;
    reg [1:0] state;
    reg [7:0] burst_beat_counter;

    // ====================================================================
    // REGION A : Coordinate Capture & Clock Domain Crossing (CDC)
    // ====================================================================
    // 1. Latch incoming coordinates in the fast (pixel) clock domain
    reg permit_d;
    reg [2:0] cam_id_hold;
    reg [9:0] line_num_hold;
    reg       final_line_hold;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            permit_d        <= 1'b0;
            cam_id_hold     <= 3'd0;
            line_num_hold   <= 10'd0;
            final_line_hold <= 1'b0;
        end else begin
            permit_d <= permit;
            if (permit && !permit_d) begin
                cam_id_hold     <= cam_id;
                line_num_hold   <= line_num;
                final_line_hold <= is_frame;
            end
        end
    end

    // 2. Synchronize the 'permit' signal to the slow (AXI) clock domain
    reg permit_s1, permit_s2, permit_s2_d;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            permit_s1   <= 1'b0;
            permit_s2   <= 1'b0;
            permit_s2_d <= 1'b0;
        end else begin
            permit_s1   <= permit;
            permit_s2   <= permit_s1;
            permit_s2_d <= permit_s2;
        end
    end
    wire permit_rise = permit_s2 & ~permit_s2_d; // Edge detector for permit

    // 3. Safely capture the latched coordinates in the AXI domain when permit_rise occurs
    reg [2:0] cam_id_axi;
    reg [9:0] line_num_axi;
    reg       final_line_axi;
    reg       armed; // Flag indicating that coordinates are loaded and ready for an AXI transaction

    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            armed          <= 1'b0;
            cam_id_axi     <= 3'd0;
            line_num_axi   <= 10'd0;
            final_line_axi <= 1'b0;
        end else if (permit_rise) begin
            armed          <= 1'b1;
            cam_id_axi     <= cam_id_hold;
            line_num_axi   <= line_num_hold;
            final_line_axi <= final_line_hold;
        end else if (state == STATE_AW) begin
            // De-arm once the address has been sent
            armed <= 1'b0;
        end
    end

    // ====================================================================
    // REGION B : Ring Buffer Address Management
    // ====================================================================
    // A 16-deep ring buffer pointer for each of the 8 cameras
    reg [3:0] frame_ring_ptr [0:NUM_CAMERAS-1];
    integer i;
    
    // Dynamic physical address calculation using shifters for performance.
    // Address = Base + CamOffset + FrameOffset + LineOffset
    wire [31:0] target_awaddr = 32'h8000_0000 
                              + (cam_id_axi << CAM_STRIDE_SHIFT) 
                              + (frame_ring_ptr[cam_id_axi] << FRAME_STRIDE_SHIFT) 
                              + (line_num_axi << LINE_STRIDE_SHIFT);

    // Watchdog signal CDC (from fast clk to slow axi_clk)
    reg wd_s1, wd_s2;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) {wd_s2, wd_s1} <= 2'b00;
        else     {wd_s2, wd_s1} <= {wd_s1, watchdog};
    end
    wire watchdog_axi = wd_s2;

    // 'drawback' pulse generator to release arbiter (crosses from axi_clk to clk)
    wire axi_b_done_pulse = m_axi_bvalid && m_axi_bready;
    Alarmer alarmer_drawback (
        .clk_data (axi_b_done_pulse),
        .clk      (clk),
        .rst      (rst),
        .alarm    (drawback)
    );

    wire fifo_rd_en, fifo_full, fifo_prog_empty, fifo_wr_rst_busy, fifo_rd_rst_busy;
    assign px_ready = !fifo_full && !fifo_wr_rst_busy;
    wire can_start_burst = armed && !fifo_prog_empty && !fifo_rd_rst_busy;

    // ====================================================================
    // REGION C : Burst FSM & Ring Pointer Update
    // ====================================================================
    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            state              <= IDLE;
            m_axi_awaddr       <= 32'd0;
            m_axi_awvalid      <= 1'b0;
            m_axi_wvalid       <= 1'b0;
            m_axi_wlast        <= 1'b0;
            m_axi_bready       <= 1'b0;
            burst_beat_counter <= 8'd0;
            
            frame_done_pulse   <= 1'b0;
            done_cam_id        <= 3'd0;
            done_frame_ptr     <= 4'd0;
            
            for(i=0; i < NUM_CAMERAS; i=i+1) begin
                frame_ring_ptr[i] <= 4'd0;
            end
        end else begin
            // Default assignments to clear pulse signals
            frame_done_pulse <= 1'b0;
            
            case (state)
                IDLE: begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    burst_beat_counter <= 8'd0;

                    if (can_start_burst) begin
                        // Load the calculated address and start the AXI AW handshake
                        m_axi_awaddr  <= target_awaddr;
                        m_axi_awvalid <= 1'b1;
                        state         <= STATE_AW;
                    end
                end

                STATE_AW: begin
                    // Wait for AW channel to be ready
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b1; // Start the W channel transfer
                        state         <= STATE_W;
                    end
                end

                STATE_W: begin
                    // Manage the data burst transfer
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (burst_beat_counter == (BURST_LEN_2048B - 1'b1)) begin
                            // Penultimate beat, assert wlast for the next beat
                            m_axi_wlast        <= 1'b1;
                            burst_beat_counter <= burst_beat_counter + 1'b1;
                        end else if (burst_beat_counter == BURST_LEN_2048B) begin
                            // Last beat has been transferred
                            m_axi_wvalid       <= 1'b0;
                            m_axi_wlast        <= 1'b0;
                            m_axi_bready       <= 1'b1; // Ready to accept write response
                            burst_beat_counter <= 8'd0;
                            state              <= STATE_B;
                        end else begin
                            burst_beat_counter <= burst_beat_counter + 1'b1;
                        end
                    end
                end

                STATE_B: begin
                    // Wait for write response
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        
                        // If this was the last line of a frame, update the ring buffer
                        if (final_line_axi) begin
                            // 1. Signal completion to Send_Control
                            frame_done_pulse <= 1'b1;
                            done_cam_id      <= cam_id_axi;
                            done_frame_ptr   <= frame_ring_ptr[cam_id_axi];
                            
                            // 2. Advance this camera's write pointer to the next slot
                            frame_ring_ptr[cam_id_axi] <= frame_ring_ptr[cam_id_axi] + 1'b1;
                        end
                        
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // The FIFO read is enabled only during the data transfer phase
    assign fifo_rd_en = (state == STATE_W) && m_axi_wvalid && m_axi_wready;

    // ====================================================================
    // REGION D : Asynchronous Data FIFO
    // ====================================================================
    fifo_generator_axi u_fifo (
        .rst         (rst || watchdog_axi), // Asynchronous reset for FIFO
        .wr_clk      (clk),                 // Write clock (pixel domain)
        .rd_clk      (axi_clk),             // Read clock (AXI domain)
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

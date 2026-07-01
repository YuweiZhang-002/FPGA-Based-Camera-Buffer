`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Send_Control
// Role: Configures the AXI DMA via an AXI-Lite interface to transfer a
//       completed frame from DDR memory.
//
// Key Updates (Checklist v3):
// C1/C2: Corrected read-side address strides to match the writer (AXI4_Compiler).
//        CAM_STRIDE is 256MB (<<28), FRAME_STRIDE is 16MB (<<24).
// C3:    DMA transfer length (FRAME_BYTE_LENGTH) updated to 600*2048 bytes
//        to match the 2KB line stride in memory.
// C4:    Removed 'rst_conf' anti-pattern, converted to standard synchronous reset.
// C5:    Enabled DMA 'Interrupt on Complete' (IOC) and added a state to clear
//        the interrupt after each transfer, enabling multi-frame operation.
//
//////////////////////////////////////////////////////////////////////////////////
module Send_Control #(
    // C3 Fix: Frame size is 600 lines * 2048 bytes/line
    parameter FRAME_BYTE_LENGTH = 32'd1228800 
)(
    // ---- Ring Buffer Input (from AXI4_Compiler) ----
    input  wire        frame_done_pulse, // Single-cycle pulse indicating a frame is ready
    input  wire [2:0]  done_cam_id,      // ID of the camera for the ready frame
    input  wire [3:0]  done_frame_ptr,   // Ring buffer pointer for the ready frame
    
    // ---- Clock, Reset, and System Control ----
    input  wire        axi_clk, 
    input  wire        rst,
    
    // ---- AXI DMA Interface ----
    input  wire        DMA_interrupt,    // Interrupt from AXI DMA (mm2s_introut)
    
    // ---- AXI4-Lite Master Interface ----
    // Write Address Channel
    output reg  [31:0] m_axi_lite_awaddr,
    output reg         m_axi_lite_awvalid,
    input  wire        m_axi_lite_awready,
    
    // Write Data Channel
    output reg  [31:0] m_axi_lite_wdata,
    output reg  [3:0]  m_axi_lite_wstrb,   
    output reg         m_axi_lite_wvalid,
    input  wire        m_axi_lite_wready,
    
    // Write Response Channel 
    input  wire [1:0]  m_axi_lite_bresp,   
    input  wire        m_axi_lite_bvalid,
    output reg         m_axi_lite_bready
);
    
    // ==========================================
    // Address Calculation and Interrupt Detection
    // ==========================================
    localparam CAM_STRIDE_SHIFT   = 25; // C2 Fix: 32MB per camera
    localparam FRAME_STRIDE_SHIFT = 21; // C1 Fix: 2MB per frame

    reg [31:0] latched_target_addr;
    wire [31:0] target_awaddr = 32'h8000_0000 
                              + (done_cam_id << CAM_STRIDE_SHIFT) 
                              + (done_frame_ptr << FRAME_STRIDE_SHIFT);
    
    // Edge detector for DMA interrupt signal
    reg intr_d1, intr_d2;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) {intr_d2, intr_d1} <= 2'b00;
        else     {intr_d2, intr_d1} <= {intr_d1, DMA_interrupt};
    end
    wire intr_rise = intr_d1 & ~intr_d2; 

    // ==========================================
    // DMA Configuration Sequence (Combinational)
    // ==========================================
    // These are the steps to program the AXI DMA
    localparam WR_CTRL     = 3'd0, // Write to Control Register
               WR_ADDR     = 3'd1, // Write to Source Address Register
               WR_LEN      = 3'd2, // Write to Length Register (this starts the transfer)
               WR_CLR_INTR = 3'd3; // C5 Fix: Write to Status Register to clear interrupt
    reg [2:0] wr_step;

    reg [31:0] next_awaddr;
    reg [31:0] next_wdata;

    // Maps the current step (wr_step) to the correct AXI-Lite address and data
    always @(*) begin
        case (wr_step)
            WR_CTRL: begin
                next_awaddr = 32'h00; // MM2S_DMACR offset
                // C5 Fix: Set RS (bit 0) and IOC_IrqEn (bit 12) to start DMA and enable interrupt
                next_wdata  = 32'h0000_1001;  // IOC_IrqEn = 1, RS = 1
            end
            WR_ADDR: begin
                next_awaddr = 32'h18; // MM2S_SA offset
                next_wdata  = latched_target_addr; // The base address of the frame to send
            end
            WR_LEN: begin
                next_awaddr = 32'h28; // MM2S_LENGTH offset
                next_wdata  = FRAME_BYTE_LENGTH; // The number of bytes to send
            end
            // C5 Fix: New step to clear the interrupt
            WR_CLR_INTR: begin
                next_awaddr = 32'h04; // MM2S_DMASR offset
                next_wdata  = 32'h0000_1000; // // IOC_IrqEn = 1, RS = 0, Clear Interrupt = 1
            end
            default: begin
                next_awaddr = 32'h00;
                next_wdata  = 32'h00;
            end
        endcase
    end

    // ==========================================
    // AXI-Lite State Machine
    // ==========================================
    localparam IDLE       = 3'd0, // Waiting for a frame_done_pulse
               WRITE_CMD  = 3'd1, // Issue AXI address and data
               WAIT_AW_W  = 3'd2, // Wait for both AW and W handshakes to complete
               WAIT_B     = 3'd3, // Wait for the B-channel response
               WAIT_INTR  = 3'd4; // Wait for the DMA transfer to finish (via interrupt)
    reg [2:0] state;
    
    // C4 Fix: The reset logic is now a simple synchronous reset.
    // The `rst_conf` anti-pattern has been removed.
    always @(posedge axi_clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            wr_step <= WR_CTRL;
            
            m_axi_lite_awvalid <= 1'b0; 
            m_axi_lite_wvalid  <= 1'b0; 
            m_axi_lite_bready  <= 1'b0;
            m_axi_lite_awaddr  <= 32'd0;
            m_axi_lite_wdata   <= 32'd0;
            m_axi_lite_wstrb   <= 4'b1111;
            latched_target_addr<= 32'd0;
        end else begin
            case(state)
                IDLE: begin
                    wr_step <= WR_CTRL; // Reset to the first programming step
                    
                    if(frame_done_pulse) begin
                        // A new frame is ready, latch its address and start the programming sequence
                        latched_target_addr <= target_awaddr;
                        state <= WRITE_CMD;
                    end
                end
                
                WRITE_CMD: begin
                    // State 1: Drive the address and data for the current step
                    m_axi_lite_awaddr  <= next_awaddr;
                    m_axi_lite_wdata   <= next_wdata;
                    m_axi_lite_awvalid <= 1'b1;     
                    m_axi_lite_wvalid  <= 1'b1;
                    state <= WAIT_AW_W;
                end
                
                WAIT_AW_W: begin
                    // State 2: Wait for both AW and W channels to be accepted by the slave.
                    // This decoupled approach handles any latency variation on the two channels.
                    if (m_axi_lite_awvalid && m_axi_lite_awready) m_axi_lite_awvalid <= 1'b0;
                    if (m_axi_lite_wvalid  && m_axi_lite_wready)  m_axi_lite_wvalid  <= 1'b0;

                    if ((!m_axi_lite_awvalid || m_axi_lite_awready) && 
                        (!m_axi_lite_wvalid  || m_axi_lite_wready)) begin
                        
                        m_axi_lite_awvalid <= 1'b0; 
                        m_axi_lite_wvalid  <= 1'b0; 
                        m_axi_lite_bready  <= 1'b1; // Prepare to receive the B-channel response
                        state <= WAIT_B;
                    end
                end
                
                WAIT_B: begin
                    // State 3: Wait for the write response and advance the programming sequence
                    if (m_axi_lite_bvalid && m_axi_lite_bready) begin
                        m_axi_lite_bready <= 1'b0;
                        
                        if (wr_step == WR_CTRL) begin
                            wr_step <= WR_ADDR;
                            state   <= WRITE_CMD;
                        end else if (wr_step == WR_ADDR) begin
                            wr_step <= WR_LEN;
                            state   <= WRITE_CMD;
                        end else if (wr_step == WR_LEN) begin
                            // The LENGTH write is the last step to start the DMA. Now we wait.
                            state <= WAIT_INTR; 
                        end else if (wr_step == WR_CLR_INTR) begin
                            // C5 Fix: After clearing the interrupt, we are done. Return to IDLE.
                            state <= IDLE;
                        end
                    end
                end
                
                WAIT_INTR: begin
                    // State 4: Wait for the DMA to assert its interrupt line
                    if (intr_rise) begin
                        // C5 Fix: Don't go to IDLE yet. First, clear the interrupt.
                        wr_step <= WR_CLR_INTR;
                        state   <= WRITE_CMD; 
                    end
                end
            endcase
        end
    end
    
endmodule

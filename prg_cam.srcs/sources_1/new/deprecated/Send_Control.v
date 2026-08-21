`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): DMA programming is not part of the
// active SRAM/FIFO stream. Define ENABLE_DEPRECATED_AXI_DDR2 for legacy use.
`ifdef ENABLE_DEPRECATED_AXI_DDR2
// 注释导读（历史 DMA 控制器）：
// - wr_step 是“当前要写哪个 DMA 寄存器”的微步骤：CTRL->ADDR->LEN，DMA
//   完成后再写 CLR_INTR；next_awaddr/next_wdata 是该步骤的组合译码。
// - state 是 AXI-Lite 握手 SM：IDLE->WRITE_CMD->WAIT_AW_W->WAIT_B；
//   写 LENGTH 后进入 WAIT_INTR，检测 interrupt 上升沿再清中断。
// - AW 与 W 是独立通道，awvalid/wvalid 分别保持到各自 ready，二者都完成
//   后才置 bready；不能把其中任一 ready 当成整个寄存器写完成。
// - reference_valid/reference 当前没有形成有效输出逻辑，属于未完成历史功能。
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Send_Control
// Role: AXI-Lite write master for programming AXI DMA MM2S transfers.
//       It latches a completed frame descriptor, programs DMA registers,
//       waits for the interrupt, and clears the interrupt before returning IDLE.
//
// Notes:
// - This module is intentionally write-only on the AXI-Lite side.
// - If two AXI DMA instances are used, instantiate one Send_Control per DMA
//   or place an AXI interconnect in front of the Lite slaves. Do not wire one
//   AXI-Lite master bus directly to two DMA control ports.
//
// Key Updates (Checklist v3):
// C1/C2: Corrected read-side address strides to match the writer (AXI4_Compiler).
//        CAM_STRIDE is 32MB (<<25), FRAME_STRIDE is 2MB (<<21).
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
    
    // ---- Message to inform Reference Controller ----
    output wire        reference,        // Message to System_RefControl
    
    // ---- AXI4-Lite Master Interface ----
    // Write Address Channel
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite AWADDR"  *) output reg  [31:0] m_axi_lite_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite AWVALID"  *) output reg         m_axi_lite_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite AWREADY"  *) input  wire        m_axi_lite_awready,
    
    // Write Data Channel
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite WDATA"   *) output reg  [31:0] m_axi_lite_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite WSTRB"   *) output reg  [3:0]  m_axi_lite_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite WVALID"   *) output reg         m_axi_lite_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite WREADY"   *) input  wire        m_axi_lite_wready,
    
    // Write Response Channel 
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite BRESP"    *) input  wire [1:0]  m_axi_lite_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite BVALID"   *) input  wire        m_axi_lite_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_lite BREADY"   *) output reg         m_axi_lite_bready
);

    localparam MODULE_DEPRECATED = 1'b1;
    
    // ==========================================
    // Address Calculation and Interrupt Detection
    // ==========================================
    localparam CAM_STRIDE_SHIFT   = 25; // 32MB per camera
    localparam FRAME_STRIDE_SHIFT = 21; // 2MB per frame

    // AXI DMA MM2S register map
    localparam [31:0] DMA_MM2S_DMACR   = 32'h0000_0000;
    localparam [31:0] DMA_MM2S_DMASR   = 32'h0000_0004;
    localparam [31:0] DMA_MM2S_SA      = 32'h0000_0018;
    localparam [31:0] DMA_MM2S_LENGTH  = 32'h0000_0028;

    // AXI DMA control bits used by this design
    localparam [31:0] DMA_DMACR_RS        = 32'h0000_0001;
    localparam [31:0] DMA_DMACR_IOC_IRQEN = 32'h0000_1000;
    localparam [31:0] DMA_DMASR_IOC_IRQ   = 32'h0000_1000;

    reg [31:0] latched_target_addr; // frame_done 时冻结，防止描述符后续变化
    wire [31:0] target_awaddr = 32'h8000_0000 
                              + (done_cam_id << CAM_STRIDE_SHIFT) 
                              + (done_frame_ptr << FRAME_STRIDE_SHIFT);
    
    
    // Edge detector for DMA interrupt signal
    reg intr_d1, intr_d2; // 中断两拍历史，用于 clk 域上升沿检测
    always @(posedge axi_clk or posedge rst) begin
        if (rst) {intr_d2, intr_d1} <= 2'b00;
        else     {intr_d2, intr_d1} <= {intr_d1, DMA_interrupt};
    end
    wire intr_rise = intr_d1 & ~intr_d2; 

    // Flags for storing the reference frame's status
    // First assume none of the cameras have the reference frame
    reg [7:0] reference_valid = 8'b00000000; // bit[cam_id]，历史未完成功能
    assign reference = 1'b0;
    
    // ==========================================
    // DMA Configuration Sequence (Combinational)
    // ==========================================
    // These are the steps to program the AXI DMA
    localparam WR_CTRL     = 3'd0, // Write to Control Register
               WR_ADDR     = 3'd1, // Write to Source Address Register
               WR_LEN      = 3'd2, // Write to Length Register (this starts the transfer)
               WR_CLR_INTR = 3'd3; // C5 Fix: Write to Status Register to clear interrupt
    reg [2:0] wr_step; // 组合寄存器映射选择器，不是 AXI SM state

    reg [31:0] next_awaddr; // 由 wr_step 组合生成的下一写地址
    reg [31:0] next_wdata;  // 由 wr_step 组合生成的下一写数据

    // Maps the current step (wr_step) to the correct AXI-Lite address and data
    always @(*) begin
        // 每个 case 分支都为两个信号赋值，default 防止非法 wr_step 推断 latch。
        case (wr_step)
            WR_CTRL: begin
                next_awaddr = DMA_MM2S_DMACR;
                // Set RS (bit 0) and IOC_IrqEn (bit 12) to start DMA and enable interrupt.
                next_wdata  = DMA_DMACR_RS | DMA_DMACR_IOC_IRQEN;
            end
            WR_ADDR: begin
                next_awaddr = DMA_MM2S_SA;
                next_wdata  = latched_target_addr;
            end
            WR_LEN: begin
                next_awaddr = DMA_MM2S_LENGTH;
                next_wdata  = FRAME_BYTE_LENGTH;
            end
            // Clear the interrupt after transfer completes.
            WR_CLR_INTR: begin
                next_awaddr = DMA_MM2S_DMASR;
                next_wdata  = DMA_DMASR_IOC_IRQ;
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
    reg [2:0] state; // AXI-Lite 配置/等待中断主状态机
    
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
                    // 只有单周期 frame_done_pulse 能启动；同时锁存计算后地址。
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
                    // BRESP 未被检查；历史逻辑把任意 BVALID 都视为成功。
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
                    // intr_rise 而非 interrupt 电平，避免高电平期间重复清中断。
                    // State 4: Wait for the DMA to assert its interrupt line
                    if (intr_rise) begin
                        // Add on: Set the flags
                        if(done_frame_ptr == 4'd0)        reference_valid[done_cam_id] <= 1'b0;
                        else if(done_frame_ptr == 4'd15)  reference_valid[done_cam_id] <= 1'b0;
                        // C5 Fix: Don't go to IDLE yet. First, clear the interrupt.
                        wr_step <= WR_CLR_INTR;
                        state   <= WRITE_CMD; 
                    end
                end
            endcase
        end
    end
    
endmodule
`endif

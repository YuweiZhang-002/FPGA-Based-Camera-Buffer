`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/19 18:55:10
// Design Name: 
// Module Name: AXI4_Compiler
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


`timescale 1ns / 1ps

module AXI4_Compiler(
    // 数据接收/发送处理模块
    input [15:0]      pixel,
    input [31:0]      cam_address,
    input             clk, axi_clk,
    input  wire       rst,
    input             permit,
    
    // AXI 写数据通道
    output [127:0]    axi_data,
    
    // 特殊模块： 解除仲裁机占用 (此时钟域为 clk)
    output wire       drawback,
    
    // AW 通道数据发送/接收模块
    input             m_axi_awready,
    output reg  [31:0]m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output reg        m_axi_awvalid,
    output wire [2:0] m_axi_awsize,   // 必须是 3-bit
    output wire [1:0] m_axi_awburst,  // 必须是 2-bit

    // W 通道数据发送/接收模块
    input  wire       m_axi_wready,
    output wire [127:0] m_axi_wdata,
    output reg        m_axi_wvalid,
    output reg        m_axi_wlast,
    output wire [15:0]m_axi_wstrb,    // 16-bit 掩码

    // B 通道发送/接收模块 (写响应)
    input  wire       m_axi_bvalid,
    output reg        m_axi_bready
    );

    // 参数配置
    assign m_axi_awlen   = 8'd99;          // 100 拍突发
    assign m_axi_awsize  = 3'd4;           // 2^4 = 16 Bytes (128-bit)
    assign m_axi_awburst = 2'b01;          // INCR 递增模式
    assign m_axi_wstrb   = 16'hFFFF;       // 16 个字节均有效
    assign axi_data      = m_axi_wdata;    // 预留端口对接

    reg [6:0] burst_beat_counter; 

    localparam IDLE = 2'd0, STATE_AW = 2'd1, STATE_W = 2'd2, STATE_B = 2'd3;
    reg [1:0] state;

    // ==========================================================================
    // 【CDC①：快到慢】permit 同步 (clk 域 -> axi_clk 域)
    // ==========================================================================
    reg permit_s1, permit_s2;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) {permit_s2, permit_s1} <= 2'b00;
        else     {permit_s2, permit_s1} <= {permit_s1, permit};
    end
    wire permit_sync = permit_s2;

    reg permit_sync_d;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) permit_sync_d <= 1'b0;
        else     permit_sync_d <= permit_sync;
    end
    wire permit_rise = permit_sync & ~permit_sync_d;

    reg armed;
    always @(posedge axi_clk or posedge rst) begin
        if (rst)               armed <= 1'b0;
        else if (permit_rise)  armed <= 1'b1;   
        else if (state == STATE_AW) armed <= 1'b0; 
    end

    // ==========================================================================
    // 【CDC②：慢到快】drawback 翻转同步 (axi_clk 域 -> clk 域)
    // ==========================================================================
    // 1. AXI 域：抓取单拍脉冲，转为电平翻转 (Toggle)
    wire axi_b_done_pulse = (m_axi_bvalid && m_axi_bready);
    reg  axi_drawback_toggle;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) axi_drawback_toggle <= 1'b0;
        else if (axi_b_done_pulse) axi_drawback_toggle <= ~axi_drawback_toggle;
    end

    // 2. SYS/Pixel 域 (clk)：打两拍同步翻转信号，并提取边缘
    reg [2:0] sys_drawback_sync;
    always @(posedge clk or posedge rst) begin
        if (rst) sys_drawback_sync <= 2'd0;
        else     sys_drawback_sync <= {sys_drawback_sync[0], axi_drawback_toggle};
    end

    // 3. 输出给仲裁机的 drawback 脉冲 (在 clk 时钟下为 1 拍高电平)
    assign drawback = sys_drawback_sync[1] ^ sys_drawback_sync[0];

    // ==========================================================================
    // AXI4 写总线状态机
    // ==========================================================================
    always @(posedge axi_clk or posedge rst) begin
        if(rst) begin
            state              <= IDLE;
            m_axi_awvalid      <= 1'b0;
            m_axi_wvalid       <= 1'b0;
            m_axi_wlast        <= 1'b0;
            m_axi_bready       <= 1'b0;
            burst_beat_counter <= 7'd0;
            m_axi_awaddr       <= 32'd0; 
        end else begin
            case(state)
                IDLE: begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    burst_beat_counter <= 7'd0;

                    if (armed && !fifo_prog_empty && !fifo_rd_rst_busy) begin
                        state         <= STATE_AW;
                        m_axi_awvalid <= 1'b1;
                        m_axi_awaddr  <= cam_address; // 每次突发闩锁外部地址
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
                         if (burst_beat_counter == m_axi_awlen - 1) begin
                             m_axi_wlast <= 1'b1;
                             burst_beat_counter <= burst_beat_counter + 1;
                         end else if (burst_beat_counter == m_axi_awlen) begin
                             m_axi_wvalid <= 1'b0;
                             m_axi_wlast  <= 1'b0;
                             m_axi_bready <= 1'b1; 
                             state        <= STATE_B;
                         end else begin
                             burst_beat_counter <= burst_beat_counter + 1;
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
    
    // ==========================================
    // 例化异步 FIFO
    // ==========================================
    wire   fifo_rd_en = (state == STATE_W) && m_axi_wvalid && m_axi_wready;
    wire   fifo_prog_empty;
    wire   fifo_wr_rst_busy;
    wire   fifo_rd_rst_busy;

    fifo_generator_1 u_fifo (
        .wr_clk      (clk),                              // VGA / 像素写时钟
        .rd_clk      (axi_clk),                          // AXI 读时钟
        .din         (pixel),                            // 16-bit 输入
        
        // ⚠️ 致命待定点：wr_en 逻辑
        .wr_en       (permit && !fifo_wr_rst_busy),
        
        .rd_en       (fifo_rd_en),                       // AXI 状态机控制读
        .dout        (m_axi_wdata),                      // 128-bit 输出直连 AXI WDATA
        .wr_rst_busy (fifo_wr_rst_busy),                 // 接出
        .rd_rst_busy (fifo_rd_rst_busy),                 // 参与启动把关
        .prog_empty  (fifo_prog_empty)                   // 阈值判据
    );

endmodule

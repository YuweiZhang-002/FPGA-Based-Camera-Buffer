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


module AXI4_Compiler(
    // 数据接收/发送处理模块，
    input [15:0]      pixel,
    input [1:0]       cam_id,
    input             clk, axi_clk,
    input  wire       rst,
    input             permit,
    output [127:0]    axi_data,
    
    // 特殊模块： 解除仲裁机占用
    output wire       drawback,
    
    // AW 通道数据发送/接收模块
    input                m_axi_awready,
    output reg  [31:0]   m_axi_awaddr,
    output wire [7:0]    m_axi_awlen,
    output reg           m_axi_awvalid,
    output wire [2:0]    m_axi_awsize,   // 必须是 3-bit
    output wire [1:0]    m_axi_awburst,  // 必须是 2-bit

    // W 通道数据发送/接收模块
    input  wire          m_axi_wready,
    output wire [255:0]  m_axi_wdata,
    output reg           m_axi_wvalid,
    output reg           m_axi_wlast,
    output wire [31:0]   m_axi_wstrb,    // 256-bit 对应 32-bit 的掩码
    
    // B 通道发送/接收模块 (写响应)
    input  wire          m_axi_bvalid,
    output reg           m_axi_bready    
    );
    
    // 参数配置
    assign m_axi_awlen   = 8'd99;  
    assign m_axi_awsize  = 3'd4;       // 16 Bytes per beat
    assign m_axi_awburst = 2'b01;      // INCR 递增模式
    assign m_axi_wstrb   = 16'hFFFF;   // 所有 32 个字节均有效
    
    reg [6:0] burst_beat_counter; // 计数器需扩大，因为要数到 100
    
    localparam IDLE = 2'd0, STATE_AW = 2'd1, STATE_W = 2'd2, STATE_B = 2'd3;
    reg [1:0] state;
    
    // 定义解除占用
    assign drawback = (m_axi_bvalid && m_axi_bready);
    
    always @(posedge axi_clk or posedge rst) begin
        if(rst) begin
            state              <= IDLE;
            m_axi_awvalid      <= 1'b0;
            m_axi_wvalid       <= 1'b0;
            m_axi_wlast        <= 1'b0;
            m_axi_bready       <= 1'b0;
            burst_beat_counter <= 7'd0;
            m_axi_awaddr       <= 32'h8000_0000 + (32'b1 << 25)*cam_id; // 初始化基地址
        end else begin
            case(state)
                IDLE: begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    burst_beat_counter <= 7'd0;
                    
                    // 【关键触发器】：FIFO 内部数据 >= 50 拍时，拉低 prog_empty
                    if (permit) begin 
                        state         <= STATE_AW;
                        m_axi_awvalid <= 1'b1;
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
                             // 倒数第二拍，拉高 WLAST
                             m_axi_wlast <= 1'b1;
                             burst_beat_counter <= burst_beat_counter + 1;
                         end else if (burst_beat_counter == m_axi_awlen) begin
                             // 最后一拍发送完毕
                             m_axi_wvalid <= 1'b0;
                             m_axi_wlast  <= 1'b0;
                             m_axi_bready <= 1'b1; // 【修正】主机拉高 BREADY 等待响应
                             state        <= STATE_B;
                         end else begin
                             burst_beat_counter <= burst_beat_counter + 1;
                         end
                     end
                end
                
                STATE_B: begin
                    // 【修正】等待从机发来 BVALID
                    if (m_axi_bvalid && m_axi_bready) begin 
                        m_axi_bready <= 1'b0;
                        
                        // 地址自增，偏移一行的数据量 (1600 字节)
                        m_axi_awaddr <= m_axi_awaddr + 32'd1600; 
                        state        <= IDLE;
                    end
                end
            endcase
        end
    end
    
    // ==========================================
    // 例化异步 FIFO (32-in, 256-out, FWFT 模式)
    // ==========================================
    // 只有在发送 W 数据且握手成功时，才从 FIFO 弹出一个 256-bit 数据
    assign fifo_rd_en = (state == STATE_W) && m_axi_wvalid && m_axi_wready;

    fifo_generator_1 u_fifo (
        .wr_clk      (clk),              // VGA 时钟
        .rd_clk      (axi_clk),          // AXI 时钟
        .din         (overflow_data),    // 32-bit 输入
        .wr_en       (ready),            // VGA 有效电平作为写使能
        .rd_en       (fifo_rd_en),       // AXI 状态机控制读
        .dout        (m_axi_wdata),      // 256-bit 输出直连 AXI
        .wr_rst_busy (),
        .rd_rst_busy (),
        .prog_empty  () 
    );

    
endmodule

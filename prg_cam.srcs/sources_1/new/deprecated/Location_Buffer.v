`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): old location/Ethernet container.
`ifdef ENABLE_DEPRECATED_LOCATION_PATH
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/23 20:27:04
// Design Name: 
// Module Name: Location_Buffer
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


module Location_Buffer #(
    // 每个相机的缓存深度是 16 字节，总计 64 字节
    parameter UNIT_DEPTH = 16,
    parameter TOTAL_DEPTH = 64
)(
    // ==========================================
    // 1. 并行接收层 (8-bit 并行输入)
    // ==========================================
    input  wire [7:0] cam0_loc, cam1_loc, cam2_loc, cam3_loc,
    input  wire [7:0] cam0_bufcnt, cam1_bufcnt, cam2_bufcnt, cam3_bufcnt,
    input  wire [1:0] cam0_id, cam1_id, cam2_id, cam3_id,
    
    // grant[i] 为 1 代表对应通道当前有有效的 loc 字节需要 Append
    input  wire [3:0] grant,      
    input  wire       frame_done, // 帧结束脉冲：触发"封箱"并激活 16-bit 发送机
    
    input  wire       clk, rst,
    
    // ==========================================
    // 2. 以太网发送层 (16-bit AXI4-Stream 接口)(待定)
    // ==========================================
    output reg  [15:0] eth_tx_data,  // 吐给 Ethernet MAC 的 16-bit 数据
    output reg         eth_tx_valid, // 数据有效标志
    output reg         eth_tx_last,  // TLAST：表示 64 字节包的最后一次 16-bit 传输
    input  wire        eth_tx_ready  // MAC 端反馈的 Ready 信号
);

    localparam MODULE_DEPRECATED = 1'b1;
    
    // ==========================================
    // 模块 A：统一的 64 字节巨型缓冲池
    // ==========================================
    reg [7:0] unified_buf [0:TOTAL_DEPTH-1];
    
    // 4 个独立的写入局部游标，范围永远是 0 ~ 15
    reg [3:0] wr_ptr0, wr_ptr1, wr_ptr2, wr_ptr3;
    
    // ==========================================
    // 模块 B：纯并行接收逻辑 (无死锁追加 Append)
    // ==========================================
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            wr_ptr0 <= 4'd0; wr_ptr1 <= 4'd0;
            wr_ptr2 <= 4'd0; wr_ptr3 <= 4'd0;
        end else begin
            if (frame_done) begin
                wr_ptr0 <= 4'd0; wr_ptr1 <= 4'd0;
                wr_ptr2 <= 4'd0; wr_ptr3 <= 4'd0;
            end else begin
                // 【通道 0 追加】：基地址为 0
                if (grant[0]) begin
                    unified_buf[0 + wr_ptr0] <= cam0_loc;
                    if (wr_ptr0 == 13) begin
                        unified_buf[0 + 14] <= {6'd0, cam0_id};
                        unified_buf[0 + 15] <= cam0_bufcnt;
                    end
                    wr_ptr0 <= wr_ptr0 + 1'b1;
                end
                
                // 【通道 1 追加】：基地址为 16
                if (grant[1]) begin
                    unified_buf[16 + wr_ptr1] <= cam1_loc;
                    if (wr_ptr1 == 13) begin
                        unified_buf[16 + 14] <= {6'd0, cam1_id};
                        unified_buf[16 + 15] <= cam1_bufcnt;
                    end
                    wr_ptr1 <= wr_ptr1 + 1'b1;
                end
                
                // 【通道 2 追加】：基地址为 32
                if (grant[2]) begin
                    unified_buf[32 + wr_ptr2] <= cam2_loc;
                    if (wr_ptr2 == 13) begin
                        unified_buf[32 + 14] <= {6'd0, cam2_id};
                        unified_buf[32 + 15] <= cam2_bufcnt;
                    end
                    wr_ptr2 <= wr_ptr2 + 1'b1;
                end
                
                // 【通道 3 追加】：基地址为 48
                if (grant[3]) begin
                    unified_buf[48 + wr_ptr3] <= cam3_loc;
                    if (wr_ptr3 == 13) begin
                        unified_buf[48 + 14] <= {6'd0, cam3_id};
                        unified_buf[48 + 15] <= cam3_bufcnt;
                    end
                    wr_ptr3 <= wr_ptr3 + 1'b1;
                end
            end
        end
    end
endmodule
`endif

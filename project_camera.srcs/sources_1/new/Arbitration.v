`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/18 19:04:27
// Design Name: 
// Module Name: Arbitration
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


module Arbitration(
    input            clk,
    input            rst,
    input [7:0]      request,   // 8 channels request (level)
    input            released,  // AXI4 complete the sending progress
    output reg       accept,    // Grant signals
    output reg [2:0] cam_id,    // Camera ID number
    output reg       drawback
);

    reg locked;
    reg [2:0] rr_ptr;

    wire [15:0] double_req = {request, request};
    wire [7:0] shifted_req = double_req >> rr_ptr;
    
    wire [2:0] grant_idx = shifted_req[0] ? 3'd0 :
                           shifted_req[1] ? 3'd1 :
                           shifted_req[2] ? 3'd2 :
                           shifted_req[3] ? 3'd3 :
                           shifted_req[4] ? 3'd4 :
                           shifted_req[5] ? 3'd5 :
                           shifted_req[6] ? 3'd6 :
                           shifted_req[7] ? 3'd7 : 3'd0;
                           
    wire any_req = (request != 8'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            accept <= 1'd0;
            locked <= 1'b0;
            rr_ptr <= 3'd0;
        end else begin
            if (locked) begin
                // 解锁条件：当前锁定信道发出完成的 withdraw 脉冲，或该信道请求撤销
                if (released) begin
                    locked   <= 1'b0;
                    accept   <= 1'd0;
                    drawback <= 1'd1;
                end
            end else begin
                // 如果有请求且没有锁定，执行轮询仲裁，锁定当前选中通道，直至本行发送完成?
                if (any_req) begin
                    accept <= 1'b1;
                    cam_id <= rr_ptr + grant_idx;
                    locked <= 1'b1;
                    rr_ptr <= rr_ptr + grant_idx + 1'b1; // 更新指针，下次从当前授权的下一个开始?
                end
            end
        end
    end
endmodule

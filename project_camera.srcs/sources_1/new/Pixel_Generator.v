`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/17 20:38:59
// Design Name: 
// Module Name: Pixel_Generator
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



module Pixel_Generator(
    input  wire    [3:0]  pins,      // 每拍输入 4-bit 数据
    input  wire           cam_clk,   // Acquire clock from RP2354A
    input  wire           clk, 
    input  wire           rst, 
    output reg [15:0] out,       // 【修改】降为 16-bit 输出
    output reg        confirm    // 输出完成脉冲 (1拍)
);

    wire valid;

    Alarmer alarmer_pixel(
    .clk_data(cam_clk), .clk(clk), .rst(rst),
    .alarm(valid)
    );
    

    reg [15:0] data;             // 【修改】内部移位寄存器降为 16-bit
    reg [1:0]  cnt;              // 【修改】计数器降为 2-bit (只需数 0~3)

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            confirm <= 1'b0;
            cnt     <= 2'd0;     // 复位归零
            data    <= 16'd0;    
            out     <= 16'd0;    // 养成好习惯：复位时初始化 output
        end else begin
            // 默认情况下，完成脉冲必须立刻拉低，保证它只有 1 拍宽
            confirm <= 1'b0;     
            
            if (valid) begin
                // 【核心移位机制】：左移 4 位，并将新来的 4-bit 塞入最低位
                data <= {data[11:0], pins};   
                
                // 【修改】因为 16 = 4 * 4，所以只需要 4 拍（计数器 0, 1, 2, 3）
                if (cnt == 2'd3) begin
                    // 在第 4 拍，直接拼装出完整的 16-bit 并输出 (Off-by-one 补偿)
                    out     <= {data[11:0], pins};  
                    confirm <= 1'b1;               // 点燃完成脉冲
                    cnt     <= 2'd0;               // 计数器清零，准备下一轮
                end else begin
                    cnt     <= cnt + 2'd1;         // 未满 4 拍，计数器推进
                end
            end
        end
    end
endmodule
`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): the active datapath is entirely in
// the pclk domain, so the old edge-to-system-clock pulse converter is unused.
`ifdef ENABLE_DEPRECATED_CAMERA_FRONTEND
// 注释导读：整个 module 受宏保护，默认预处理阶段即被移除。若恢复旧前端，
// clk_data 是异步 camera clock，clk 是系统域；stage_1/stage_2 构成两拍
// 采样链，alarm=stage_1 & ~stage_2 表示检测到同步后上升沿。该旧版本没有
// ASYNC_REG 约束属性，因此当前实现应使用上级目录中的新版 Alarmer。
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/19 10:31:39
// Design Name: 
// Module Name: Alarmer
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


module Alarmer(
    // clk_data=异步源；clk=目标系统时钟；rst=高有效异步复位；
    // alarm=clk 域单周期上升沿脉冲。
    input clk_data, clk, rst,
    output alarm
    );

    localparam MODULE_DEPRECATED = 1'b0;
    
    reg stage_1, stage_2; // 当前/上一拍同步样本；非业务状态 flags
    // 组合边沿检测，不具有保持功能。
    assign alarm = (stage_1 && (!stage_2));
    
    always @(posedge clk or posedge rst)
    begin
        if (rst)
        begin
            stage_1 <= 1'b0;
            stage_2 <= 1'b0;
        end
        else begin
            // 非阻塞赋值使 stage_2 读取上一拍 stage_1。
            stage_1 <= clk_data;
            stage_2 <= stage_1;
        end
    end
endmodule
`endif

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/05 11:41:28
// Design Name: 
// Module Name: System_ClkControl
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


module System_ClkControl (
    input  wire clk_sys,    // 来自 Clocking Wizard 的输出时钟
    input  wire locked,     // 来自 Clocking Wizard 的 locked 信号
    output wire rst_sys_n   // 输出给整个下游系统的复位信号（低电平复位）
);

    // OPTIONAL UTILITY ONLY: Camera_Pipeline does not instantiate this block;
    // its active datapath and reset release are entirely in the pclk domain.
    localparam MODULE_DEPRECATED = 1'b0;

    // STREAMING_CHUNK:定义复位同步移位寄存器...
    // 使用两级触发器打拍，防止亚稳态，并实现异步复位、同步释放
    reg [1:0] reset_sync_reg = 2'b00;

    // STREAMING_CHUNK:实现异步复位，同步释放逻辑...
    always @(posedge clk_sys or negedge locked) begin
        if (!locked) begin
            // 当 PLL 未锁定时（locked=0），立刻强制整个系统进入复位
            reset_sync_reg <= 2'b00;
        end else begin
            // 当 PLL 锁定后（locked=1），经过两拍 clk_sys 同步后释放复位
            reset_sync_reg <= {reset_sync_reg[0], 1'b1};
        end
    end

    // STREAMING_CHUNK:输出同步后的复位信号...
    assign rst_sys_n = reset_sync_reg[1]; 
    // 下游模块只有在 rst_sys_n 为 1 时，才开始正常工作

endmodule

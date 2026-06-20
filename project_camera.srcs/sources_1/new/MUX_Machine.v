`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/18 19:27:40
// Design Name: 
// Module Name: MUX_Machine
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


module MUX_Machine(
    // 4 路摄像头的独立数据输入 (根据你的定义使用 16-bit)
    input  wire [15:0] pixel_in_0,
    input  wire [15:0] pixel_in_1,
    input  wire [15:0] pixel_in_2,
    input  wire [15:0] pixel_in_3,
    
    // 控制信号
    input  wire [3:0]  grant,       // 授权信号 (理论上应为独热码 One-Hot)
    input  wire        clk,
    input  wire        rst,         // 良好的硬件设计必须有复位
    
    // 输出端口 (注意修正了你原代码中漏掉的逗号)
    output reg  [15:0] pixel_out,
    output reg  [1:0]  cam_id,
    output wire        work
);

    // ==========================================
    // 状态指示：只要 grant 不是全 0，说明当前有通路正在工作
    // ==========================================
    assign work = (grant != 4'd0) ? 1'b1 : 1'b0;

    // ==========================================
    // 核心数据路由 (Data Routing)
    // 采用同步时序逻辑打拍输出，确保满足高速总线的时序要求
    // ==========================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pixel_out <= 16'd0;
        end else begin
            // 在硬件中，针对按位开启的逻辑，最标准且极省资源的写法是 case 独热码匹配
            case (grant)
                4'b0001: begin
                    pixel_out <= pixel_in_0; // 第 0 号 Bit 为高，导通通道 0
                    cam_id <= 2'd0;
                end
                4'b0010: begin
                    pixel_out <= pixel_in_1; // 第 1 号 Bit 为高，导通通道 1
                    cam_id <= 2'd1;
                end
                4'b0100: begin
                    pixel_out <= pixel_in_2; // 第 2 号 Bit 为高，导通通道 2
                    cam_id <= 2'd2;
                end
                4'b1000: begin
                    pixel_out <= pixel_in_3; // 第 3 号 Bit 为高，导通通道 3
                    cam_id <= 2'd3;
                end
                default: pixel_out <= 16'd0;      // 没有任何授权，输出保持干净的 0
            endcase
        end
    end

endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/20 15:31:28
// Design Name: 
// Module Name: Address_Generator
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


module Address_Generator(
    input [1:0]         cam_id,
    input [7:0]         frame_cnt,
    input [9:0]         line_cnt,
    output wire [31:0]  addr
    );
    
    assign addr = 32'h80000000 + 32'h400*(line_cnt) + 32'h100000*(frame_cnt) + 32'h4000000*(cam_id);
endmodule

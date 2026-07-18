`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): the active datapath is entirely in
// the pclk domain, so the old edge-to-system-clock pulse converter is unused.
`ifdef ENABLE_DEPRECATED_CAMERA_FRONTEND
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
    input clk_data, clk, rst,
    output alarm
    );

    localparam MODULE_DEPRECATED = 1'b0;
    
    reg stage_1, stage_2;
    assign alarm = (stage_1 && (!stage_2));
    
    always @(posedge clk or posedge rst)
    begin
        if (rst)
        begin
            stage_1 <= 1'b0;
            stage_2 <= 1'b0;
        end
        else begin
            stage_1 <= clk_data;
            stage_2 <= stage_1;
        end
    end
endmodule
`endif

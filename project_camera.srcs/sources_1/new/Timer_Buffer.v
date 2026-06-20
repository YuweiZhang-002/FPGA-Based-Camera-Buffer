`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/17 17:57:27
// Design Name: 
// Module Name: Timer_Buffer
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


module Timer_Buffer(
    input  [3:0] pins,
    input        clk, rst, valid,
    output reg [15:0] out,
    output reg        confirm
    );
    
    reg [15:0] data;
    reg [1:0]  cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            confirm <= 1'b0;
            cnt     <= 2'd0;
            data    <= 16'd0;
        end else begin
            confirm <= 1'b0;
            if(valid) begin
                data <= {data[11:0], pins};   
                if (cnt == 2'd3) begin
                    out     <= {data[11:0], pins};  
                    confirm <= 1'b1;   
                    cnt     <= 2'd0;
                end else begin
                    cnt     <= cnt + 2'd1;
                end
            end
        end
    end
endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/26 18:01:29
// Design Name: 
// Module Name: Grant_Splitter
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


module Grant_Splitter(
     input  wire [7:0] bus_in,

    output wire out0,
    output wire out1,
    output wire out2,
    output wire out3,
    output wire out4,
    output wire out5,
    output wire out6,
    output wire out7
);

assign out0 = bus_in[0];
assign out1 = bus_in[1];
assign out2 = bus_in[2];
assign out3 = bus_in[3];
assign out4 = bus_in[4];
assign out5 = bus_in[5];
assign out6 = bus_in[6];
assign out7 = bus_in[7];

endmodule

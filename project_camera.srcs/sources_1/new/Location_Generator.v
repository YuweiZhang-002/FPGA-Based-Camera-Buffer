`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/18 14:05:15
// Design Name: 
// Module Name: Location_Generator
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


module Location_Generator(
    input            clk, spi_clk, rst,
    input            data_stream,
    output wire[7:0] loc_data,
    output wire      loc_valid
    );
    
    reg [7:0] temp_data;
    reg [2:0] ptr;
    reg       ready;
    assign loc_data = temp_data;
    assign loc_valid = ready;  
    
    always @(posedge clk or posedge rst) begin
        ready <= 1'b0;
        
        if (spi_clk) begin
            if(ptr == 3'd7) begin
                ready <= 1'b1;
            end
            temp_data <= {temp_data[7:1], data_stream};
            ptr <= ptr + 1;
        end
    end
endmodule

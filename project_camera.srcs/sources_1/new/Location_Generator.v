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
    assign loc_data  = temp_data;
    assign loc_valid = ready;

    // spi_clk is a FOREIGN serial clock, not a data enable. Sample it into the
    // system clk domain and turn each rising edge into a 1-clk strobe, exactly
    // like Pixel_Generator does for cam_clk. This removes the clock-as-data hazard.
    wire spi_pulse;
    Alarmer alarmer_loc (
        .clk_data (spi_clk),
        .clk      (clk),
        .rst      (rst),
        .alarm    (spi_pulse)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            temp_data <= 8'd0;   // reset was in the sensitivity list but never used
            ptr       <= 3'd0;
            ready     <= 1'b0;
        end else begin
            ready <= 1'b0;
            if (spi_pulse) begin
                // BUGFIX: old code {temp_data[7:1], data_stream} only wrote bit0 and
                // never shifted. Proper MSB-first serial shift-in:
                temp_data <= {temp_data[6:0], data_stream};
                if (ptr == 3'd7) ready <= 1'b1; // full byte assembled this strobe
                ptr <= ptr + 1'b1;
            end
        end
    end
endmodule

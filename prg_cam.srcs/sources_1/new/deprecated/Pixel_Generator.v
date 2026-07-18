`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): superseded by Camera_Capture.v,
// which runs directly on pclk and does not create a synthetic clk-domain pulse.
`ifdef ENABLE_DEPRECATED_CAMERA_FRONTEND
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/04 21:39:21
// Design Name: 
// Module Name: pixel_gen
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// - REFRACTORED: Now acts as a clean camera interface.
// - It only processes input `pins` when href is active.
// - It synchronizes camera signals to the main `clk` domain.
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Refactored for clear separation of concerns.
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module pixel_gen(
    input  wire           href,      // Input: Horizontal active signal
    input  wire    [3:0]  pins,      // Input: 4-bit data per cam_clk
    input  wire           cam_clk,   // Input: Acquire clock from camera
    input  wire           clk,       // Input: System clock
    input  wire           rst,       // Input: System reset
    output reg [15:0] out,       // Output: Y8 in out[7:0], out[15:8]=0 for compatibility
    output reg        confirm    // Output: Single-cycle pulse confirming a valid byte
);

    wire valid_cam_clk_edge;

    // Alarmer converts each cam_clk edge into a single pulse in the `clk` domain.
    alarmer alarmer_pixel(
        .clk_data(cam_clk), 
        .clk(clk), 
        .rst(rst),
        .alarm(valid_cam_clk_edge)
    );
    
    // Synchronize href from cam_clk domain to clk domain to be used safely.
    reg href_d1, href_sync;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            href_d1   <= 1'b0;
            href_sync <= 1'b0;
        end else begin
            href_d1   <= href;
            href_sync <= href_d1;
        end
    end

    reg [7:0] data;
    reg       cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            confirm <= 1'b0;
            cnt     <= 1'b0;
            data    <= 8'd0;
            out     <= 16'd0;
        end else begin
            // The confirm pulse must be held low by default.
            confirm <= 1'b0;     
            
            // Only process data if we are in an active line (href_sync is high)
            // and we have a valid clock edge from the camera (valid_cam_clk_edge).
            if (valid_cam_clk_edge && href_sync) begin
                // Y8 capture: two 4-bit nibbles form one byte.
                if (!cnt) begin
                    data[7:4] <= pins;
                    cnt       <= 1'b1;
                end else begin
                    data[3:0] <= pins;
                    out       <= {8'd0, data[7:4], pins};
                    confirm   <= 1'b1;
                    cnt       <= 1'b0;
                end
            // If href goes low, it means the line has ended.
            end else if (!href_sync) begin
                // Reset the counter to discard any partial pixel data.
                cnt <= 1'b0;
            end
        end
    end
endmodule
`endif

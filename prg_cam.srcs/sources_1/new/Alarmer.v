`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Alarmer
//
// MODIFIED (2026-07-17): active lightweight pclk-to-sys_clk edge detector.
// Camera pclk is asynchronous to the 100 MHz FPGA system clock.  The two
// ASYNC_REG stages reduce metastability risk; alarm is one sys_clk-wide pulse
// for each observed pclk rising edge.
//
// IMPORTANT: this pulse-sampling scheme requires sys_clk to be sufficiently
// faster than pclk and camera data to remain stable until the synchronized edge
// is observed.  If that timing contract cannot be met, use a pclk-written
// asynchronous FIFO instead of synchronizing the data strobe.
//////////////////////////////////////////////////////////////////////////////////
module Alarmer(
    input  wire clk_data,
    input  wire clk,
    input  wire rst,
    output wire alarm
);

    (* ASYNC_REG = "TRUE" *) reg clk_meta;
    (* ASYNC_REG = "TRUE" *) reg clk_sync;
    reg clk_sync_d;

    assign alarm = clk_sync && !clk_sync_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_meta   <= 1'b0;
            clk_sync   <= 1'b0;
            clk_sync_d <= 1'b0;
        end else begin
            clk_meta   <= clk_data;
            clk_sync   <= clk_meta;
            clk_sync_d <= clk_sync;
        end
    end

endmodule

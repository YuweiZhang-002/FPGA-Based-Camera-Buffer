`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Arbitration
// Role: Round-robin arbiter for 8 camera channels.
//       Decides which camera's request gets processed, issues a locked one-hot
//       grant, and releases the grant upon receiving the drawback pulse.
//
// Key Updates:
// - Scaled down from 16 channels to 8 channels to align with the 8-camera MUX.
// - Input 'request' narrowed to [7:0] (1 line per camera).
// - Output 'grant_onehot' narrowed to [7:0] (one-hot grant for MUX).
// - Round-robin pointer (rr_ptr) resized to 3-bit width [2:0] to index 8 channels.
// - Watchdog timer and priority encoder updated to perfectly match 8-bit widths.
//////////////////////////////////////////////////////////////////////////////////
module Arbitration (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] request,      // 8 request lines (1 per camera)
    input  wire       released,     // AXI drawback pulse, indicating grant can be released
    output reg  [7:0] grant_onehot, // Latched one-hot grant for the selected camera
    output reg        drawback,     // One-cycle pulse indicating the grant has been released
    output reg        watchdog_en   // Latches high on timeout (See Watchdog Notice)
);

    localparam NUM_CHANNELS        = 8;
    localparam LOCK_TIMEOUT_CYCLES = 24'd400_000;   // ~1ms @ 400MHz / ~4ms @ 100MHz

    reg        locked;       // Flag indicating a grant is currently active
    reg [2:0]  rr_ptr;       // Round-robin pointer (points to the start of the priority list)
    reg [23:0] lock_timer;   // Timer to detect if a grant is held for too long

    // Round-robin priority encoding logic
    wire [15:0] double_req  = {request, request};
    wire [7:0]  shifted_req = double_req >> rr_ptr;

    // Priority encoder to find the index of the first set bit in the shifted request vector
    wire [2:0] grant_idx = shifted_req[0] ? 3'd0 :
                           shifted_req[1] ? 3'd1 :
                           shifted_req[2] ? 3'd2 :
                           shifted_req[3] ? 3'd3 :
                           shifted_req[4] ? 3'd4 :
                           shifted_req[5] ? 3'd5 :
                           shifted_req[6] ? 3'd6 :
                           shifted_req[7] ? 3'd7 : 3'd0;

    wire [2:0] selected_channel = rr_ptr + grant_idx; // The absolute index of the channel to be granted
    wire       any_req          = (request != 8'd0);
    wire       lock_timeout     = (lock_timer >= LOCK_TIMEOUT_CYCLES);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            grant_onehot <= 8'd0;
            drawback     <= 1'b0;
            watchdog_en  <= 1'b0;
            locked       <= 1'b0;
            rr_ptr       <= 3'd0;
            lock_timer   <= 24'd0;
        end else begin
            // Default to de-asserting the single-cycle drawback pulse
            drawback <= 1'b0;

            if (locked) begin
                // If a grant is active, start the watchdog timer
                if (!lock_timeout) begin
                    lock_timer <= lock_timer + 1'b1;
                end

                // Normal completion: the AXI compiler signals 'released'
                if (released) begin
                    grant_onehot <= 8'd0;
                    drawback     <= 1'b1;   // Signal back that the release was seen
                    locked       <= 1'b0;
                    lock_timer   <= 24'd0;
                // Timeout completion: the grant has been held for too long
                end else if (lock_timeout) begin
                    grant_onehot <= 8'd0;
                    watchdog_en  <= 1'b1;   // Assert watchdog signal
                    locked       <= 1'b0;
                    lock_timer   <= 24'd0;
                end
            end else begin
                // If no grant is active, keep timer cleared and look for new requests
                lock_timer <= 24'd0;

                if (any_req) begin
                    // Grant the highest priority request
                    grant_onehot <= (8'h1 << selected_channel);
                    locked       <= 1'b1;
                    // Advance the round-robin pointer for the next cycle
                    rr_ptr       <= selected_channel + 1'b1;
                end
            end
        end
    end
endmodule

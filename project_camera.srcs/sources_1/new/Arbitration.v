`timescale 1ns / 1ps

module Arbitration #(
    parameter CHANNELS = 4
)(
    input            clk,
    input            rst,
    input [7:0]      request,
    input            released,      // AXI drawback pulse, already in clk domain.
    output reg       accept,        // = (grant_onehot != 0); drives AXI permit.
    output reg [7:0] grant_onehot,  // Latched one-hot grant. Drives LG/MUX select + AG.
    output reg       drawback       // One clk pulse: this grant has been released.
);
    // cam_id output removed: the camera index is fully recoverable from the
    // one-hot grant (MUX decodes it for Address_Generator), so exporting a
    // separate cam_id bus was redundant routing.

    localparam LOCK_TIMEOUT_CYCLES = 24'd1_000_000; // ~10ms @ 100MHz

    reg        locked;
    reg [2:0]  rr_ptr;
    reg [23:0] lock_timer;

    wire [7:0] request_masked = (CHANNELS >= 8) ? request :
                                (request & ((8'h01 << CHANNELS) - 8'h01));
    wire [15:0] double_req = {request_masked, request_masked};
    wire [7:0] shifted_req = double_req >> rr_ptr;

    wire [2:0] grant_idx = shifted_req[0] ? 3'd0 :
                           shifted_req[1] ? 3'd1 :
                           shifted_req[2] ? 3'd2 :
                           shifted_req[3] ? 3'd3 :
                           shifted_req[4] ? 3'd4 :
                           shifted_req[5] ? 3'd5 :
                           shifted_req[6] ? 3'd6 :
                           shifted_req[7] ? 3'd7 : 3'd0;

    wire [2:0] selected_cam = rr_ptr + grant_idx;
    wire       any_req = (request_masked != 8'd0);
    wire       lock_timeout = (lock_timer >= LOCK_TIMEOUT_CYCLES);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            accept       <= 1'b0;
            grant_onehot <= 8'd0;
            drawback     <= 1'b0;
            locked       <= 1'b0;
            rr_ptr       <= 3'd0;
            lock_timer   <= 24'd0;
        end else begin
            drawback <= 1'b0;

            if (locked) begin
                if (!lock_timeout) begin
                    lock_timer <= lock_timer + 1'b1;
                end

                // AXI drawback is the only normal completion signal.  Arbitration
                // only converts it into a one-cycle release pulse and drops grant.
                if (released || lock_timeout) begin
                    accept       <= 1'b0;
                    grant_onehot <= 8'd0;
                    drawback     <= 1'b1;
                    locked       <= 1'b0;
                    lock_timer   <= 24'd0;
                end
            end else begin
                lock_timer <= 24'd0;

                if (any_req) begin
                    accept       <= 1'b1;
                    grant_onehot <= (8'h01 << selected_cam);
                    locked       <= 1'b1;
                    rr_ptr       <= selected_cam + 1'b1;
                end
            end
        end
    end
endmodule

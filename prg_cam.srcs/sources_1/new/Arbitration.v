`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Arbitration
//
// MODIFIED (2026-07-17): minimal four-camera packet arbiter.
// - request[i] is a level from Line_Buffer, not a pulse.
// - grant_onehot is the only lock state; a separate locked flag is unnecessary.
// - A grant is held for the complete 128-byte packet.
// - released must be selected_valid && selected_ready && selected_packet_last.
// - Only a two-bit round-robin pointer is retained.  Watchdog, drawback and
//   auxiliary status flags from the older architecture were removed.
//////////////////////////////////////////////////////////////////////////////////
module Arbitration(
    input  wire       sys_clk,
    input  wire       rst,
    input  wire [3:0] request,
    input  wire       released,
    output reg  [3:0] grant_onehot
);

    reg [1:0] rr_ptr;
    reg [3:0] next_grant;

    // Four explicit priority orders are easier to audit than a rotating barrel
    // shifter and synthesize to a small priority network for exactly four cams.
    always @(*) begin
        next_grant = 4'b0000;
        case (rr_ptr)
            2'd0: begin
                if      (request[0]) next_grant = 4'b0001;
                else if (request[1]) next_grant = 4'b0010;
                else if (request[2]) next_grant = 4'b0100;
                else if (request[3]) next_grant = 4'b1000;
            end
            2'd1: begin
                if      (request[1]) next_grant = 4'b0010;
                else if (request[2]) next_grant = 4'b0100;
                else if (request[3]) next_grant = 4'b1000;
                else if (request[0]) next_grant = 4'b0001;
            end
            2'd2: begin
                if      (request[2]) next_grant = 4'b0100;
                else if (request[3]) next_grant = 4'b1000;
                else if (request[0]) next_grant = 4'b0001;
                else if (request[1]) next_grant = 4'b0010;
            end
            default: begin
                if      (request[3]) next_grant = 4'b1000;
                else if (request[0]) next_grant = 4'b0001;
                else if (request[1]) next_grant = 4'b0010;
                else if (request[2]) next_grant = 4'b0100;
            end
        endcase
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            grant_onehot <= 4'b0000;
            rr_ptr       <= 2'd0;
        end else if (grant_onehot == 0) begin
            grant_onehot <= next_grant;
        end else if (released) begin
            case (grant_onehot)
                4'b0001: rr_ptr <= 2'd1;
                4'b0010: rr_ptr <= 2'd2;
                4'b0100: rr_ptr <= 2'd3;
                default: rr_ptr <= 2'd0;
            endcase
            // One idle arbitration cycle cleanly separates packet owners.
            grant_onehot <= 4'b0000;
        end
    end

endmodule

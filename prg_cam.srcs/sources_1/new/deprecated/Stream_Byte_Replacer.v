`timescale 1ns / 1ps
// DEPRECATED (2026-07-17): superseded by Byte_Replacer.v, which patches both
// required header fields and regenerates CRC-16 for fixed 128-byte packets.
`ifdef ENABLE_DEPRECATED_STREAM_BYTE_REPLACER
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Stream_Byte_Replacer
//
// Transparent ready/valid transform for a fixed packet stream. BYTE_OFFSET is
// counted from zero and advances only on a real handshake, so downstream stalls
// cannot move the replacement point. packet_last resets the counter.
//
// Recommended placement: Packet_Formatter -> this module -> Byte_FIFO.
//////////////////////////////////////////////////////////////////////////////////
module Stream_Byte_Replacer #(
    parameter integer ENABLE           = 0,
    parameter integer BYTE_OFFSET      = 0,
    parameter [7:0]   REPLACEMENT_BYTE = 8'hFF
)(
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] in_data,
    input  wire       in_valid,
    output wire       in_ready,
    input  wire       in_packet_last,

    output wire [7:0] out_data,
    output wire       out_valid,
    input  wire       out_ready,
    output wire       out_packet_last
);

    reg [6:0] byte_index;
    wire transfer_fire = in_valid && in_ready;

    assign in_ready        = out_ready;
    assign out_valid       = in_valid;
    assign out_packet_last = in_packet_last;
    assign out_data        = (ENABLE && (byte_index == BYTE_OFFSET))
                             ? REPLACEMENT_BYTE : in_data;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            byte_index <= 7'd0;
        end else if (transfer_fire) begin
            if (in_packet_last)
                byte_index <= 7'd0;
            else
                byte_index <= byte_index + 1'b1;
        end
    end

endmodule
`endif

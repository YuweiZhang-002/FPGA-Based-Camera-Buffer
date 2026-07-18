`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Byte_Replacer
//
// MODIFIED (2026-07-17): replaces Packet_Formatter in the active data path.
// The incoming stream is already one complete fixed 128-byte packet, so this
// module does not construct headers, split payloads or generate row sequences.
// It changes only the fields FPGA owns and recomputes the packet-tail CRC:
//
//   offset 4   cam_id       = {6'd0, in_cam_id}
//   offset 9   row_flags    = original byte OR in_row_flags
//   offset 126 CRC low byte
//   offset 127 CRC high byte and packet_last
//
// CRC covers the MODIFIED bytes at offsets 0..125.  The implementation matches
// the supplied C code: initial 16'hFFFF, polynomial 16'h1021, MSB first, no
// reflection and no final XOR.  Index and CRC advance only on valid/ready
// handshakes, so downstream backpressure cannot move a replacement position.
//////////////////////////////////////////////////////////////////////////////////
module Byte_Replacer #(
    parameter integer PACKET_BYTES     = 128,
    parameter integer CAM_ID_OFFSET    = 4,
    parameter integer ROW_FLAG_OFFSET  = 9,
    parameter integer CRC_LOW_OFFSET   = 126,
    parameter integer CRC_HIGH_OFFSET  = 127
)(
    input  wire       sys_clk,
    input  wire       rst,

    input  wire [7:0] in_data,
    input  wire       in_valid,
    output wire       in_ready,
    input  wire       in_packet_last,
    input  wire [1:0] in_cam_id,
    input  wire [7:0] in_row_flags,

    output wire [7:0] out_data,
    output wire       out_valid,
    input  wire       out_ready,
    output wire       out_packet_last
);

    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0]  data_in;
        integer bit_index;
        reg [15:0] crc_work;
        begin
            crc_work = crc_in ^ {data_in, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (crc_work[15])
                    crc_work = {crc_work[14:0], 1'b0} ^ 16'h1021;
                else
                    crc_work = {crc_work[14:0], 1'b0};
            end
            crc16_byte = crc_work;
        end
    endfunction

    reg [6:0]  byte_index;
    reg [15:0] crc_reg;

    wire [7:0] header_patched_data =
        (byte_index == CAM_ID_OFFSET)   ? {6'd0, in_cam_id} :
        (byte_index == ROW_FLAG_OFFSET) ? (in_data | in_row_flags) :
                                           in_data;

    wire transfer_fire = in_valid && in_ready;

    assign in_ready  = out_ready;
    assign out_valid = in_valid;

    assign out_data = (byte_index == CRC_LOW_OFFSET)  ? crc_reg[7:0]  :
                      (byte_index == CRC_HIGH_OFFSET) ? crc_reg[15:8] :
                                                        header_patched_data;

    // Line_Buffer always emits a fixed-size packet.  Deriving packet_last from
    // the index makes the boundary explicit; in_packet_last is checked below as
    // a defensive resynchronization condition.
    assign out_packet_last = in_valid && (byte_index == PACKET_BYTES - 1);

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            byte_index <= 7'd0;
            crc_reg    <= 16'hFFFF;
        end else if (transfer_fire) begin
            if (byte_index < CRC_LOW_OFFSET)
                crc_reg <= crc16_byte(crc_reg, header_patched_data);

            if (in_packet_last || (byte_index == PACKET_BYTES - 1)) begin
                byte_index <= 7'd0;
                crc_reg    <= 16'hFFFF;
            end else begin
                byte_index <= byte_index + 1'b1;
            end
        end
    end

endmodule

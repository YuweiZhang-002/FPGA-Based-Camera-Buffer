`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Byte_Replacer
//
// Packet-preserving transform in the active camera path:
//   offset 4       FPGA-assigned cam_id
//   offset 9       RP2354 sender flags, byte-exact and never patched here
//   offset 13      FPGA receiver diagnostic status byte
//   offset 126/127 CRC high/low, or explicit FF/FF placeholder
//
// Each bank owns its bytes, cam_id and status until its final output handshake.
// Camera_Capture audits the MCU ingress tail before this module. CRC_ENABLE
// controls the independent FPGA egress CRC: enabled regenerates offsets
// 126/127 after all patches; disabled emits FF/FF.
//////////////////////////////////////////////////////////////////////////////////
module Byte_Replacer #(
    parameter integer PACKET_BYTES       = 128,
    parameter integer CAM_ID_OFFSET      = 4,
    parameter integer FPGA_STATUS_OFFSET = 13,
    parameter integer CRC_HIGH_OFFSET    = 126,
    parameter integer CRC_LOW_OFFSET     = 127,
    parameter         CRC_ENABLE         = 1'b1
)(
    input  wire       sys_clk,
    input  wire       rst,

    input  wire [7:0] in_data,
    input  wire       in_valid,
    output wire       in_ready,
    input  wire       in_packet_last,
    input  wire [1:0] in_cam_id,
    input  wire [7:0] in_fpga_status,

    output wire [7:0] out_data,
    output wire       out_valid,
    input  wire       out_ready,
    output wire       out_packet_last
);

    localparam [7:0] FPGA_STATUS_LENGTH_ERROR = 8'h08;

    localparam [1:0] BUF_FREE    = 2'd0;
    localparam [1:0] BUF_CAPTURE = 2'd1;
    localparam [1:0] BUF_READY   = 2'd2;
    localparam [1:0] BUF_OUTPUT  = 2'd3;

    // Packet storage is deliberately declared before all functions.  The RAM
    // write process has no reset and the output side is read-only.
    reg [7:0] packet0 [0:PACKET_BYTES-1];
    reg [7:0] packet1 [0:PACKET_BYTES-1];

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

    reg [1:0] buffer_state0;
    reg [1:0] buffer_state1;
    reg [1:0] buffer_cam_id0;
    reg [1:0] buffer_cam_id1;
    reg [7:0] buffer_status0;
    reg [7:0] buffer_status1;

    reg       capture_sel;
    reg       capture_active;
    reg [6:0] capture_index;
    reg [1:0] capture_cam_id_latched;
    reg [7:0] capture_status_latched;
    reg       capture_boundary_error;

    reg       next_output_sel;
    reg       output_sel;
    reg       output_active;
    (* MARK_DEBUG = "TRUE" *) reg [6:0] output_index;
    reg [15:0] output_crc;

    wire capture_buffer_free = capture_sel
        ? (buffer_state1 == BUF_FREE)
        : (buffer_state0 == BUF_FREE);
    wire capture_transfer_fire = in_valid && in_ready;
    wire output_transfer_fire = out_valid && out_ready;
    wire [6:0] capture_write_index = capture_active
        ? capture_index : 7'd0;

    // Once a packet starts, its selected Line_Buffer can always finish.  After
    // both banks fill, ready drops before Arbitration can release another owner.
    assign in_ready = capture_active || capture_buffer_free;

    always @(posedge sys_clk) begin
        if (capture_transfer_fire) begin
            if (capture_sel)
                packet1[capture_write_index] <= in_data;
            else
                packet0[capture_write_index] <= in_data;
        end
    end

    wire capture_length_error =
        ((capture_status_latched & FPGA_STATUS_LENGTH_ERROR) != 0) ||
        capture_boundary_error ||
        ((capture_index == PACKET_BYTES - 1) && !in_packet_last);
    wire [7:0] finalized_status =
        capture_status_latched |
        (capture_length_error ? FPGA_STATUS_LENGTH_ERROR : 8'd0);

    wire [7:0] buffered_output_data = output_sel
        ? packet1[output_index] : packet0[output_index];
    wire [1:0] output_cam_id = output_sel
        ? buffer_cam_id1 : buffer_cam_id0;
    wire [7:0] output_status = output_sel
        ? buffer_status1 : buffer_status0;
    wire [7:0] patched_output_data =
        (output_index == CAM_ID_OFFSET) ? {6'd0, output_cam_id} :
        (output_index == FPGA_STATUS_OFFSET) ? output_status :
        buffered_output_data;

    assign out_valid = output_active;
    assign out_packet_last = output_active &&
                             (output_index == PACKET_BYTES - 1);
    assign out_data = !output_active ? 8'd0 :
        (output_index == CRC_HIGH_OFFSET) ?
            ((CRC_ENABLE != 0) ? output_crc[15:8] : 8'hFF) :
        (output_index == CRC_LOW_OFFSET) ?
            ((CRC_ENABLE != 0) ? output_crc[7:0] : 8'hFF) :
        patched_output_data;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            buffer_state0 <= BUF_FREE;
            buffer_state1 <= BUF_FREE;
            buffer_cam_id0 <= 2'd0;
            buffer_cam_id1 <= 2'd0;
            buffer_status0 <= 8'd0;
            buffer_status1 <= 8'd0;

            capture_sel <= 1'b0;
            capture_active <= 1'b0;
            capture_index <= 7'd0;
            capture_cam_id_latched <= 2'd0;
            capture_status_latched <= 8'd0;
            capture_boundary_error <= 1'b0;

            next_output_sel <= 1'b0;
            output_sel <= 1'b0;
            output_active <= 1'b0;
            output_index <= 7'd0;
            output_crc <= 16'hFFFF;
        end else begin
            if (capture_transfer_fire) begin
                if (!capture_active) begin
                    capture_active <= 1'b1;
                    capture_index <= 7'd1;
                    capture_cam_id_latched <= in_cam_id;
                    capture_status_latched <= in_fpga_status;
                    capture_boundary_error <= in_packet_last;
                    if (capture_sel)
                        buffer_state1 <= BUF_CAPTURE;
                    else
                        buffer_state0 <= BUF_CAPTURE;
                end else if (capture_index == PACKET_BYTES - 1) begin
                    if (capture_sel) begin
                        buffer_cam_id1 <= capture_cam_id_latched;
                        buffer_status1 <= finalized_status;
                        buffer_state1 <= BUF_READY;
                    end else begin
                        buffer_cam_id0 <= capture_cam_id_latched;
                        buffer_status0 <= finalized_status;
                        buffer_state0 <= BUF_READY;
                    end
                    capture_sel <= ~capture_sel;
                    capture_active <= 1'b0;
                    capture_index <= 7'd0;
                    capture_boundary_error <= 1'b0;
                end else begin
                    capture_index <= capture_index + 1'b1;
                    if (in_packet_last)
                        capture_boundary_error <= 1'b1;
                end
            end

            if (!output_active) begin
                if (!next_output_sel && (buffer_state0 == BUF_READY)) begin
                    output_sel <= 1'b0;
                    output_active <= 1'b1;
                    output_index <= 7'd0;
                    output_crc <= 16'hFFFF;
                    buffer_state0 <= BUF_OUTPUT;
                end else if (next_output_sel &&
                             (buffer_state1 == BUF_READY)) begin
                    output_sel <= 1'b1;
                    output_active <= 1'b1;
                    output_index <= 7'd0;
                    output_crc <= 16'hFFFF;
                    buffer_state1 <= BUF_OUTPUT;
                end
            end else if (output_transfer_fire) begin
                if (output_index < CRC_HIGH_OFFSET)
                    output_crc <= crc16_byte(output_crc,
                                             patched_output_data);

                if (output_index == PACKET_BYTES - 1) begin
                    if (output_sel)
                        buffer_state1 <= BUF_FREE;
                    else
                        buffer_state0 <= BUF_FREE;
                    next_output_sel <= ~output_sel;
                    output_active <= 1'b0;
                    output_index <= 7'd0;
                    output_crc <= 16'hFFFF;
                end else begin
                    output_index <= output_index + 1'b1;
                end
            end
        end
    end

endmodule

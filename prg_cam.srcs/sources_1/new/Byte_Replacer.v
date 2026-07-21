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
    parameter integer PACKET_BYTES     = 128, // 固定输出包长
    parameter integer CAM_ID_OFFSET    = 4,   // pkt_row_header_t.cam_id
    parameter integer ROW_FLAG_OFFSET  = 9,   // pkt_row_header_t.row_flags
    parameter integer CRC_LOW_OFFSET   = 126, // 小端 CRC 低字节
    parameter integer CRC_HIGH_OFFSET  = 127  // 小端 CRC 高字节/包尾
)(
    input  wire       sys_clk,          // CRC 和位置计数所在时钟域
    input  wire       rst,              // 高有效异步复位

    input  wire [7:0] in_data,          // Line_Buffer 当前 byte
    input  wire       in_valid,         // in_data/metadata 有效
    output wire       in_ready,         // 由下游 ready 直接回传
    input  wire       in_packet_last,   // 上游包边界，用于异常情况下重同步
    input  wire [1:0] in_cam_id,        // 被仲裁通道 ID，写入 offset 4
    input  wire [7:0] in_row_flags,     // FPGA flags，按位 OR 到 offset 9

    output wire [7:0] out_data,         // 替换字段/CRC 后的 byte
    output wire       out_valid,        // 与 in_valid 同步的透明 valid
    input  wire       out_ready,        // Byte_FIFO 是否可写
    output wire       out_packet_last   // offset 127 时置位
);

    // 对单个 byte 执行 8 轮 CRC-16-CCITT 更新。这里使用组合函数，
    // crc_reg 只在真实握手时锁存函数结果，stall 不会重复累计同一 byte。
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

    // ========================================================================
    // SHARED TRANSFORM FLAGS -- 组合替换/输出和时序 CRC/index 块共同使用
    // ========================================================================
    reg [6:0]  byte_index; // 当前呈现在接口上的 byte offset：0..127
    reg [15:0] crc_reg;    // 已接收 offset 0..byte_index-1 的累计 CRC

    // ========================================================================
    // COMBINATIONAL-ONLY WIRES -- 不保存状态，只描述当前 byte 的变换/握手
    // ========================================================================
    // 先形成最终 header byte，再把同一个值同时送往输出和 CRC，确保 CRC
    // 校验的是接收端实际看到的 cam_id/flags，而不是修改前的数据。
    wire [7:0] header_patched_data =
        (byte_index == CAM_ID_OFFSET)   ? {6'd0, in_cam_id} :
        (byte_index == ROW_FLAG_OFFSET) ? (in_data | in_row_flags) :
                                           in_data;

    wire transfer_fire = in_valid && in_ready; // 唯一允许 index/CRC 前进的条件

    // 本模块没有额外输出缓存，是完全组合的 ready/valid 变换级。
    assign in_ready  = out_ready;
    assign out_valid = in_valid;

    // CRC 两个位置不再使用原包尾内容；先低字节再高字节，与 MCU 结构一致。
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
            // 只覆盖 0..125；CRC 字段本身不参与 CRC 计算。
            if (byte_index < CRC_LOW_OFFSET)
                crc_reg <= crc16_byte(crc_reg, header_patched_data);

            // 优先使用任一包尾条件复位，防止异常上游 last 令下一包错位。
            if (in_packet_last || (byte_index == PACKET_BYTES - 1)) begin
                byte_index <= 7'd0;
                crc_reg    <= 16'hFFFF;
            end else begin
                byte_index <= byte_index + 1'b1;
            end
        end
    end

endmodule

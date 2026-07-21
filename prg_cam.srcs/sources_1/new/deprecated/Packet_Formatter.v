`timescale 1ns / 1ps
// DEPRECATED (2026-07-17): the camera now supplies a complete 128-byte packet.
// Byte_Replacer modifies only cam_id/row_flags and regenerates the CRC tail, so
// header construction, payload splitting and zero-padding no longer belong here.
`ifdef ENABLE_DEPRECATED_PACKET_FORMATTER
// 注释导读（历史 112-byte formatter）：
// ST_WAIT 接收一次行描述符；ST_HEADER 组合选择 16-byte header 字段；
// ST_PAYLOAD 发送 96-byte chunk，真实数据不足时补 0。header_pos/payload_pos
// 只在 out_valid&out_ready 时递增。row_seq 是同一行被切成多个 packet 后的
// chunk 编号；FIRST_CHUNK/LAST_CHUNK 与当前协议的 FIRST_ROW/LAST_ROW 不同。
// 注意：该归档版本引用旧接口 desc_frame_id/desc_row_idx/desc_byte_count，端口
// 已在历史重构中移除，因此默认宏关闭，不应直接重新启用综合。
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Packet_Formatter
//
// Converts each completed line descriptor and payload into fixed 112-byte row
// packets: 16-byte pkt_row_header_t followed by 96 payload bytes. The final
// chunk is zero padded, while payload_len records the number of real bytes.
// Multi-byte fields are emitted little-endian to match the packed C structure.
// cam_id occupies reserved[0] (packet byte offset 12).
//////////////////////////////////////////////////////////////////////////////////
module Packet_Formatter #(
    parameter [15:0] SYNC0         = 16'hA55A,
    parameter [15:0] SYNC1         = 16'h5AA5,
    parameter integer PAYLOAD_BYTES = 96
)(
    input  wire        pclk,
    input  wire        rst,

    input  wire        desc_valid,
    output wire        desc_ready,
    input  wire [1:0]  desc_cam_id,
    input  wire [7:0]  desc_flags,

    input  wire [7:0]  line_data,
    input  wire        line_valid,
    output wire        line_ready,
    input  wire        line_last,

    output reg  [7:0]  out_data,
    output reg         out_valid,
    input  wire        out_ready,
    output reg         out_packet_last
);

    // 旧 row_flags bit0/bit1 表示 chunk 边界，并非当前设计的行边界语义。
    localparam [7:0] PKT_ROW_FLAG_FIRST_CHUNK = 8'h01;
    localparam [7:0] PKT_ROW_FLAG_LAST_CHUNK  = 8'h02;

    localparam [1:0] ST_WAIT    = 2'd0;
    localparam [1:0] ST_HEADER  = 2'd1;
    localparam [1:0] ST_PAYLOAD = 2'd2;

    reg [1:0]  state;           // formatter 三态 SM
    reg [4:0]  header_pos;      // header offset 0..15
    reg [6:0]  payload_pos;     // chunk payload offset 0..95
    reg [7:0]  payload_len;     // 当前 chunk 真实有效 byte 数
    reg [15:0] bytes_remaining; // 当前行尚未分包的 byte 数
    reg [15:0] row_seq;         // 当前行 chunk 序号

    reg [7:0]  cam_id_latched;
    reg [15:0] frame_id_latched;
    reg [15:0] row_idx_latched;
    reg [7:0]  flags_latched;

    wire final_chunk = (bytes_remaining <= PAYLOAD_BYTES); // 本 chunk 是否结束整行
    wire [7:0] row_flags = flags_latched |
                           ((row_seq == 0) ? PKT_ROW_FLAG_FIRST_CHUNK : 8'd0) |
                           (final_chunk ? PKT_ROW_FLAG_LAST_CHUNK : 8'd0);
    wire output_fire = out_valid && out_ready; // SM/位置前进的唯一条件

    assign desc_ready = (state == ST_WAIT);
    assign line_ready = (state == ST_PAYLOAD) &&
                        (payload_pos < payload_len) && out_ready;

    always @(*) begin
        // 先给所有组合输出默认值，确保每条 case 路径完整赋值、不推断 latch。
        out_data        = 8'd0;
        out_valid       = 1'b0;
        out_packet_last = 1'b0;

        case (state)
            ST_HEADER: begin
                // 多字节 C 字段按 little-endian 低字节优先发送。
                out_valid = 1'b1;
                case (header_pos)
                    5'd0:  out_data = SYNC0[7:0];
                    5'd1:  out_data = SYNC0[15:8];
                    5'd2:  out_data = SYNC1[7:0];
                    5'd3:  out_data = SYNC1[15:8];
                    5'd4:  out_data = frame_id_latched[7:0];
                    5'd5:  out_data = frame_id_latched[15:8];
                    5'd6:  out_data = row_idx_latched[7:0];
                    5'd7:  out_data = row_idx_latched[15:8];
                    5'd8:  out_data = row_flags;
                    5'd9:  out_data = payload_len;
                    5'd10: out_data = row_seq[7:0];
                    5'd11: out_data = row_seq[15:8];
                    5'd12: out_data = cam_id_latched; // reserved[0]
                    default: out_data = 8'd0;          // reserved[1..3]
                endcase
            end

            ST_PAYLOAD: begin
                // payload_pos>=payload_len 时主动产生 valid 的 0 进行定长填充。
                if (payload_pos < payload_len) begin
                    out_data  = line_data;
                    out_valid = line_valid;
                end else begin
                    out_data  = 8'd0;
                    out_valid = 1'b1;
                end
                out_packet_last = (payload_pos == PAYLOAD_BYTES - 1);
            end

            default: begin
                out_data        = 8'd0;
                out_valid       = 1'b0;
                out_packet_last = 1'b0;
            end
        endcase
    end

    always @(posedge pclk or posedge rst) begin
        if (rst) begin
            state               <= ST_WAIT;
            header_pos          <= 5'd0;
            payload_pos         <= 7'd0;
            payload_len         <= 8'd0;
            bytes_remaining     <= 16'd0;
            row_seq             <= 16'd0;
            cam_id_latched      <= 8'd0;
            frame_id_latched    <= 16'd0;
            row_idx_latched     <= 16'd0;
            flags_latched       <= 8'd0;
        end else begin
            if (desc_valid && desc_ready) begin
                cam_id_latched   <= desc_cam_id;
                frame_id_latched <= desc_frame_id;
                row_idx_latched  <= desc_row_idx;
                flags_latched    <= desc_flags;
                bytes_remaining  <= desc_byte_count;
                row_seq          <= 16'd0;
                header_pos       <= 5'd0;
                payload_pos      <= 7'd0;
                payload_len      <= (desc_byte_count > PAYLOAD_BYTES)
                                    ? PAYLOAD_BYTES : desc_byte_count[7:0];
                state            <= ST_HEADER;
            end else if (output_fire) begin
                case (state)
                    ST_HEADER: begin
                        // 第 16 个 header byte 握手后切换到 payload offset 0。
                        if (header_pos == 5'd15) begin
                            header_pos  <= 5'd0;
                            payload_pos <= 7'd0;
                            state       <= ST_PAYLOAD;
                        end else begin
                            header_pos <= header_pos + 1'b1;
                        end
                    end

                    ST_PAYLOAD: begin
                        // 每完成固定 96 byte，决定结束整行或开始下一个 chunk。
                        if (payload_pos == PAYLOAD_BYTES - 1) begin
                            payload_pos <= 7'd0;

                            if (bytes_remaining <= PAYLOAD_BYTES) begin
                                state <= ST_WAIT;
                            end else begin
                                bytes_remaining <= bytes_remaining - PAYLOAD_BYTES;
                                row_seq         <= row_seq + 1'b1;
                                payload_len     <= ((bytes_remaining - PAYLOAD_BYTES) >
                                                    PAYLOAD_BYTES)
                                                   ? PAYLOAD_BYTES
                                                   : bytes_remaining - PAYLOAD_BYTES;
                                state           <= ST_HEADER;
                            end
                        end else begin
                            payload_pos <= payload_pos + 1'b1;
                        end
                    end

                    default: state <= ST_WAIT;
                endcase
            end
        end
    end

    // line_last is generated and checked at the line-buffer boundary. It is
    // referenced here to keep protocol debug visibility without changing data.
    wire _unused_line_last = line_last;

endmodule
`endif

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Camera_Pipeline
// Active four-camera top level.
//
// MODIFIED (2026-07-17):
//
//   Camera_Capture[0] -> Line_Buffer[0] --\
//   Camera_Capture[1] -> Line_Buffer[1] ---+-> Arbitration / one-hot mux
//   Camera_Capture[2] -> Line_Buffer[2] ---+-> Byte_Replacer -> Byte_FIFO
//   Camera_Capture[3] -> Line_Buffer[3] --/
//
// All Camera_Capture outputs, Line Buffers, Arbitration, CRC and output FIFO run
// in sys_clk domain. Each camera pclk is only an asynchronous input strobe to its
// own Alarmer. This makes the four Line Buffer streams safe to arbitrate without
// an additional CDC after the buffers.
//////////////////////////////////////////////////////////////////////////////////
module Camera_Pipeline #(
    parameter integer LINES_PER_FRAME   = 480, // href 行数达到此值即 frame 回卷
    parameter integer PACKET_FIFO_DEPTH = 512, // 末级 9-bit FIFO 深度
    parameter [1:0] CAM0_ID = 2'd0,
    parameter [1:0] CAM1_ID = 2'd1,
    parameter [1:0] CAM2_ID = 2'd2,
    parameter [1:0] CAM3_ID = 2'd3
)(
    input  wire       sys_clk, // FPGA 原生 100 MHz；全流水线唯一逻辑时钟
    input  wire       rst,     // 高有效复位，广播到所有子模块

    input  wire       cam0_pclk,
    input  wire       cam0_href,
    input  wire [7:0] cam0_data,
    input  wire       cam1_pclk,
    input  wire       cam1_href,
    input  wire [7:0] cam1_data,
    input  wire       cam2_pclk,
    input  wire       cam2_href,
    input  wire [7:0] cam2_data,
    input  wire       cam3_pclk,
    input  wire       cam3_href,
    input  wire [7:0] cam3_data,

    output wire [7:0] packet_data,  // 最终 128-byte 包字节
    output wire       packet_valid, // packet_data/last 有效
    input  wire       packet_ready, // MCU/下游反压输入
    output wire       packet_last,  // 与第 127 offset 同拍的包尾标志

    output wire [3:0]  arb_grant,      // bit[i]：当前完整包由 camera i 独占
    output wire [3:0]  overflow_pulse, // bit[i]：camera i 本拍丢弃了新包
    output wire [31:0] dropped_packet_count_0,
    output wire [31:0] dropped_packet_count_1,
    output wire [31:0] dropped_packet_count_2,
    output wire [31:0] dropped_packet_count_3,
    // 以下两个 12-bit 调试总线每 3 bit 对应一路：{cam3,cam2,cam1,cam0}。
    output wire [11:0] buffer_used_count,
    output wire [11:0] buffer_committed_count,
    output wire [15:0] packet_fifo_level,      // 末级 FIFO 当前总 word 数
    output wire        packet_fifo_almost_full // 剩余容量不足 128 word
);

    // ========================================================================
    // SHARED INTER-MODULE FLAGS -- 跨两个及以上子模块使用，集中置顶
    // ========================================================================
    // Camera_Capture -> Line_Buffer signals。cN_* 的 N 与物理 camera 端口一致；
    // data/valid 是 byte 通道，start/end 是包边界，id/flags 是逐包 metadata。
    wire [7:0] c0_data, c1_data, c2_data, c3_data;
    wire       c0_valid, c1_valid, c2_valid, c3_valid;
    wire       c0_start, c1_start, c2_start, c3_start;
    wire       c0_end, c1_end, c2_end, c3_end;
    wire [1:0] c0_id, c1_id, c2_id, c3_id;
    wire [7:0] c0_flags, c1_flags, c2_flags, c3_flags;

    // Line_Buffer -> one-hot mux signals。request 是四路持续请求；lbN_ready
    // 只有在该路获得 grant 时才可能为 1，因此未授权 LB 永远不会误弹数据。
    wire [3:0] request;
    wire [7:0] lb0_data, lb1_data, lb2_data, lb3_data;
    wire       lb0_valid, lb1_valid, lb2_valid, lb3_valid;
    wire       lb0_ready, lb1_ready, lb2_ready, lb3_ready;
    wire       lb0_last, lb1_last, lb2_last, lb3_last;
    wire [1:0] lb0_id, lb1_id, lb2_id, lb3_id;
    wire [7:0] lb0_flags, lb1_flags, lb2_flags, lb3_flags;
    wire [2:0] used0, used1, used2, used3;
    wire [2:0] committed0, committed1, committed2, committed3;

    wire ovf0, ovf1, ovf2, ovf3;

    Camera_Capture #(.CAM_ID(CAM0_ID), .LINES_PER_FRAME(LINES_PER_FRAME))
    u_capture_0 (
        .pclk(cam0_pclk), .sys_clk(sys_clk), .rst(rst),
        .href(cam0_href), .camera_data(cam0_data),
        .byte_data(c0_data), .byte_valid(c0_valid),
        .line_start(c0_start), .line_end(c0_end),
        .line_cam_id(c0_id), .line_flags(c0_flags),
        .current_row_idx(), .current_byte_count()
    );

    Camera_Capture #(.CAM_ID(CAM1_ID), .LINES_PER_FRAME(LINES_PER_FRAME))
    u_capture_1 (
        .pclk(cam1_pclk), .sys_clk(sys_clk), .rst(rst),
        .href(cam1_href), .camera_data(cam1_data),
        .byte_data(c1_data), .byte_valid(c1_valid),
        .line_start(c1_start), .line_end(c1_end),
        .line_cam_id(c1_id), .line_flags(c1_flags),
        .current_row_idx(), .current_byte_count()
    );

    Camera_Capture #(.CAM_ID(CAM2_ID), .LINES_PER_FRAME(LINES_PER_FRAME))
    u_capture_2 (
        .pclk(cam2_pclk), .sys_clk(sys_clk), .rst(rst),
        .href(cam2_href), .camera_data(cam2_data),
        .byte_data(c2_data), .byte_valid(c2_valid),
        .line_start(c2_start), .line_end(c2_end),
        .line_cam_id(c2_id), .line_flags(c2_flags),
        .current_row_idx(), .current_byte_count()
    );

    Camera_Capture #(.CAM_ID(CAM3_ID), .LINES_PER_FRAME(LINES_PER_FRAME))
    u_capture_3 (
        .pclk(cam3_pclk), .sys_clk(sys_clk), .rst(rst),
        .href(cam3_href), .camera_data(cam3_data),
        .byte_data(c3_data), .byte_valid(c3_valid),
        .line_start(c3_start), .line_end(c3_end),
        .line_cam_id(c3_id), .line_flags(c3_flags),
        .current_row_idx(), .current_byte_count()
    );

    Line_Buffer u_line_buffer_0 (
        .sys_clk(sys_clk), .rst(rst),
        .capture_data(c0_data), .capture_valid(c0_valid),
        .capture_line_start(c0_start), .capture_line_end(c0_end),
        .capture_cam_id(c0_id), .capture_flags(c0_flags),
        .request(request[0]), .grant(arb_grant[0]),
        .tx_data(lb0_data), .tx_valid(lb0_valid), .tx_ready(lb0_ready),
        .tx_packet_last(lb0_last), .tx_cam_id(lb0_id), .tx_flags(lb0_flags),
        .overflow_pulse(ovf0), .dropped_packet_count(dropped_packet_count_0),
        .used_count(used0), .committed_count(committed0)
    );

    Line_Buffer u_line_buffer_1 (
        .sys_clk(sys_clk), .rst(rst),
        .capture_data(c1_data), .capture_valid(c1_valid),
        .capture_line_start(c1_start), .capture_line_end(c1_end),
        .capture_cam_id(c1_id), .capture_flags(c1_flags),
        .request(request[1]), .grant(arb_grant[1]),
        .tx_data(lb1_data), .tx_valid(lb1_valid), .tx_ready(lb1_ready),
        .tx_packet_last(lb1_last), .tx_cam_id(lb1_id), .tx_flags(lb1_flags),
        .overflow_pulse(ovf1), .dropped_packet_count(dropped_packet_count_1),
        .used_count(used1), .committed_count(committed1)
    );

    Line_Buffer u_line_buffer_2 (
        .sys_clk(sys_clk), .rst(rst),
        .capture_data(c2_data), .capture_valid(c2_valid),
        .capture_line_start(c2_start), .capture_line_end(c2_end),
        .capture_cam_id(c2_id), .capture_flags(c2_flags),
        .request(request[2]), .grant(arb_grant[2]),
        .tx_data(lb2_data), .tx_valid(lb2_valid), .tx_ready(lb2_ready),
        .tx_packet_last(lb2_last), .tx_cam_id(lb2_id), .tx_flags(lb2_flags),
        .overflow_pulse(ovf2), .dropped_packet_count(dropped_packet_count_2),
        .used_count(used2), .committed_count(committed2)
    );

    Line_Buffer u_line_buffer_3 (
        .sys_clk(sys_clk), .rst(rst),
        .capture_data(c3_data), .capture_valid(c3_valid),
        .capture_line_start(c3_start), .capture_line_end(c3_end),
        .capture_cam_id(c3_id), .capture_flags(c3_flags),
        .request(request[3]), .grant(arb_grant[3]),
        .tx_data(lb3_data), .tx_valid(lb3_valid), .tx_ready(lb3_ready),
        .tx_packet_last(lb3_last), .tx_cam_id(lb3_id), .tx_flags(lb3_flags),
        .overflow_pulse(ovf3), .dropped_packet_count(dropped_packet_count_3),
        .used_count(used3), .committed_count(committed3)
    );

    // ========================================================================
    // MUX-ONLY FLAGS -- 紧邻组合 MUX，未在 Capture/LB agent 中使用
    // ========================================================================
    // 组合 mux 的五个 selected_* 必须作为一个整体选择。尤其 cam_id/flags
    // 不能单独延迟，否则会写入另一路 packet 的 offset 4/9。
    reg [7:0] selected_data;
    reg       selected_valid;
    reg       selected_last;
    reg [1:0] selected_cam_id;
    reg [7:0] selected_flags;

    wire replacer_in_ready; // Byte_FIFO ready 经 Byte_Replacer 透明回传
    // released 只能由最后一个 byte 的真实握手产生，不能只检测 last 电平。
    wire released = selected_valid && replacer_in_ready && selected_last;

    Arbitration u_arbitration (
        .sys_clk      (sys_clk),
        .rst          (rst),
        .request      (request),
        .released     (released),
        .grant_onehot (arb_grant)
    );

    // MODIFIED: the old MUX_Machine is unnecessary.  One small combinational
    // one-hot mux selects data and its aligned cam_id/flags metadata together.
    always @(*) begin
        selected_data   = 8'd0;
        selected_valid  = 1'b0;
        selected_last   = 1'b0;
        selected_cam_id = 2'd0;
        selected_flags  = 8'd0;
        case (arb_grant)
            4'b0001: begin
                selected_data   = lb0_data;
                selected_valid  = lb0_valid;
                selected_last   = lb0_last;
                selected_cam_id = lb0_id;
                selected_flags  = lb0_flags;
            end
            4'b0010: begin
                selected_data   = lb1_data;
                selected_valid  = lb1_valid;
                selected_last   = lb1_last;
                selected_cam_id = lb1_id;
                selected_flags  = lb1_flags;
            end
            4'b0100: begin
                selected_data   = lb2_data;
                selected_valid  = lb2_valid;
                selected_last   = lb2_last;
                selected_cam_id = lb2_id;
                selected_flags  = lb2_flags;
            end
            4'b1000: begin
                selected_data   = lb3_data;
                selected_valid  = lb3_valid;
                selected_last   = lb3_last;
                selected_cam_id = lb3_id;
                selected_flags  = lb3_flags;
            end
            default: begin
                // Defaults assigned above represent the no-grant interval.
            end
        endcase
    end

    // ready 解复用：只有 one-hot owner 接收到 backpressure 反馈。
    assign lb0_ready = replacer_in_ready && arb_grant[0];
    assign lb1_ready = replacer_in_ready && arb_grant[1];
    assign lb2_ready = replacer_in_ready && arb_grant[2];
    assign lb3_ready = replacer_in_ready && arb_grant[3];

    // ========================================================================
    // REPLACER/FIFO-ONLY WIRES -- 只属于末级格式修改和输出缓冲
    // ========================================================================
    wire [7:0] replaced_data;
    wire       replaced_valid;
    wire       replaced_ready;
    wire       replaced_last;

    Byte_Replacer u_byte_replacer (
        .sys_clk         (sys_clk),
        .rst             (rst),
        .in_data         (selected_data),
        .in_valid        (selected_valid),
        .in_ready        (replacer_in_ready),
        .in_packet_last  (selected_last),
        .in_cam_id       (selected_cam_id),
        .in_row_flags    (selected_flags),
        .out_data        (replaced_data),
        .out_valid       (replaced_valid),
        .out_ready       (replaced_ready),
        .out_packet_last (replaced_last)
    );

    // bit8 随 byte 一起进入 FIFO，保证任意停顿后 packet_last 仍与数据对齐。
    wire [8:0] fifo_out;

    Byte_FIFO #(
        .DEPTH        (PACKET_FIFO_DEPTH),
        .PACKET_BYTES (128)
    ) u_packet_fifo (
        .clk         (sys_clk),
        .rst         (rst),
        .in_data     ({replaced_last, replaced_data}),
        .in_valid    (replaced_valid),
        .in_ready    (replaced_ready),
        .out_data    (fifo_out),
        .out_valid   (packet_valid),
        .out_ready   (packet_ready),
        .level       (packet_fifo_level),
        .almost_full (packet_fifo_almost_full)
    );

    assign packet_data = fifo_out[7:0];
    assign packet_last = fifo_out[8];

    // 调试/状态输出统一按高位 cam3、低位 cam0 打包。
    assign overflow_pulse        = {ovf3, ovf2, ovf1, ovf0};
    assign buffer_used_count      = {used3, used2, used1, used0};
    assign buffer_committed_count = {committed3, committed2,
                                     committed1, committed0};

endmodule

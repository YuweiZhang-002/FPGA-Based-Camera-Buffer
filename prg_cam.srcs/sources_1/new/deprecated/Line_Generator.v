`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): superseded by Line_Buffer.v.
// The active design has no VSYNC input and uses href edges for row/frame state.
`ifdef ENABLE_DEPRECATED_CAMERA_FRONTEND
// 注释导读（历史四行 FIFO 前端）：
// - state 管理一行的接收：IDLE 等首 pixel，GET_LINE 计 num_pixel，
//   WAIT_FINISH 在最后一行后等待 VSYNC；当前设计已经没有 VSYNC。
// - ptr_rx/ptr_tx 是四个独立 FIFO 的写/读槽指针；buf_full[N] 是对应槽的
//   所有权 flag，is_transmitting 是 grant 到 drawback 期间的发送锁。
// - in_overflow 表示行开始时 ptr_rx 指向的槽仍满，本行所有 pixel 被丢弃；
//   overflow_en 是每个被丢 pixel 的脉冲/电平组合，不是当前 sticky frame flag。
// - fifoN_can_read 选择 ptr_tx 槽，transfer_fire=px_valid&px_ready 才读 FIFO。
// 这些大量逐槽 flags 已被当前 Line_Buffer 的双指针、used_count 和
// committed_count 替代。
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/04 21:39:39
// Design Name: 
// Module Name: line_gen
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// - REFRACTORED: Now acts as a clean line buffer.
// - It is completely decoupled from raw camera signals like href and cam_clk.
// - It consumes a simple `data`+`confirm` interface from pixel_gen.
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Refactored to fix CDC bug and simplify logic.
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module line_gen#(
    parameter num_pixel = 640,
    parameter num_lines = 480,
    parameter CAM_ID    = 0
)(
    input  wire [15:0] data,         // Input: Pixel data from pixel_gen
    input  wire        confirm,      // Input: Single-cycle pulse indicating `data` is valid
    input  wire        clk,          // Input: System clock
    input  wire        vsync,        // Input: Vsync to detect start-of-frame
    input  wire        grant,        // Input: AXI grant for this line
    input  wire        px_ready,     // Input: AXI ready to receive a pixel
    input  wire        drawback,     // Input: AXI transfer completion pulse
    input  wire        rst,          // Input: System Reset

    output wire [15:0] pixel_out,
    output wire [9:0]  line_num_ext,
    output wire [3:0]  frame_num_ext,
    output wire        request,
    output wire        px_valid,
    output wire        final_line,
    output wire        overflow_en
);

    // 接收状态编码；2'd3 未使用，case 无 default 是旧实现的局限。
    localparam IDLE = 2'd0, GET_LINE = 2'd1, WAIT_FINISH = 2'd2;

    reg [1:0] state;       // RX 行接收 SM
    reg [9:0] line_num;    // 当前接收行编号
    reg [10:0] pixel_num;  // 当前行 pixel offset
    reg [3:0] frame_num;   // 旧 16-frame 环形编号，自然溢出
    reg is_final_line;     // 当前接收行是否为 frame 最后一行

    // 每个 FIFO slot 对应一份 metadata；数组化前的显式寄存器写法。
    reg [9:0] line_num_buf1, line_num_buf2;
    reg [9:0] line_num_buf3, line_num_buf4;
    reg [3:0] frame_num_buf1, frame_num_buf2;
    reg [3:0] frame_num_buf3, frame_num_buf4;
    reg       final_line_buf1, final_line_buf2;
    reg       final_line_buf3, final_line_buf4;

    reg       is_transmitting; // 已收到 grant、等待 drawback 的旧锁定 flag
    reg       in_overflow;     // 当前行是否因目标 slot 满而丢弃
    reg [3:0] buf_full;        // bit[N]=FIFO N 含有一行尚未释放的数据
    reg [1:0] ptr_rx; // 0..3 write pointer (4-line ring)
    reg [1:0] ptr_tx; // 0..3 read pointer  (4-line ring)

    // A pixel is valid to be written to FIFO if we get a confirm pulse and are in the correct state.
    wire pixel_valid_for_write = confirm && (state == GET_LINE); // FIFO 写入资格
    assign overflow_en = confirm && in_overflow && (state == GET_LINE);

    assign request = |buf_full; // 任一完整槽存在就向旧 Arbitration 请求

    reg vsync_d1, vsync_sync; // 两拍 VSYNC 采样；未标 ASYNC_REG
    wire vsync_falling_edge = vsync_d1 && !vsync_sync;
    

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            line_num    <= 10'd0;
            pixel_num   <= 11'd0;
            frame_num   <= 4'd0;
            in_overflow <= 1'b0;
            ptr_rx      <= 1'b0;
            ptr_tx      <= 1'b0;
            buf_full    <= 4'b0000;
            state       <= IDLE;
            line_num_buf1 <= 10'd0;
            line_num_buf2 <= 10'd0;
            line_num_buf3 <= 10'd0;
            line_num_buf4 <= 10'd0;
            frame_num_buf1 <= 4'd0;
            frame_num_buf2 <= 4'd0;
            frame_num_buf3 <= 4'd0;
            frame_num_buf4 <= 4'd0;
            final_line_buf1 <= 1'b0;
            final_line_buf2 <= 1'b0;
            final_line_buf3 <= 1'b0;
            final_line_buf4 <= 1'b0;
            is_transmitting <= 1'b0;
            is_final_line   <= 1'b0;
            vsync_d1 <= 1'b0;
            vsync_sync <= 1'b0;
        end else begin
            // Sync vsync to the clk domain
            vsync_d1 <= vsync;
            vsync_sync <= vsync_d1;
            
            if (drawback && is_transmitting) begin
                // drawback 表示 AXI 行事务结束，此时释放 ptr_tx 对应 slot。
                is_transmitting <= 1'b0;
                buf_full[ptr_tx] <= 1'b0;
                if (ptr_tx == 2'd3) begin
                    ptr_tx <= 2'd0;
                end else begin
                    ptr_tx <= ptr_tx + 2'd1;
                end
            end else if (vsync_falling_edge) begin
                ptr_tx <= 1'b0;
            end

            if (grant && !is_transmitting) begin
                // grant 被转换成内部 level 锁，避免授权持续时重复启动。
                is_transmitting <= 1'b1;
            end

            case (state)
                IDLE: begin
                    // A confirm pulse indicates the first pixel of a line is arriving.
                    if (!vsync_sync && confirm) begin
                        state <= GET_LINE;
                        pixel_num <= 11'd0; // This is the first pixel.
                        // 只在行首检查一次容量；该结果保持到整行完成。
                                if (buf_full[ptr_rx]) begin
                           in_overflow <= 1'b1;
                        end else begin
                           in_overflow <= 1'b0;
                        end

                        if(line_num == num_lines - 1) begin
                            is_final_line <= 1'b1;
                        end
                    end
                end

                GET_LINE: begin
                    // confirm 是一个完整 16-bit pixel 的单周期有效事件。
                    if (confirm) begin
                        if (pixel_num == num_pixel - 1) begin
                            pixel_num <= 11'd0;

                            if (!in_overflow) begin
                                case (ptr_rx)
                                    2'd0: begin
                                        line_num_buf1   <= line_num;
                                        frame_num_buf1  <= frame_num;
                                        final_line_buf1 <= is_final_line;
                                    end
                                    2'd1: begin
                                        line_num_buf2   <= line_num;
                                        frame_num_buf2  <= frame_num;
                                        final_line_buf2 <= is_final_line;
                                    end
                                    2'd2: begin
                                        line_num_buf3   <= line_num;
                                        frame_num_buf3  <= frame_num;
                                        final_line_buf3 <= is_final_line;
                                    end
                                    default: begin
                                        line_num_buf4   <= line_num;
                                        frame_num_buf4  <= frame_num;
                                        final_line_buf4 <= is_final_line;
                                    end
                                endcase
                                // 写满后原子提交 slot，然后 ptr_rx 环形前进。
                                buf_full[ptr_rx] <= 1'b1;
                                if (ptr_rx == 2'd3) begin
                                    ptr_rx <= 2'd0;
                                end else begin
                                    ptr_rx <= ptr_rx + 2'd1;
                                end
                            end

                            in_overflow <= 1'b0;

                            if (line_num == num_lines - 1) begin
                                line_num  <= 10'd0;
                                frame_num <= frame_num + 4'd1;
                                state     <= WAIT_FINISH;
                            end else begin
                                line_num <= line_num + 1'b1;
                                state    <= IDLE; // Go back to IDLE to wait for next line's first pixel
                            end
                        end else begin
                            pixel_num <= pixel_num + 1'b1;
                        end
                    end
                end

                WAIT_FINISH: begin
                    // 旧协议依赖 VSYNC 重新武装帧；与当前 href-only 要求不兼容。
                    if (vsync_sync) begin // Wait for vsync to go inactive
                        is_final_line <= 1'b0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // metadata mux 与 pixel FIFO mux 共同由 ptr_tx 选择，必须保持对齐。
    assign line_num_ext  = (ptr_tx == 2'd0) ? line_num_buf1 :
                           (ptr_tx == 2'd1) ? line_num_buf2 :
                           (ptr_tx == 2'd2) ? line_num_buf3 : line_num_buf4;
    assign frame_num_ext = (ptr_tx == 2'd0) ? frame_num_buf1 :
                           (ptr_tx == 2'd1) ? frame_num_buf2 :
                           (ptr_tx == 2'd2) ? frame_num_buf3 : frame_num_buf4;
    assign final_line    = (ptr_tx == 2'd0) ? final_line_buf1 :
                           (ptr_tx == 2'd1) ? final_line_buf2 :
                           (ptr_tx == 2'd2) ? final_line_buf3 : final_line_buf4;


    wire [15:0] dout1, dout2, dout3, dout4;
    wire        empty1, empty2, empty3, empty4;
    wire        wr_busy1, wr_busy2, wr_busy3, wr_busy4;
    wire        rd_busy1, rd_busy2, rd_busy3, rd_busy4;
    // FIFO Generator 的 reset-busy flags；任一路忙就阻断全部写入，较保守。
    wire        wr_busy_any = wr_busy1 | wr_busy2 | wr_busy3 | wr_busy4;

    assign pixel_out = (ptr_tx == 2'd0) ? dout1 :
                       (ptr_tx == 2'd1) ? dout2 :
                       (ptr_tx == 2'd2) ? dout3 : dout4;

    wire cam_selected = grant; // 本实例是否拥有旧共享 AXI 数据路径
    wire fifo1_can_read = cam_selected && (ptr_tx == 2'd0) && !empty1 && !rd_busy1;
    wire fifo2_can_read = cam_selected && (ptr_tx == 2'd1) && !empty2 && !rd_busy2;
    wire fifo3_can_read = cam_selected && (ptr_tx == 2'd2) && !empty3 && !rd_busy3;
    wire fifo4_can_read = cam_selected && (ptr_tx == 2'd3) && !empty4 && !rd_busy4;

    assign px_valid = fifo1_can_read || fifo2_can_read || fifo3_can_read || fifo4_can_read;

    wire transfer_fire = px_valid && px_ready; // 只有握手才弹出一个 pixel

    // FIFO write enable is now simply controlled by the `pixel_valid_for_write` signal.
    // 写使能 one-hot 解码；in_overflow 时整行所有 FIFO 均禁止写。
    wire fifo1_wr_en = pixel_valid_for_write && !in_overflow && !wr_busy_any && (ptr_rx == 2'd0);
    wire fifo2_wr_en = pixel_valid_for_write && !in_overflow && !wr_busy_any && (ptr_rx == 2'd1);
    wire fifo3_wr_en = pixel_valid_for_write && !in_overflow && !wr_busy_any && (ptr_rx == 2'd2);
    wire fifo4_wr_en = pixel_valid_for_write && !in_overflow && !wr_busy_any && (ptr_rx == 2'd3);

    fifo_generator_line fifo_1 (
        .rst          (rst),
        .wr_clk       (clk),
        .rd_clk       (clk),
        .din          (data),
        .wr_en        (fifo1_wr_en),
        .rd_en        (transfer_fire && fifo1_can_read),
        .dout         (dout1),
        .empty        (empty1),
        .wr_rst_busy  (wr_busy1),
        .rd_rst_busy  (rd_busy1)
    );

    fifo_generator_line fifo_2 (
        .rst          (rst),
        .wr_clk       (clk),
        .rd_clk       (clk),
        .din          (data),
        .wr_en        (fifo2_wr_en),
        .rd_en        (transfer_fire && fifo2_can_read),
        .dout         (dout2),
        .empty        (empty2),
        .wr_rst_busy  (wr_busy2),
        .rd_rst_busy  (rd_busy2)
    );

    fifo_generator_line fifo_3 (
        .rst          (rst),
        .wr_clk       (clk),
        .rd_clk       (clk),
        .din          (data),
        .wr_en        (fifo3_wr_en),
        .rd_en        (transfer_fire && fifo3_can_read),
        .dout         (dout3),
        .empty        (empty3),
        .wr_rst_busy  (wr_busy3),
        .rd_rst_busy  (rd_busy3)
    );

    fifo_generator_line fifo_4 (
        .rst          (rst),
        .wr_clk       (clk),
        .rd_clk       (clk),
        .din          (data),
        .wr_en        (fifo4_wr_en),
        .rd_en        (transfer_fire && fifo4_can_read),
        .dout         (dout4),
        .empty        (empty4),
        .wr_rst_busy  (wr_busy4),
        .rd_rst_busy  (rd_busy4)
    );

endmodule
`endif

`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): superseded by Line_Buffer.v.
// The active design has no VSYNC input and uses href edges for row/frame state.
`ifdef ENABLE_DEPRECATED_CAMERA_FRONTEND
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

    localparam IDLE = 2'd0, GET_LINE = 2'd1, WAIT_FINISH = 2'd2;

    reg [1:0] state;
    reg [9:0] line_num;
    reg [10:0] pixel_num; // Width must be sufficient for num_pixel, e.g., 11 bits for 800
    reg [3:0] frame_num;
    reg is_final_line;

    reg [9:0] line_num_buf1, line_num_buf2;
    reg [9:0] line_num_buf3, line_num_buf4;
    reg [3:0] frame_num_buf1, frame_num_buf2;
    reg [3:0] frame_num_buf3, frame_num_buf4;
    reg       final_line_buf1, final_line_buf2;
    reg       final_line_buf3, final_line_buf4;

    reg       is_transmitting;
    reg       in_overflow;
    reg [3:0] buf_full;
    reg [1:0] ptr_rx; // 0..3 write pointer (4-line ring)
    reg [1:0] ptr_tx; // 0..3 read pointer  (4-line ring)

    // A pixel is valid to be written to FIFO if we get a confirm pulse and are in the correct state.
    wire pixel_valid_for_write = confirm && (state == GET_LINE);
    assign overflow_en = confirm && in_overflow && (state == GET_LINE);

    assign request = |buf_full;

    reg vsync_d1, vsync_sync;
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
                is_transmitting <= 1'b1;
            end

            case (state)
                IDLE: begin
                    // A confirm pulse indicates the first pixel of a line is arriving.
                    if (!vsync_sync && confirm) begin
                        state <= GET_LINE;
                        pixel_num <= 11'd0; // This is the first pixel.
                        // Check for overflow condition at the very start of the line.
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
                    if (vsync_sync) begin // Wait for vsync to go inactive
                        is_final_line <= 1'b0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

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
    wire        wr_busy_any = wr_busy1 | wr_busy2 | wr_busy3 | wr_busy4;

    assign pixel_out = (ptr_tx == 2'd0) ? dout1 :
                       (ptr_tx == 2'd1) ? dout2 :
                       (ptr_tx == 2'd2) ? dout3 : dout4;

    wire cam_selected = grant;
    wire fifo1_can_read = cam_selected && (ptr_tx == 2'd0) && !empty1 && !rd_busy1;
    wire fifo2_can_read = cam_selected && (ptr_tx == 2'd1) && !empty2 && !rd_busy2;
    wire fifo3_can_read = cam_selected && (ptr_tx == 2'd2) && !empty3 && !rd_busy3;
    wire fifo4_can_read = cam_selected && (ptr_tx == 2'd3) && !empty4 && !rd_busy4;

    assign px_valid = fifo1_can_read || fifo2_can_read || fifo3_can_read || fifo4_can_read;

    wire transfer_fire = px_valid && px_ready;

    // FIFO write enable is now simply controlled by the `pixel_valid_for_write` signal.
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

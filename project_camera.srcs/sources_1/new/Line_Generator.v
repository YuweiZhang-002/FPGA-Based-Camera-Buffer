`timescale 1ns / 1ps

module Line_Generator #(
    parameter num_pixel = 800,
    parameter num_lines = 600
)(
    input  wire [15:0] data,
    input  wire [1:0]  cam_id,
    input  wire [1:0]  cam_arb,
    input  wire        clk,
    input  wire        valid_clk,
    input  wire        href,
    input  wire        vsync,
    input  wire        grant,
    input  wire        px_ready,
    input  wire        drawback,      // AXI completion pulse, synchronized to clk.
    input  wire        req_overflow,
    input  wire        rst,

    output wire [15:0] pixel_out,
    output wire [9:0]  line_num_ext,
    output wire [7:0]  frame_num_ext,
    output wire [7:0]  buf_cnt_ext,
    output wire [1:0]  cam_id_ext,
    output wire        fifo_empty,
    output wire        rd_rst_busy,
    output wire        wr_rst_busy,
    output wire        request,
    output wire        px_valid,
    output wire        overflow_en
);

    localparam IDLE = 2'd0, WAIT_HREF = 2'd1, GET_LINE = 2'd2, WAIT_FINISH = 2'd3;

    reg [1:0] state;
    reg [9:0] line_num;
    reg [9:0] pixel_num;

    // Registers to store the line/frame number for each buffer when it gets filled.
    reg [9:0] line_num_buf1, line_num_buf2;
    reg [7:0] frame_num_buf1, frame_num_buf2;

    // Registers to hold the latched line/frame number for the duration of a transaction.
    reg [9:0] line_num_shipping;
    reg [7:0] frame_num_shipping;
    reg       is_transmitting; // Flag to indicate a transaction is in progress for this LG.

    reg       in_overflow;
    reg       buf1_full;
    reg       buf2_full;
    reg       ptr_rx; // 0: write FIFO1, 1: write FIFO2
    reg       ptr_tx; // 0: read FIFO1,  1: read FIFO2

    assign cam_id_ext = cam_id;
    reg [7:0]  buf_cnt = 8'd0;
    assign buf_cnt_ext = buf_cnt;

    wire normal_pixel_valid = valid_clk && !in_overflow && (state == GET_LINE);
    assign overflow_en = valid_clk && in_overflow && (state == GET_LINE);

    // A request is a held level.  It remains high until AXI drawback releases
    // the buffer that is currently selected by ptr_tx.
    assign request = buf1_full | buf2_full;

    reg vsync_d1;
    wire vsync_falling_edge = vsync_d1 && !vsync;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            line_num    <= 10'd0;
            pixel_num   <= 10'd0;
            in_overflow <= 1'b0;
            ptr_rx      <= 1'b0;
            ptr_tx      <= 1'b0;
            buf1_full   <= 1'b0;
            buf2_full   <= 1'b0;
            state       <= IDLE;
            line_num_buf1 <= 10'd0;
            line_num_buf2 <= 10'd0;
            frame_num_buf1 <= 8'd0;
            frame_num_buf2 <= 8'd0;
            line_num_shipping <= 10'd0;
            frame_num_shipping <= 8'd0;
            is_transmitting <= 1'b0;
        end else begin
            vsync_d1 <= vsync;
            // AXI drawback is the only normal completion event.  The cam check
            // prevents another camera's completion pulse from clearing this LG.
            if (drawback && (cam_id == cam_arb)) begin
                is_transmitting <= 1'b0; // End of transaction
                if (!ptr_tx) begin
                    buf1_full <= 1'b0;
                end else begin
                    buf2_full <= 1'b0;
                end
                ptr_tx <= ~ptr_tx;
            // On the start of a new frame, reset the transmit pointer.
            end else if (vsync_falling_edge) begin
                ptr_tx <= 1'b0;
            end

            // Latch the shipping line and frame number at the start of a new transaction.
            if (grant && (cam_id == cam_arb) && !is_transmitting) begin
                is_transmitting <= 1'b1;
                line_num_shipping <= ptr_tx ? line_num_buf2 : line_num_buf1;
                frame_num_shipping <= ptr_tx ? frame_num_buf2 : frame_num_buf1;
            end

            case (state)
                IDLE: begin
                    if (vsync_falling_edge) begin
                        state     <= WAIT_HREF;
                        line_num  <= 10'd0;
                        ptr_rx    <= 1'b0;
                        buf1_full <= 1'b0;
                        buf2_full <= 1'b0;
                    end
                end

                WAIT_HREF: begin
                    in_overflow <= 1'b0;
                    if (href) begin
                        pixel_num <= 10'd0;

                        // Capacity right: if the target line buffer is still
                        // full, do not overwrite it.  Route the incoming line
                        // to the overflow path instead.
                        if (req_overflow || (!ptr_rx && buf1_full) || (ptr_rx && buf2_full)) begin
                            in_overflow <= 1'b1;
                        end

                        state <= GET_LINE;
                    end
                end

                GET_LINE: begin
                    if (valid_clk) begin
                        if (pixel_num == num_pixel - 1) begin
                            pixel_num <= 10'd0;

                            if (!in_overflow) begin
                                if (!ptr_rx) begin
                                    line_num_buf1 <= line_num;
                                    frame_num_buf1 <= buf_cnt;
                                    buf1_full <= 1'b1;
                                end else begin
                                    line_num_buf2 <= line_num;
                                    frame_num_buf2 <= buf_cnt;
                                    buf2_full <= 1'b1;
                                end
                                ptr_rx <= ~ptr_rx;
                            end

                            in_overflow <= 1'b0;

                            if (line_num == num_lines - 1) begin
                                line_num <= 10'd0;
                                buf_cnt  <= buf_cnt + 8'd1;
                                state    <= WAIT_FINISH;
                            end else begin
                                line_num <= line_num + 1'b1;
                                state    <= WAIT_HREF;
                            end
                        end else begin
                            pixel_num <= pixel_num + 1'b1;
                        end
                    end
                end

                WAIT_FINISH: begin
                    if (vsync) begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    assign line_num_ext = line_num_shipping;
    assign frame_num_ext = frame_num_shipping;

    wire [15:0] dout1, dout2;
    wire        empty1, empty2;
    wire        wr_busy1, wr_busy2, rd_busy1, rd_busy2;

    assign pixel_out  = ptr_tx ? dout2  : dout1;
    assign fifo_empty = ptr_tx ? empty2 : empty1;
    assign wr_rst_busy = wr_busy1 | wr_busy2;
    assign rd_rst_busy = rd_busy1 | rd_busy2;

    wire cam_selected = grant && (cam_id == cam_arb);
    wire fifo1_can_read = cam_selected && !ptr_tx && !empty1 && !rd_busy1;
    wire fifo2_can_read = cam_selected &&  ptr_tx && !empty2 && !rd_busy2;

    // Ready-valid fire is the single point where data is consumed from LG and
    // accepted by the AXI-side FIFO.  If px_ready is low, no byte is popped.
    assign px_valid = fifo1_can_read || fifo2_can_read;

    wire transfer_fire = px_valid && px_ready;

    wire fifo1_wr_en = normal_pixel_valid && !wr_rst_busy && !ptr_rx;
    wire fifo2_wr_en = normal_pixel_valid && !wr_rst_busy &&  ptr_rx;

    fifo_generator_2 fifo_1 (
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

    fifo_generator_2 fifo_2 (
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

endmodule

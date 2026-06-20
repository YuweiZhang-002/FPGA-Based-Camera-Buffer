`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/18 15:48:47
// Design Name: 
// Module Name: Line_Generator
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////



module Line_Generator#(
    parameter num_pixel = 800,
    parameter num_lines = 600
)(
    input [15:0]       data,
    input [1:0]        cam_id, cam_arb,  // 接收定义的时钟编号和仲裁机有效时钟
    input              clk,           // 写入时钟 (VGA/Camera 像素时钟)
    input              valid_clk,     // 数据有效信号 (对应原 href 期间的数据有效)
    input              href, vsync,
    input              grant,         // 仲裁机许可信号 (即 rd_en 触发)
    input              line_complete, // AXI4 发送模块反馈 (一整行发送完毕)
    input              req_overflow,
    input              rst,
    
    output wire [15:0] pixel_out,     // 经过 MUX 吐出的数据
    output wire        fifo_empty,    // 告知后端仲裁机，当前激活的 FIFO 是不是空的
    output wire        rd_rst_busy, wr_rst_busy, 
    output wire        line_finish, frame_done,
    output wire        request,       // 申请仲裁机制
    output wire        overflow_en
);
    
    localparam IDLE = 2'd0, WAIT_HREF = 2'd1, GET_LINE = 2'd2, WAIT_FINISH = 2'd3;
    reg [1:0] state;
    
    reg [9:0]  line_num, pixel_num;
    reg        fifo1_ready, fifo2_ready;
    reg        in_overflow;
    
    // 乒乓指针声明
    reg ptr_rx; // 接收端写指针 (0: 写FIFO1, 1: 写FIFO2)
    reg ptr_tx; // 发送端读指针 (0: 读FIFO1, 1: 读FIFO2)
    
    assign request = fifo1_ready || fifo2_ready;
    assign line_finish = (pixel_num == num_pixel - 1) && valid_clk; 
    assign frame_done  = (line_num == num_lines - 1) && line_finish;
    
    wire normal_pixel_valid = valid_clk && (!in_overflow) && (state == GET_LINE);
    assign overflow_en  = valid_clk && in_overflow && (state == GET_LINE);
    
    // ==========================================
    // 1. 坐标、状态机与 ptr_rx (写指针) 控制
    // ==========================================
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            line_num    <= 10'd0;  
            pixel_num   <= 10'd0; 
            in_overflow <= 1'b0; 
            ptr_rx      <= 1'b0;  // 默认从写 FIFO1 开始
            fifo1_ready <= 1'b0;
            fifo2_ready <= 1'b0;
            state       <= IDLE;
        end else begin
            case(state) 
                IDLE: begin 
                    if(!vsync) begin
                        state    <= WAIT_HREF;
                        line_num <= 10'd0;
                        ptr_rx   <= 1'b0; // 新的一帧，强制同步指针
                    end
                end
                WAIT_HREF: begin
                    in_overflow <= 1'b0;
                    if (href) begin
                        pixel_num <= 10'd0; 
                        if (req_overflow) in_overflow <= 1'b1;
                        state <= GET_LINE;
                    end
                end
                GET_LINE: begin
                    if (valid_clk) begin
                        if (pixel_num == num_pixel - 1) begin
                            pixel_num   <= 10'd0;
                            in_overflow <= 1'b0; 
                            /* 设置fifo就绪标志 */
                            if (!ptr_rx)      fifo1_ready = 1'b1;
                            else              fifo2_ready = 1'b1; 
                            ptr_rx      <= ~ptr_rx;  // 【精髓1】：当前行写满，瞬间翻转写指针！
                            
                            if (line_num == num_lines - 1) begin
                                line_num <= 10'd0;
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
                    if(vsync) begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
    
    // ==========================================
    // 2. ptr_tx (读指针) 翻转控制
    // ==========================================
    // 【精髓2】：读指针绝对不能乱翻。必须等到 AXI 搬运工明确说"我把这一行搬完了 (line_complete)"，才能翻转读指针，去读下一个 FIFO。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ptr_tx <= 1'b0; // 默认读 FIFO1
        end else if (line_complete) begin
            /* 设置fifo就绪标志 */
            if (!ptr_tx)      fifo1_ready = 1'b0;
            else              fifo2_ready = 1'b0; 
            ptr_tx <= ~ptr_tx; 
        end else if (!vsync) begin
            ptr_tx <= 1'b0; // 帧同步信号到来，对齐指针
        end
    end

    // ==========================================
    // 3. FIFO 例化与硬核 MUX 多路复用
    // ==========================================
    // 分离写使能 (严格受 ptr_rx 控制)
    wire fifo1_wr_en = normal_pixel_valid && (!wr_rst_busy) && (!ptr_rx);
    wire fifo2_wr_en = normal_pixel_valid && (!wr_rst_busy) && (ptr_rx);
    
    // 分离读使能 (严格受 ptr_tx 控制)
    wire fifo1_rd_en = grant && (!ptr_tx) && (cam_id == cam_arb);
    wire fifo2_rd_en = grant && (ptr_tx) && (cam_id == cam_arb);
    
    // 独立的物理输出线
    wire [15:0] dout1, dout2;
    wire        empty1, empty2;
    wire        wr_busy1, wr_busy2;
    wire        rd_busy1, rd_busy2;
    
    // MUX 数据选择器：后端的 AXI 状态机看到的永远只有一个干净的输出
    assign pixel_out  = ptr_tx ? dout2  : dout1;
    assign fifo_empty = ptr_tx ? empty2 : empty1;
    
    // 综合 Busy 信号
    assign wr_rst_busy = wr_busy1 | wr_busy2;
    assign rd_rst_busy = rd_busy1 | rd_busy2;

    fifo_generator_2 fifo_1 (
        .rst          (rst),
        .wr_clk       (clk),           // 【修正】：时钟必须是真实的物理时钟 clk
        .rd_clk       (clk),           // 如果后级 AXI 也在同频，这里写 clk，否则写 axi_clk
        .din          (data),
        .wr_en        (fifo1_wr_en),
        .rd_en        (fifo1_rd_en),
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
        .rd_en        (fifo2_rd_en),
        .dout         (dout2),
        .empty        (empty2),
        .wr_rst_busy  (wr_busy2),
        .rd_rst_busy  (rd_busy2)
    );
endmodule

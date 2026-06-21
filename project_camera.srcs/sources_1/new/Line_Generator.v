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
    input [1:0]        cam_id, cam_arb,  // 接收定义的本摄像头编号 和 仲裁机授权的编号
    input              clk,              // 全局/像素时钟
    input              valid_clk,        // 像素有效电平
    input              href, vsync,
    input              grant,            // 仲裁机许可电平 (即 rd_en 触发前提)
    input              line_complete,    // AXI4发送模块反馈的一整行发送完毕脉冲(已同步至clk域)
    input              req_overflow,     // 外部系统级溢出强制指令
    input              rst,
    
    output wire [15:0] pixel_out,        // 经过 MUX 吐出的数据
    output wire        fifo_empty,       // 告知后端当前激活的 FIFO 状态
    output wire        rd_rst_busy, wr_rst_busy, 
    output wire        line_finish, frame_done,
    output wire        request,          // 申请仲裁
    output wire        overflow_en       // 溢出泄洪通道使能
);
    
    // ==========================================
    // 状态机与指针定义
    // ==========================================
    localparam IDLE = 2'd0, WAIT_HREF = 2'd1, GET_LINE = 2'd2, WAIT_FINISH = 2'd3;
    reg [1:0] state;
    reg [9:0] line_num, pixel_num;
    reg       in_overflow;
    
    // 【问题1 & 2 修复】：废除原有的模糊 ready，改用绝对状态锁 buf_full
    reg buf1_full, buf2_full; 
    
    // 乒乓指针声明
    reg ptr_rx; // 接收端写指针 (0: 写FIFO1, 1: 写FIFO2)
    reg ptr_tx; // 发送端读指针 (0: 读FIFO1, 1: 读FIFO2)
    
    // ==========================================
    // 组合逻辑判决 (问题 6: 纯组合逻辑是可行且零延迟的)
    // ==========================================
    assign line_finish = (pixel_num == num_pixel - 1) && valid_clk && (state == GET_LINE); 
    assign frame_done  = (line_num == num_lines - 1) && line_finish;
    
    wire normal_pixel_valid = valid_clk && (!in_overflow) && (state == GET_LINE);
    assign overflow_en      = valid_clk && in_overflow && (state == GET_LINE);
    
    // 【问题5 修复】：request 安全判决。只要任何一个 buffer 满了，就向仲裁机举手。
    // 由于 buf_full 是寄存器输出，绝对稳定，不会受毛刺和多驱动影响。
    assign request = buf1_full | buf2_full;

    // ==========================================
    // 核心逻辑：双口状态与指针调度
    // ==========================================
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            line_num    <= 10'd0;  
            pixel_num   <= 10'd0; 
            in_overflow <= 1'b0; 
            ptr_rx      <= 1'b0;  
            ptr_tx      <= 1'b0;
            buf1_full   <= 1'b0;
            buf2_full   <= 1'b0;
            state       <= IDLE;
        end else begin
            // ----------------------------------------------------
            // 【问题2 修复：同发同送的解耦】
            // 将 AXI 读完成 (line_complete) 的状态清零独立出来，
            // 且必须确保只有当仲裁机服务的是**本摄像头**时才响应！(问题3应用)
            // ----------------------------------------------------
            if (line_complete && (cam_id == cam_arb)) begin
                if (!ptr_tx) buf1_full <= 1'b0; // FIFO1 被读空，解除满状态
                else         buf2_full <= 1'b0; // FIFO2 被读空，解除满状态
                ptr_tx <= ~ptr_tx;              // 读指针翻转，准备下一次出货
            end 
            else if (!vsync) begin
                ptr_tx <= 1'b0; // 帧复位
            end
            
            case(state) 
                IDLE: begin 
                    if(!vsync) begin
                        state     <= WAIT_HREF;
                        line_num  <= 10'd0;
                        ptr_rx    <= 1'b0;
                        buf1_full <= 1'b0; // 新帧强行清空残留状态
                        buf2_full <= 1'b0;
                    end
                end
                
                WAIT_HREF: begin
                    in_overflow <= 1'b0;
                    if (href) begin
                        pixel_num <= 10'd0; 
                        
                        // ----------------------------------------------------
                        // 【问题1 修复：极其严格的 Overflow 保护屏障】
                        // 在决定写这一行之前，先看目标库房满没满！
                        // 如果目标库房是 full 的，说明 ptr_tx 还没来得及把它读走，
                        // 此时强行写入必然导致旧行被覆盖！直接触发溢出旁路机制！
                        // ----------------------------------------------------
                        if (req_overflow || (!ptr_rx && buf1_full) || (ptr_rx && buf2_full)) 
                            in_overflow <= 1'b1; 
                            
                        state <= GET_LINE;
                    end
                end
                
                GET_LINE: begin
                    if (valid_clk) begin
                        if (pixel_num == num_pixel - 1) begin
                            pixel_num   <= 10'd0;
                            
                            // 如果本行没有溢出，说明成功写进去了，上报库房满！
                            if (!in_overflow) begin
                                if (!ptr_rx) buf1_full <= 1'b1;
                                else         buf2_full <= 1'b1;
                                ptr_rx <= ~ptr_rx; // 【写满翻转写指针】
                            end
                            
                            in_overflow <= 1'b0; 
                            
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
                    if(vsync) state <= IDLE;
                end
            endcase
        end
    end
    
    // ==========================================
    // FIFO 实例化与硬核 MUX (无需修改)
    // ==========================================
    
    wire [15:0] dout1, dout2;
    wire        empty1, empty2;
    wire        wr_busy1, wr_busy2, rd_busy1, rd_busy2;
    
    assign pixel_out  = ptr_tx ? dout2  : dout1;
    assign fifo_empty = ptr_tx ? empty2 : empty1; 
    // 【问题4 解答】：fifo_empty 的作用。仲裁机虽然看 line_complete，
    // 但如果 AXI 读取速度过快，FIFO 可能瞬间被吸干。此时空信号可以做"读空断流保护"
    
    assign wr_rst_busy = wr_busy1 | wr_busy2;
    assign rd_rst_busy = rd_busy1 | rd_busy2;
    
    // 【问题3 修复：利用 cam_arb】
    // 只有当仲裁机选中的是本摄像头，且给与 grant 时，才允许读！
    wire fifo1_wr_en = normal_pixel_valid && (!wr_rst_busy) && (!ptr_rx);
    wire fifo2_wr_en = normal_pixel_valid && (!wr_rst_busy) && (ptr_rx);
    
    wire fifo1_rd_en = grant && (!ptr_tx) && (cam_id == cam_arb);
    wire fifo2_rd_en = grant && (ptr_tx)  && (cam_id == cam_arb);

    fifo_generator_2 fifo_1 (
        .rst          (rst),
        .wr_clk       (clk), 
        .rd_clk       (clk), // 根据你要求统一合并为 clk
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

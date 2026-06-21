`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/19 18:55:10
// Design Name: 
// Module Name: AXI4_Compiler
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


module AXI4_Compiler(
    // 数据接收/发送处理模块，
    input [15:0]      pixel,
    input [31:0]      cam_address,
    input             clk, axi_clk,
    input  wire       rst,
    input             permit,
    // 【说明】axi_data 目前未驱动（悬空），保留作后续直连 DDR2 WDATA 之用；
    //         当前真正的写数据通道是下方的 m_axi_wdata（直连 FIFO dout）。属预留端口/TODO。
    output [127:0]    axi_data,
    
    // 特殊模块： 解除仲裁机占用
    output wire       drawback,
    
    // AW 通道数据发送/接收模块
    input                m_axi_awready,
    output reg  [31:0]   m_axi_awaddr,
    output wire [7:0]    m_axi_awlen,
    output reg           m_axi_awvalid,
    output wire [2:0]    m_axi_awsize,   // 必须是 3-bit
    output wire [1:0]    m_axi_awburst,  // 必须是 2-bit

    // W 通道数据发送/接收模块
    input  wire          m_axi_wready,
    output wire [127:0]  m_axi_wdata,
    output reg           m_axi_wvalid,
    output reg           m_axi_wlast,
    // 【修改】128-bit 总线 = 16 字节/拍，WSTRB 应为 16-bit（原 [31:0] 对应的是 256-bit 总线，多了 16 位）
    output wire [15:0]   m_axi_wstrb,    // 16-bit 掩码，对应 128-bit 数据的 16 个字节

    // B 通道发送/接收模块 (写响应)
    input  wire          m_axi_bvalid,
    output reg           m_axi_bready
    );

    // 参数配置
    assign m_axi_awlen   = 8'd99;          // 100 拍突发
    assign m_axi_awsize  = 3'd4;           // 2^4 = 16 Bytes per beat，与 128-bit 数据一致
    assign m_axi_awburst = 2'b01;          // INCR 递增模式
    // 【修改】WSTRB 改为 16-bit 全 1：128-bit/16 字节全部有效（原 32'h0000FFFF 是为 32-bit 端口准备的）
    assign m_axi_wstrb   = 16'hFFFF;       // 16 个字节均有效

    reg [6:0] burst_beat_counter; // 计数器需扩大，因为要数到 100

    localparam IDLE = 2'd0, STATE_AW = 2'd1, STATE_W = 2'd2, STATE_B = 2'd3;
    reg [1:0] state;

    // ==========================================================================
    // 【新增 / CDC①】permit 跨时钟域同步 (clk 像素域 -> axi_clk 域)
    // ------------------------------------------------------------------
    // 原因：permit 由仲裁机在 clk 域产生，却被 axi_clk 域的状态机直接采样，
    //       属于典型单比特跨域，存在亚稳态风险。这里打两拍同步器再使用。
    // ==========================================================================
    reg permit_s1, permit_s2;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) {permit_s2, permit_s1} <= 2'b00;
        else     {permit_s2, permit_s1} <= {permit_s1, permit};
    end
    wire permit_sync = permit_s2;

    // ==========================================================================
    // 【新增】permit 上升沿检测 + armed 锁存（防电平重触发）
    // ------------------------------------------------------------------
    // 原因：permit 是“电平”信号（仲裁机锁定到 released 才撤销），一次授权只应发一行。
    //       若仅用电平判定，突发结束回 IDLE 时 permit 可能仍为高 -> 误触发第二次突发，
    //       且 permit 跨域撤销有延迟。故：检测到 permit 新的上升沿才 armed，
    //       启动时立刻清 armed，保证“一次授权 = 一次突发”。
    // ==========================================================================
    reg permit_sync_d;
    always @(posedge axi_clk or posedge rst) begin
        if (rst) permit_sync_d <= 1'b0;
        else     permit_sync_d <= permit_sync;
    end
    wire permit_rise = permit_sync & ~permit_sync_d;

    reg armed;
    always @(posedge axi_clk or posedge rst) begin
        if (rst)               armed <= 1'b0;
        else if (permit_rise)  armed <= 1'b1;   // 收到新授权，待发
        else if (state == STATE_AW) armed <= 1'b0; // 已进入突发，消费掉授权
    end

    // 定义解除占用
    // ------------------------------------------------------------------
    // 注意【CDC③/跨模块】：drawback 是 axi_clk 域的单拍脉冲，要送往 clk 域的
    // Arbitration.released。单拍脉冲跨域会丢/重采，接收侧（仲裁机）必须用
    // toggle + 两级同步 + 边沿检测还原成 clk 域脉冲，不能直接连线。
    // 此修复跨越两个模块，需在 Arbitration.v 一并处理（本次仅改 AXI 模块，留此说明）。
    assign drawback = (m_axi_bvalid && m_axi_bready);

    always @(posedge axi_clk or posedge rst) begin
        if(rst) begin
            state              <= IDLE;
            m_axi_awvalid      <= 1'b0;
            m_axi_wvalid       <= 1'b0;
            m_axi_wlast        <= 1'b0;
            m_axi_bready       <= 1'b0;
            burst_beat_counter <= 7'd0;
            m_axi_awaddr       <= cam_address; // 复位缺省基地址（真正取值在启动那拍闩锁）
        end else begin
            case(state)
                IDLE: begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    burst_beat_counter <= 7'd0;

                    // ==========================================================
                    // 【修改 / 读空保护 + CDC】启动条件三重把关：
                    //   armed            : 收到一次新的授权（防电平重触发）
                    //   !fifo_prog_empty : FIFO 已攒够一整行(阈值≥100)，整行预缓存后再发，
                    //                      100 次 pop 绝不下溢（读空保护核心）
                    //   !fifo_rd_rst_busy: 复位忙期间不启动
                    // 同时在“接受授权进入 AW 这一拍”把 cam_address 闩进 awaddr：
                    //   - 解决多比特总线跨域（permit 高电平期间 cam_address 稳定，可安全采样）
                    //   - cam_address 已含 line_cnt，无需再自增（见 STATE_B 注释）
                    // ==========================================================
                    if (armed && !fifo_prog_empty && !fifo_rd_rst_busy) begin
                        state         <= STATE_AW;
                        m_axi_awvalid <= 1'b1;
                        m_axi_awaddr  <= cam_address; // 【修改】每次突发闩锁外部地址
                    end
                end

                STATE_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0; 
                        m_axi_wvalid  <= 1'b1; 
                        state         <= STATE_W;
                    end
                end
                
                STATE_W: begin
                     if (m_axi_wvalid && m_axi_wready) begin
                         if (burst_beat_counter == m_axi_awlen - 1) begin
                             // 倒数第二拍，拉高 WLAST
                             m_axi_wlast <= 1'b1;
                             burst_beat_counter <= burst_beat_counter + 1;
                         end else if (burst_beat_counter == m_axi_awlen) begin
                             // 最后一拍发送完毕
                             m_axi_wvalid <= 1'b0;
                             m_axi_wlast  <= 1'b0;
                             m_axi_bready <= 1'b1; // 【修正】主机拉高 BREADY 等待响应
                             state        <= STATE_B;
                         end else begin
                             burst_beat_counter <= burst_beat_counter + 1;
                         end
                     end
                end
                
                STATE_B: begin
                    // 【修正】等待从机发来 BVALID
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        // 【修改】删除原 m_axi_awaddr += 1600 自增：
                        //   外部 Address_Generator 计算的 cam_address 已包含 line_cnt 偏移，
                        //   内部再自增会与之重复，且多摄像头仲裁时会错误跨到别的相机区域。
                        //   现改为下一次突发启动时直接闩锁 cam_address（见 IDLE 分支）。
                        state        <= IDLE;
                    end
                end
            endcase
        end
    end
    
    // ==========================================
    // 例化异步 FIFO (16-in / 128-out, FWFT 模式)   【修改】原注释 32-in/256-out 已过时
    // ==========================================
    // 只有在发送 W 数据且握手成功时，才从 FIFO 弹出一个 128-bit 数据
    wire   fifo_rd_en;
    assign fifo_rd_en = (state == STATE_W) && m_axi_wvalid && m_axi_wready;

    // 【新增】引出 FIFO 状态：prog_empty 做整行预缓存判据(读空保护)，busy 做复位防护
    wire   fifo_prog_empty;
    wire   fifo_wr_rst_busy;
    wire   fifo_rd_rst_busy;

    fifo_generator_1 u_fifo (
        .wr_clk      (clk),                              // VGA / 像素写时钟
        .rd_clk      (axi_clk),                          // AXI 读时钟
        .din         (pixel),                            // 16-bit 输入
        // 【修改】写使能加 !wr_rst_busy 防护，复位忙期间不写入
        // 注意：wr_en 仍用 permit 作电平使能；若像素侧另有 data-valid 信号，
        //       更严谨应改用该 valid，避免 permit 高电平期间重复写入旧 pixel(待定)。
        .wr_en       (permit && !fifo_wr_rst_busy),
        .rd_en       (fifo_rd_en),                       // AXI 状态机控制读
        .dout        (m_axi_wdata),                      // 128-bit 输出直连 AXI WDATA
        .wr_rst_busy (fifo_wr_rst_busy),                 // 【新增】接出
        .rd_rst_busy (fifo_rd_rst_busy),                 // 【新增】接出，参与启动把关
        // 【新增】prog_empty：FIFO 内字数 < 阈值时为高。阈值需在 IP 中设为 >=100，
        //         即攒够一整行(100×128bit)后才拉低，状态机据此启动突发，保证不读空。
        .prog_empty  (fifo_prog_empty)
    );


endmodule

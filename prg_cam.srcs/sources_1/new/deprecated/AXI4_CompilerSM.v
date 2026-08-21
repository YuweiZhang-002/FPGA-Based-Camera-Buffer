`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): legacy AXI burst state machine.
// It is intentionally compiled out with the rest of the DDR2 data path.
`ifdef ENABLE_DEPRECATED_AXI_DDR2
// 注释导读（历史 AXI4-Full 写 SM）：
// IDLE 等待 can_start_burst；STATE_AW 完成地址握手；STATE_W 发送 256 beat；
// STATE_B 等待写响应。AWVALID/WVALID/BREADY 分别对应 AXI AW/W/B 通道。
// fifo_rd_en 只在 WVALID&WREADY 时置位，确保 FIFO 与 AXI beat 一一对应。
// burst_beat_counter=254 时预告下一/末 beat 的 WLAST，=255 握手后进入 B。
//////////////////////////////////////////////////////////////////////////////////
// Module Name: AXI4_CompilerSM
// Role: Control-plane FSM for AXI4_Compiler.
//       Sequences the AXI write burst handshake, generates FIFO read enables,
//       and records frame-completion metadata in the axi_clk domain.
//
// Notes:
// - The outer AXI4_Compiler keeps the datapath, CDC capture, and address math.
// - This module only owns the AW/W/B state machine and related bookkeeping.
//////////////////////////////////////////////////////////////////////////////////

module AXI4_CompilerSM(
    input  wire        axi_clk,
    input  wire        rst_axi,

    // ---- Burst Launch Inputs ----
    input  wire        can_start_burst,
    input  wire [31:0] target_awaddr,
    input  wire        final_line_axi,
    input  wire [2:0]  cam_id_axi,
    input  wire [3:0]  frame_num_axi,

    // ---- AXI Write Channel Inputs ----
    input  wire        m_axi_awready,
    input  wire        m_axi_wready,
    input  wire        m_axi_bvalid,

    // ---- Control Outputs ----
    output wire        fifo_rd_en,
    output wire        state_is_aw,
    output reg         frame_done_pulse,
    output reg  [2:0]  done_cam_id,
    output reg  [3:0]  done_frame_ptr,

    // ---- AXI Write Channel Outputs ----
    output reg  [31:0] m_axi_awaddr,
    output reg         m_axi_awvalid,
    output reg         m_axi_wvalid,
    output reg         m_axi_wlast,
    output reg         m_axi_bready
);

    localparam MODULE_DEPRECATED = 1'b1;

    // AXI AWLEN 编码为 beats-1，因此 255 表示 256 个 64-bit beat=2048 byte。
    localparam [7:0] BURST_LEN_2048B = 8'd255;

    localparam IDLE     = 2'd0;
    localparam STATE_AW = 2'd1;
    localparam STATE_W  = 2'd2;
    localparam STATE_B  = 2'd3;

    reg [1:0] state;              // 当前 AXI 写事务阶段
    reg [7:0] burst_beat_counter; // 已进行的 W 通道 beat 索引

    assign state_is_aw = (state == STATE_AW); // 外部调试/启动互锁标志
    assign fifo_rd_en   = (state == STATE_W) && m_axi_wvalid && m_axi_wready;

    always @(posedge axi_clk or posedge rst_axi) begin
        if (rst_axi) begin
            state              <= IDLE;
            m_axi_awaddr       <= 32'd0;
            m_axi_awvalid      <= 1'b0;
            m_axi_wvalid       <= 1'b0;
            m_axi_wlast        <= 1'b0;
            m_axi_bready       <= 1'b0;
            burst_beat_counter <= 8'd0;
            frame_done_pulse   <= 1'b0;
            done_cam_id        <= 3'd0;
            done_frame_ptr     <= 4'd0;
        end else begin
            frame_done_pulse <= 1'b0;

            case (state)
                IDLE: begin
                    m_axi_awvalid      <= 1'b0;
                    m_axi_wvalid       <= 1'b0;
                    m_axi_wlast        <= 1'b0;
                    m_axi_bready       <= 1'b0;
                    burst_beat_counter <= 8'd0;

                    if (can_start_burst) begin
                        m_axi_awaddr  <= target_awaddr;
                        m_axi_awvalid <= 1'b1;
                        state         <= STATE_AW;
                    end
                end

                STATE_AW: begin
                    // VALID 必须保持到 READY；只有真实 AW 握手后才进入数据通道。
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b1;
                        state         <= STATE_W;
                    end
                end

                STATE_W: begin
                    // counter 仅在 W 握手前进，下游停顿不会丢 beat。
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (burst_beat_counter == (BURST_LEN_2048B - 1'b1)) begin
                            m_axi_wlast        <= 1'b1;
                            burst_beat_counter <= burst_beat_counter + 1'b1;
                        end else if (burst_beat_counter == BURST_LEN_2048B) begin
                            m_axi_wvalid       <= 1'b0;
                            m_axi_wlast        <= 1'b0;
                            m_axi_bready       <= 1'b1;
                            burst_beat_counter <= 8'd0;
                            state              <= STATE_B;
                        end else begin
                            burst_beat_counter <= burst_beat_counter + 1'b1;
                        end
                    end
                end

                STATE_B: begin
                    // B 通道确认整个 burst 完成；仅 final line 生成帧完成 metadata。
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;

                        if (final_line_axi) begin
                            frame_done_pulse <= 1'b1;
                            done_cam_id      <= cam_id_axi;
                            done_frame_ptr   <= frame_num_axi;
                        end

                        state <= IDLE;
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
`endif

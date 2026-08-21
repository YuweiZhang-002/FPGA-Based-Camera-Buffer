`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Byte_FIFO
// Synchronous BRAM FIFO used as the second buffering level after the four-line
// ring. The ninth stored bit carries the fixed-packet boundary marker.
//
// MODIFIED (2026-07-20): control is explicitly divided into three posedge agents:
//   RX  owns mem write port and wr_ptr.
//   TX  owns mem read port, rd_ptr, out_data_r and out_valid_r.
//   CNT owns mem_count only.
// Shared handshake events are declared once above the agents. No register has
// more than one procedural driver, which makes waveform ownership unambiguous.
//////////////////////////////////////////////////////////////////////////////////
module Byte_FIFO #(
    parameter integer DEPTH        = 512, // FIFO 总 word 数；每个 word 为 9 bit
    parameter integer PACKET_BYTES = 128  // 仅用于 almost_full 的整包余量阈值
)(
    input  wire        clk,       // 所有读写均位于 sys_clk 域
    input  wire        rst,       // 高有效同步复位控制寄存器，不清空 BRAM 内容

    input  wire [8:0]  in_data,   // {packet_last, packet_byte[7:0]}
    input  wire        in_valid,  // 上游声明 in_data 当前有效
    output wire        in_ready,  // FIFO 仍可接收一个 word

    output wire [8:0]  out_data,  // 输出寄存器中的稳定 word
    output wire        out_valid, // 输出寄存器含有可消费 word
    input  wire        out_ready, // 下游愿意在本拍消费 out_data

    output wire [15:0] level,       // RAM 等待项 + 输出寄存器项的总占用
    output wire        almost_full  // RAM 剩余空间不足一个完整 packet
);

    // Verilog-2001 兼容的 ceil(log2(value))，用于生成指针位宽。
    function integer clog2;
        input integer value;
        integer i;
        begin
            value = value - 1;
            for (i = 0; value > 0; i = i + 1)
                value = value >> 1;
            clog2 = (i == 0) ? 1 : i;
        end
    endfunction

    localparam integer ADDR_W = clog2(DEPTH);

    // ========================================================================
    // SHARED FLAGS / STORAGE
    // 跨 RX、TX、CNT 使用的对象集中在此处。mem 由 RX 写口和 TX 读口共享；
    // push/fetch 同时决定 CNT 加减，因此也属于共享事件。
    // ========================================================================
    (* ram_style = "block" *) reg [8:0] mem [0:DEPTH-1];
    // mem_count 由 CNT 独占写入，但 RX 的 in_ready 和 TX 的 fetch 都读取它；
    // out_valid_r 由 TX 独占写入，但 fetch/level 也读取它，故二者归共享区。
    reg [ADDR_W:0] mem_count;
    reg              out_valid_r;

    wire push;  // RX+CNT：上游 word 被接受，写 RAM 且 mem_count 候选 +1
    wire fetch; // TX+CNT：RAM word 被预取，读 RAM 且 mem_count 候选 -1

    assign in_ready    = (mem_count < DEPTH);
    assign out_valid   = out_valid_r;
    assign level       = mem_count + out_valid_r;
    // level 加上 out_valid_r，避免调试口少报预取寄存器中的一个 word。
    // almost_full 保守地只看 RAM：置位后仍不阻断当前 word，真正流控由 in_ready。
    assign almost_full = (mem_count >= DEPTH - PACKET_BYTES);

    assign push  = in_valid && in_ready;
    assign fetch = (mem_count != 0) && (!out_valid_r || out_ready);

    // ========================================================================
    // RX AGENT -- only mem write port and wr_ptr
    // ========================================================================
    reg [ADDR_W-1:0] wr_ptr; // 下一次 push 写入地址，仅 RX always 驱动

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= {ADDR_W{1'b0}};
        end else if (push) begin
            // RAM 内容本身不复位；真实 push 才写一个 9-bit {last,data} word。
            mem[wr_ptr] <= in_data;
            if (wr_ptr == DEPTH - 1)
                wr_ptr <= {ADDR_W{1'b0}};
            else
                wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // ========================================================================
    // TX AGENT -- only mem read port, rd_ptr and output holding register
    // out_valid_r 是隐藏式 TX SM：0=输出级空，1=持有稳定 word 等待 ready。
    // ========================================================================
    reg [ADDR_W-1:0] rd_ptr;       // 下一次 fetch 读取地址，仅 TX always 驱动
    reg [8:0]        out_data_r;   // RAM 外一级预取/保持寄存器
    wire             pop = out_valid_r && out_ready; // 仅 TX 使用的消费事件

    assign out_data = out_data_r;

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr      <= {ADDR_W{1'b0}};
            out_valid_r <= 1'b0;
        end else begin
            if (fetch) begin
                // fetch=1 时同步读 RAM，并在本沿把输出级标记为有效。
                // fetch 与 pop 同拍代表无气泡替换旧输出 word，valid 保持 1。
                out_data_r  <= mem[rd_ptr];
                out_valid_r <= 1'b1;
                if (rd_ptr == DEPTH - 1)
                    rd_ptr <= {ADDR_W{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end else if (pop) begin
                // 只有消费且没有新预取补位时，输出级才变为空。
                out_valid_r <= 1'b0;
            end
        end
    end

    // ========================================================================
    // CNT AGENT -- only mem_count
    // mem_count 只统计仍在 RAM 的 word，不包含 out_data_r。push/fetch 同拍时
    // RAM 占用不变；pop 不直接修改它，因为 pop 消费的是 RAM 外输出寄存器。
    // ========================================================================
    always @(posedge clk) begin
        if (rst) begin
            mem_count <= {(ADDR_W+1){1'b0}};
        end else begin
            case ({push, fetch})
                // 同拍 push+fetch 时 RAM 内总数不变；输入和输出可流水并行。
                2'b10: mem_count <= mem_count + 1'b1;
                2'b01: mem_count <= mem_count - 1'b1;
                default: mem_count <= mem_count;
            endcase
        end
    end

endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Line_Buffer
//
// MODIFIED (2026-07-20): lightweight four-packet ring buffer using implicit SMs.
//
// The former slot_busy[], slot_ready[], capture_active and capture_drop arrays
// were removed. FIFO order makes per-slot flags unnecessary. As in Byte_FIFO,
// control state is encoded by datapath-valid/counter conditions rather than by
// separate WR_*/RD_* enum registers:
//   rx_reserved        used_count > committed_count; one RX slot is in flight
//   tx_valid           0=TX idle, 1=TX owns a stable output byte
//   wr_ptr             next packet slot reserved/committed by the RX agent
//   rd_ptr             next committed slot streamed by the TX agent
//   used_count         reserved + committed + currently transmitted slots
//   committed_count    complete packets available to Arbitration
//
// This implicit RX encoding relies on the Camera_Capture protocol: line_start
// and line_end are ordered, non-overlapping href edge pulses, with at most one
// packet being captured per Line_Buffer. Under that contract a dropped packet
// needs no WR_DROP flag: no slot is reserved, so all intervening valid bytes and
// the matching line_end naturally have no write/commit qualification.
//
// RX, TX and occupancy accounting remain separate always blocks. RX owns wr_ptr
// and metadata writes; TX owns rd_ptr and ready/valid output registers; the count
// block alone owns used_count/committed_count. This separation keeps the logic
// readable and preserves the simple-dual-port BRAM inference template.
//////////////////////////////////////////////////////////////////////////////////
module Line_Buffer #(
    parameter integer PACKET_BYTES = 128, // 每个 slot 对外固定发送的 byte 数
    parameter integer LINE_SLOTS   = 4    // 每路 Camera 可同时占用的包槽数量
)(
    input  wire       sys_clk, // RX、TX、计数和 BRAM 均在同一 sys_clk 域
    input  wire       rst,     // 控制寄存器复位；packet_mem 内容不需要清零

    input  wire [7:0] capture_data,       // Camera_Capture 输出 byte
    input  wire       capture_valid,      // 本拍 capture_data 可写
    input  wire       capture_line_start, // href 上升事件：尝试预留一个 slot
    input  wire       capture_line_end,   // href 下降事件：提交或结束丢弃
    input  wire [1:0] capture_cam_id,     // 行包所属相机 ID
    input  wire [7:0] capture_flags,      // FIRST/LAST/LENGTH_ERROR 等行属性

    // Arbitration interface. request is a level, not a one-cycle pulse, and
    // remains asserted while at least one committed packet is owned by this LB.
    output wire       request, // committed_count!=0 时持续有效
    input  wire       grant,   // Arbiter 给本 LB 的包级所有权

    // Selected packet stream to Byte_Replacer.
    output wire [7:0] tx_data,        // 当前输出 byte；短包缺失区自动补 0
    output reg        tx_valid,       // tx_data/metadata/last 当前有效
    input  wire       tx_ready,       // 被选中且 Byte_Replacer 可接收
    output reg        tx_packet_last, // 固定 offset PACKET_BYTES-1 时置位
    output reg  [1:0] tx_cam_id,      // rd_ptr slot 锁存的相机 ID
    output reg  [7:0] tx_flags,       // rd_ptr slot 锁存的 flags

    output reg        overflow_pulse,       // 每丢弃一个新包拉高一拍
    output reg [31:0] dropped_packet_count, // 累计整包丢弃数，复位清零
    output reg  [2:0] used_count,           // 已预留+已提交+正在发送 slot 数
    output reg  [2:0] committed_count       // 已完整接收且尚未释放 slot 数
);

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

    localparam integer SLOT_W = clog2(LINE_SLOTS);
    localparam integer ADDR_W = clog2(PACKET_BYTES * LINE_SLOTS);

    // ========================================================================
    // SHARED STORAGE -- RX 写、TX 读，不能归入单一 agent
    // ========================================================================
    // packet_mem 线性地址布局为 {slot, byte_offset}，默认 4*128=512 byte。
    // cam_id/flags/length 是每 slot 一份的小型 metadata，综合为寄存器/LUTRAM。
    (* ram_style = "block" *) reg [7:0] packet_mem
        [0:PACKET_BYTES*LINE_SLOTS-1];

    reg [1:0] cam_id_mem [0:LINE_SLOTS-1];
    reg [7:0] flags_mem  [0:LINE_SLOTS-1];
    reg [8:0] length_mem [0:LINE_SLOTS-1];

    // ========================================================================
    // RX-ONLY FLAGS / REGISTERS -- 仅 RX agent 写入或判断
    // ========================================================================
    localparam [7:0] PKT_ROW_FLAG_LAST_ROW     = 8'h02;
    localparam [7:0] PKT_ROW_FLAG_FRAME_OVFLOW = 8'h04;

    reg [SLOT_W-1:0] wr_ptr;           // 下一个将预留/提交的 slot
    reg [8:0] wr_count;                // 当前 href 已保存的真实 byte 数

    // Set after a packet is dropped because all slots are occupied.  The bit is
    // merged into the first later packet that can be transmitted and remains set
    // until a committed LAST_ROW packet reports it.  A dropped last-row packet
    // cannot carry metadata itself, so retaining the bit prevents silent loss.
    reg frame_overflow_pending;

    // 隐式 RX 状态：正常不变量 committed_count<=used_count 下，二者之差
    // 只能是 0 或 1。1 表示 line_start 已 reserve，但 line_end 尚未 commit。
    // 发送中的 packet 同时计入 used/committed，因此不会影响这个差值。
    wire rx_reserved = (used_count > committed_count);

    // ========================================================================
    // TX-ONLY FLAGS / REGISTERS -- 仅 TX agent 写入或判断
    // ========================================================================
    reg [SLOT_W-1:0] rd_ptr;           // 下一个将发送/释放的 slot
    reg [7:0] tx_output_index;         // 当前输出 offset，0..PACKET_BYTES-1
    reg [8:0] tx_length;               // 本 slot 实际捕获长度，用于补零判断
    reg [7:0] mem_read_data;           // 同步 BRAM 读出的一级输出寄存器

    // ========================================================================
    // SHARED EVENT FLAGS -- 由一个 agent 产生，同时被 CNT/其他 agent 使用
    // ========================================================================
    // 四个 event 是跨 agent 共享计数器的唯一更新来源：
    // reserve: 新包成功占用 slot，used +1。
    // drop   : 新包未占用 slot，仅更新错误统计和 sticky overflow。
    // commit : 当前 reserved 包结束，committed +1。
    // release: 最后一 byte 被下游真正接收，used/committed 各 -1。
    // !rx_reserved 等价于原 WR_IDLE。若容量满则产生 drop_event，但不建立
    // 任何 drop 状态；合法 href 在下一次 line_start 前必先给出 line_end。
    wire reserve_event = capture_line_start && !rx_reserved &&
                         (used_count < LINE_SLOTS);
    wire drop_event    = capture_line_start && !rx_reserved &&
                         (used_count >= LINE_SLOTS);
    wire commit_event  = capture_line_end && rx_reserved;
    wire release_event = tx_valid && tx_ready && tx_packet_last;

    // ========================================================================
    // RX COMBINATIONAL ADDRESS / WRITE QUALIFICATION
    // ========================================================================
    wire [ADDR_W-1:0] wr_base = wr_ptr * PACKET_BYTES; // 写 slot 首地址

    // MODIFIED: exactly one write address and one read address feed a standalone
    // simple-dual-port RAM template. Keeping packet_mem out of the resettable RX
    // and TX agents is what permits a RAMB18 inference for each 512x8 buffer.
    // line_start 与首 byte 可能同拍，因此 reserve_event 分支负责写 offset 0；
    // 后续 byte 使用 wr_count。超过 128 的 byte 被忽略但仍由 Capture 标错。
    wire memory_write = (reserve_event && capture_valid) ||
                        (rx_reserved && capture_valid &&
                         (wr_count < PACKET_BYTES));
    wire [ADDR_W-1:0] memory_write_addr = reserve_event
                                           ? wr_base
                                           : wr_base + wr_count;

    // ========================================================================
    // TX COMBINATIONAL ADDRESS / READ QUALIFICATION
    // ========================================================================
    wire [ADDR_W-1:0] rd_base = rd_ptr * PACKET_BYTES; // 读 slot 首地址

    // tx_start 预取 slot 的 offset 0；tx_advance 仅在当前 byte 被接收后
    // 预取下一地址。stall 时 memory_read=0，mem_read_data 保持稳定。
    // 隐式 TX 状态完全由 tx_valid 表示：0=等待 grant，1=持有一个稳定 byte。
    // 因此不再需要 rd_state。与 Byte_FIFO.out_valid_r 一样，只有握手才前进。
    wire tx_start = !tx_valid && grant && (committed_count != 0);
    wire tx_advance = tx_valid && tx_ready && !tx_packet_last;
    wire memory_read = tx_start || tx_advance;
    wire [ADDR_W-1:0] memory_read_addr = tx_start
                                          ? rd_base
                                          : rd_base + tx_output_index + 1'b1;

    assign request = (committed_count != 0);
    // 如果 href 过早结束，超出真实 tx_length 的位置补 0；后级仍发送 128 byte。
    assign tx_data = (tx_output_index < tx_length) ? mem_read_data : 8'd0;

    always @(posedge sys_clk) begin
        if (memory_write)
            packet_mem[memory_write_addr] <= capture_data;

        if (memory_read)
            mem_read_data <= packet_mem[memory_read_addr];
    end

    // -------------------------------------------------------------------------
    // RX implicit SM agent. Event/condition priority mirrors Byte_FIFO:
    //   drop_event    : no slot reserved; report overflow only.
    //   reserve_event : reserve wr_ptr and optionally store the first byte.
    //   rx_reserved   : accept later bytes; line_end commits metadata and wr_ptr.
    // Short packets are later zero-padded by TX; long packets retain their first
    // 128 bytes. Camera_Capture's length-error flag is merged at offset 9 later.
    // -------------------------------------------------------------------------
    // Synchronous reset is intentional in both memory-owning agents. Vivado
    // cannot infer block RAM when a memory port sits in an asynchronous-reset
    // process; no RAM contents are reset, only the RX control registers are.
    always @(posedge sys_clk) begin
        if (rst) begin
            wr_ptr                 <= {SLOT_W{1'b0}};
            wr_count               <= 9'd0;
            frame_overflow_pending <= 1'b0;
            overflow_pulse         <= 1'b0;
            dropped_packet_count   <= 32'd0;
        end else begin
            // overflow_pulse 是 event 输出而非 sticky flag，默认每拍清零。
            overflow_pulse <= 1'b0;

            if (drop_event) begin
                // used_count 未增加，所以 rx_reserved 始终为 0。该 href 后续的
                // capture_valid 和 line_end 都不会满足写/commit 条件，等价于原
                // WR_DROP，但不再保存一个显式 capture_drop/WR_DROP 状态位。
                frame_overflow_pending <= 1'b1;
                overflow_pulse         <= 1'b1;
                dropped_packet_count   <= dropped_packet_count + 1'b1;
            end else if (reserve_event) begin
                // line_start 与第一个 byte 允许同拍；BRAM 写口由 reserve_event
                // 选择 offset 0。used_count 在本沿 +1，下一拍 rx_reserved=1。
                wr_count <= capture_valid ? 9'd1 : 9'd0;
            end else if (rx_reserved) begin
                // rx_reserved 相当于原 WR_STORE 状态。超过 PACKET_BYTES 后保持
                // wr_count=128，并让上游 LENGTH_ERROR 表明输入过长。
                if (capture_valid && (wr_count < PACKET_BYTES))
                    wr_count <= wr_count + 1'b1;

                if (capture_line_end) begin
                    // metadata 只在 commit 时写一次。若 line_end 与最后一个
                    // valid 同拍，length 需把本拍 byte 计入。
                    cam_id_mem[wr_ptr] <= capture_cam_id;
                    flags_mem[wr_ptr]  <= capture_flags |
                                          (frame_overflow_pending
                                           ? PKT_ROW_FLAG_FRAME_OVFLOW
                                           : 8'd0);
                    length_mem[wr_ptr] <= wr_count +
                                          ((capture_valid &&
                                            (wr_count < PACKET_BYTES))
                                           ? 1'b1 : 1'b0);

                    // 成功提交的 LAST_ROW 会携带 sticky overflow，再清除它。
                    // 若 LAST_ROW 本身被 drop，没有 commit，所以不会在此清零。
                    if (capture_flags & PKT_ROW_FLAG_LAST_ROW)
                        frame_overflow_pending <= 1'b0;

                    if (wr_ptr == LINE_SLOTS - 1)
                        wr_ptr <= {SLOT_W{1'b0}};
                    else
                        wr_ptr <= wr_ptr + 1'b1;

                    // commit_event 同拍使 committed_count+1；下一拍 used 与
                    // committed 再次相等，即隐式回到 RX idle。
                    wr_count <= 9'd0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // TX implicit SM agent: tx_valid=0 等待 grant；tx_valid=1 表示输出寄存器
    // 持有一个必须保持到 ready 的 byte。该编码与 Byte_FIFO.out_valid_r 相同。
    // 获得 grant 后固定从 rd_ptr 发送 128 bytes；同步 BRAM 读与 ready/valid
    // 输出寄存器形成紧凑的预取端口。
    // Missing bytes from a short href interval are emitted as zero; Byte_Replacer
    // then overwrites the CRC tail using the actual modified packet contents.
    // -------------------------------------------------------------------------
    // See RX note above: synchronous reset preserves the BRAM read template.
    always @(posedge sys_clk) begin
        if (rst) begin
            rd_ptr         <= {SLOT_W{1'b0}};
            tx_output_index <= 8'd0;
            tx_length       <= 9'd0;
            tx_valid       <= 1'b0;
            tx_packet_last <= 1'b0;
            tx_cam_id      <= 2'd0;
            tx_flags       <= 8'd0;
        end else begin
            if (!tx_valid) begin
                // 隐式 TX idle。last 在 idle 明确为 0，metadata/data 无需清零，
                // 因为 tx_valid=0 时消费者必须忽略它们。
                tx_packet_last <= 1'b0;

                if (tx_start) begin
                    // 同步 BRAM 在该沿预取 offset 0；metadata 与 rd_ptr 同拍锁存。
                    tx_cam_id       <= cam_id_mem[rd_ptr];
                    tx_flags        <= flags_mem[rd_ptr];
                    tx_length       <= length_mem[rd_ptr];
                    tx_valid        <= 1'b1;
                    tx_packet_last  <= (PACKET_BYTES == 1);
                    tx_output_index <= 8'd0;
                end
            end else if (tx_ready) begin
                // 进入本分支等价于 tx_valid&&tx_ready 的真实握手。ready=0 时
                // 本 always 不赋值，data/index/last/metadata 全部自然保持。
                if (tx_packet_last) begin
                    tx_valid       <= 1'b0;
                    tx_packet_last <= 1'b0;

                    if (rd_ptr == LINE_SLOTS - 1)
                        rd_ptr <= {SLOT_W{1'b0}};
                    else
                        rd_ptr <= rd_ptr + 1'b1;
                end else begin
                    tx_output_index <= tx_output_index + 1'b1;
                    tx_packet_last <= (tx_output_index ==
                                       PACKET_BYTES - 2);
                end
            end
        end
    end

    // MODIFIED: all shared occupancy accounting lives here.  Simultaneous RX
    // reservation/commit and TX release are handled without cross-driving state.
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            used_count      <= 3'd0;
            committed_count <= 3'd0;
        end else begin
            case ({reserve_event, release_event})
                // 同拍一进一出时占用不变；避免两个 always block 分别写 count。
                2'b10: used_count <= used_count + 1'b1;
                2'b01: used_count <= used_count - 1'b1;
                default: used_count <= used_count;
            endcase

            case ({commit_event, release_event})
                // release 对应的包必然曾 commit，因此正常工作时不会下溢。
                2'b10: committed_count <= committed_count + 1'b1;
                2'b01: committed_count <= committed_count - 1'b1;
                default: committed_count <= committed_count;
            endcase
        end
    end

endmodule

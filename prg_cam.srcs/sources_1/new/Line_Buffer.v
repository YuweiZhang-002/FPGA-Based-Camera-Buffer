`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Line_Buffer
//
// MODIFIED (2026-07-17): lightweight four-packet ring buffer.
//
// The former slot_busy[], slot_ready[], capture_active and capture_drop arrays
// were removed.  FIFO order makes per-slot flags unnecessary; ownership is now
// represented by only:
//   wr_ptr             next packet slot written by the RX state machine
//   rd_ptr             next committed slot read by the TX state machine
//   used_count         reserved + committed + currently transmitted slots
//   committed_count    complete packets available to Arbitration
//
// RX and TX are deliberately separate always blocks.  RX owns wr_ptr and packet
// metadata writes.  TX owns rd_ptr and the ready/valid output register.  A small
// third block updates the two shared counters from one-cycle reserve/commit/
// release events, avoiding multiple drivers between RX and TX.
//////////////////////////////////////////////////////////////////////////////////
module Line_Buffer #(
    parameter integer PACKET_BYTES = 128,
    parameter integer LINE_SLOTS   = 4
)(
    input  wire       sys_clk,
    input  wire       rst,

    input  wire [7:0] capture_data,
    input  wire       capture_valid,
    input  wire       capture_line_start,
    input  wire       capture_line_end,
    input  wire [1:0] capture_cam_id,
    input  wire [7:0] capture_flags,

    // Arbitration interface. request is a level, not a one-cycle pulse, and
    // remains asserted while at least one committed packet is owned by this LB.
    output wire       request,
    input  wire       grant,

    // Selected packet stream to Byte_Replacer.
    output wire [7:0] tx_data,
    output reg        tx_valid,
    input  wire       tx_ready,
    output reg        tx_packet_last,
    output reg  [1:0] tx_cam_id,
    output reg  [7:0] tx_flags,

    output reg        overflow_pulse,
    output reg [31:0] dropped_packet_count,
    output reg  [2:0] used_count,
    output reg  [2:0] committed_count
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

    localparam [1:0] WR_IDLE  = 2'd0;
    localparam [1:0] WR_STORE = 2'd1;
    localparam [1:0] WR_DROP  = 2'd2;

    localparam       RD_IDLE  = 1'b0;
    localparam       RD_SEND  = 1'b1;

    localparam [7:0] PKT_ROW_FLAG_LAST_ROW     = 8'h02;
    localparam [7:0] PKT_ROW_FLAG_FRAME_OVFLOW = 8'h04;

    (* ram_style = "block" *) reg [7:0] packet_mem
        [0:PACKET_BYTES*LINE_SLOTS-1];

    reg [1:0] cam_id_mem [0:LINE_SLOTS-1];
    reg [7:0] flags_mem  [0:LINE_SLOTS-1];
    reg [8:0] length_mem [0:LINE_SLOTS-1];

    reg [1:0] wr_state;
    reg       rd_state;
    reg [SLOT_W-1:0] wr_ptr;
    reg [SLOT_W-1:0] rd_ptr;
    reg [8:0] wr_count;
    reg [7:0] tx_output_index;
    reg [8:0] tx_length;
    reg [7:0] mem_read_data;

    // Set after a packet is dropped because all slots are occupied.  The bit is
    // merged into the first later packet that can be transmitted and remains set
    // until a committed LAST_ROW packet reports it.  A dropped last-row packet
    // cannot carry metadata itself, so retaining the bit prevents silent loss.
    reg frame_overflow_pending;

    wire reserve_event = capture_line_start && (wr_state == WR_IDLE) &&
                         (used_count < LINE_SLOTS);
    wire drop_event    = capture_line_start && (wr_state == WR_IDLE) &&
                         (used_count >= LINE_SLOTS);
    wire commit_event  = capture_line_end && (wr_state == WR_STORE);
    wire release_event = tx_valid && tx_ready && tx_packet_last;

    wire [ADDR_W-1:0] wr_base = wr_ptr * PACKET_BYTES;
    wire [ADDR_W-1:0] rd_base = rd_ptr * PACKET_BYTES;

    // MODIFIED: exactly one write address and one read address feed a standalone
    // simple-dual-port RAM template. Keeping packet_mem out of the resettable RX
    // and TX agents is what permits a RAMB18 inference for each 512x8 buffer.
    wire memory_write = (reserve_event && capture_valid) ||
                        ((wr_state == WR_STORE) && capture_valid &&
                         (wr_count < PACKET_BYTES));
    wire [ADDR_W-1:0] memory_write_addr = reserve_event
                                           ? wr_base
                                           : wr_base + wr_count;

    wire tx_start = (rd_state == RD_IDLE) && grant &&
                    (committed_count != 0);
    wire tx_advance = (rd_state == RD_SEND) && tx_valid && tx_ready &&
                      !tx_packet_last;
    wire memory_read = tx_start || tx_advance;
    wire [ADDR_W-1:0] memory_read_addr = tx_start
                                          ? rd_base
                                          : rd_base + tx_output_index + 1'b1;

    assign request = (committed_count != 0);
    assign tx_data = (tx_output_index < tx_length) ? mem_read_data : 8'd0;

    always @(posedge sys_clk) begin
        if (memory_write)
            packet_mem[memory_write_addr] <= capture_data;

        if (memory_read)
            mem_read_data <= packet_mem[memory_read_addr];
    end

    // -------------------------------------------------------------------------
    // RX agent: reserve one slot, store at most 128 incoming bytes, then commit
    // the slot atomically when href falls. Short packets are later zero-padded by
    // the TX agent; long packets retain their first 128 bytes. In both cases the
    // Camera_Capture length-error flag is merged at packet offset 9 downstream.
    // -------------------------------------------------------------------------
    // Synchronous reset is intentional in both memory-owning agents. Vivado
    // cannot infer block RAM when a memory port sits in an asynchronous-reset
    // process; no RAM contents are reset, only the RX control registers are.
    always @(posedge sys_clk) begin
        if (rst) begin
            wr_state               <= WR_IDLE;
            wr_ptr                 <= {SLOT_W{1'b0}};
            wr_count               <= 9'd0;
            frame_overflow_pending <= 1'b0;
            overflow_pulse         <= 1'b0;
            dropped_packet_count   <= 32'd0;
        end else begin
            overflow_pulse <= 1'b0;

            case (wr_state)
                WR_IDLE: begin
                    if (drop_event) begin
                        // MODIFIED: no capture_drop flag is needed. WR_DROP is
                        // the complete and explicit representation of this case.
                        wr_state               <= WR_DROP;
                        frame_overflow_pending <= 1'b1;
                        overflow_pulse         <= 1'b1;
                        dropped_packet_count   <= dropped_packet_count + 1'b1;
                    end else if (reserve_event) begin
                        wr_state <= WR_STORE;
                        if (capture_valid) begin
                            wr_count <= 9'd1;
                        end else begin
                            wr_count <= 9'd0;
                        end
                    end
                end

                WR_STORE: begin
                    if (capture_valid && (wr_count < PACKET_BYTES)) begin
                        wr_count <= wr_count + 1'b1;
                    end

                    if (capture_line_end) begin
                        cam_id_mem[wr_ptr] <= capture_cam_id;
                        flags_mem[wr_ptr]  <= capture_flags |
                                              (frame_overflow_pending
                                               ? PKT_ROW_FLAG_FRAME_OVFLOW
                                               : 8'd0);
                        length_mem[wr_ptr] <= wr_count +
                                              ((capture_valid &&
                                                (wr_count < PACKET_BYTES))
                                               ? 1'b1 : 1'b0);

                        // Once the last delivered row reports the sticky frame
                        // overflow, the next frame starts with a clean flag.
                        if (capture_flags & PKT_ROW_FLAG_LAST_ROW)
                            frame_overflow_pending <= 1'b0;

                        if (wr_ptr == LINE_SLOTS - 1)
                            wr_ptr <= {SLOT_W{1'b0}};
                        else
                            wr_ptr <= wr_ptr + 1'b1;

                        wr_count <= 9'd0;
                        wr_state <= WR_IDLE;
                    end
                end

                WR_DROP: begin
                    // Ignore every byte until this malformed/unbuffered packet
                    // ends. The ring pointers and counters are left untouched.
                    if (capture_line_end)
                        wr_state <= WR_IDLE;
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // TX agent: after grant, emit exactly 128 bytes from rd_ptr.  The memory read
    // and ready/valid output register form a compact synchronous BRAM read port.
    // Missing bytes from a short href interval are emitted as zero; Byte_Replacer
    // then overwrites the CRC tail using the actual modified packet contents.
    // -------------------------------------------------------------------------
    // See RX note above: synchronous reset preserves the BRAM read template.
    always @(posedge sys_clk) begin
        if (rst) begin
            rd_state       <= RD_IDLE;
            rd_ptr         <= {SLOT_W{1'b0}};
            tx_output_index <= 8'd0;
            tx_length       <= 9'd0;
            tx_valid       <= 1'b0;
            tx_packet_last <= 1'b0;
            tx_cam_id      <= 2'd0;
            tx_flags       <= 8'd0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    tx_valid       <= 1'b0;
                    tx_packet_last <= 1'b0;

                    if (tx_start) begin
                        tx_cam_id <= cam_id_mem[rd_ptr];
                        tx_flags  <= flags_mem[rd_ptr];
                        tx_length <= length_mem[rd_ptr];
                        tx_valid       <= 1'b1;
                        tx_packet_last <= (PACKET_BYTES == 1);
                        tx_output_index <= 8'd0;
                        rd_state       <= RD_SEND;
                    end
                end

                RD_SEND: begin
                    if (tx_valid && tx_ready) begin
                        if (tx_packet_last) begin
                            tx_valid       <= 1'b0;
                            tx_packet_last <= 1'b0;
                            rd_state       <= RD_IDLE;

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
            endcase
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
                2'b10: used_count <= used_count + 1'b1;
                2'b01: used_count <= used_count - 1'b1;
                default: used_count <= used_count;
            endcase

            case ({commit_event, release_event})
                2'b10: committed_count <= committed_count + 1'b1;
                2'b01: committed_count <= committed_count - 1'b1;
                default: committed_count <= committed_count;
            endcase
        end
    end

endmodule

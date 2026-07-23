`timescale 1ns / 1ps
`default_nettype none

// Independent regression for the Stage-b source path:
// producer -> Byte_FIFO -> Ethernet_Frame_Adapter -> ready/valid sink.
module tb_Byte_FIFO_Ethernet_Source;
    localparam integer PACKET_BYTES = 128;
    localparam integer FRAME_BYTES  = 14 + PACKET_BYTES;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic [8:0] fifo_in_data = 9'd0;
    logic       fifo_in_valid = 1'b0;
    wire        fifo_in_ready;
    wire [8:0]  fifo_out_data;
    wire        fifo_out_valid;
    wire        fifo_out_ready;
    wire [15:0] fifo_level;
    wire        fifo_almost_full;

    wire [7:0] frame_data;
    wire       frame_valid;
    logic      frame_ready;
    wire       frame_last;

    integer expected_ids [0:15];
    integer expected_write = 0;
    integer expected_read = 0;
    integer frame_byte_index = 0;
    integer completed_frames = 0;
    integer cycle_count = 0;
    integer fifo_push_count = 0;
    integer fifo_pop_count = 0;
    integer frame_handshake_count = 0;
    integer last_stall_count = 0;

    logic periodic_stall_enable = 1'b0;
    logic last_stall_enable = 1'b0;
    logic force_not_ready = 1'b0;
    logic saw_fifo_empty_mid_frame = 1'b0;
    logic saw_last_byte_stall = 1'b0;

    logic [7:0] prev_frame_data;
    logic       prev_frame_valid;
    logic       prev_frame_ready;
    logic       prev_frame_last;
    logic [8:0] prev_fifo_data;
    logic       prev_fifo_valid;
    logic       prev_fifo_ready;

    always #5 clk = ~clk;

    Byte_FIFO #(
        .DEPTH        (512),
        .PACKET_BYTES (PACKET_BYTES)
    ) u_byte_fifo (
        .clk         (clk),
        .rst         (rst),
        .in_data     (fifo_in_data),
        .in_valid    (fifo_in_valid),
        .in_ready    (fifo_in_ready),
        .out_data    (fifo_out_data),
        .out_valid   (fifo_out_valid),
        .out_ready   (fifo_out_ready),
        .level       (fifo_level),
        .almost_full (fifo_almost_full)
    );

    Ethernet_Frame_Adapter u_frame_adapter (
        .clk          (clk),
        .rst          (rst),
        .packet_data  (fifo_out_data[7:0]),
        .packet_valid (fifo_out_valid),
        .packet_ready (fifo_out_ready),
        .packet_last  (fifo_out_data[8]),
        .frame_data   (frame_data),
        .frame_valid  (frame_valid),
        .frame_ready  (frame_ready),
        .frame_last   (frame_last)
    );

    function automatic [7:0] payload_byte(input integer packet_id,
                                           input integer byte_index);
        payload_byte = (packet_id * 8'h31 + byte_index) & 8'hff;
    endfunction

    function automatic [7:0] header_byte(input integer byte_index);
        case (byte_index)
            0, 1, 2, 3, 4, 5: header_byte = 8'hff;
            6:                 header_byte = 8'h02;
            7, 8, 9, 10:      header_byte = 8'h00;
            11:                header_byte = 8'h02;
            12:                header_byte = 8'h88;
            13:                header_byte = 8'hb5;
            default:           header_byte = 8'h00;
        endcase
    endfunction

    always_comb begin
        if (force_not_ready) begin
            frame_ready = 1'b0;
        end else if (last_stall_enable && frame_valid && frame_last &&
                     last_stall_count < 5) begin
            frame_ready = 1'b0;
        end else if (periodic_stall_enable) begin
            frame_ready = ((cycle_count % 7) != 2) &&
                          ((cycle_count % 11) != 5);
        end else begin
            frame_ready = 1'b1;
        end
    end

    // Scoreboard, handshake counters, and explicit TLAST-position checking.
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;

        if (rst) begin
            expected_read          <= expected_write;
            frame_byte_index       <= 0;
            fifo_push_count        <= 0;
            fifo_pop_count         <= 0;
            frame_handshake_count  <= 0;
            last_stall_count       <= 0;
        end else begin
            if (fifo_in_valid && fifo_in_ready)
                fifo_push_count <= fifo_push_count + 1;

            if (fifo_out_valid && fifo_out_ready)
                fifo_pop_count <= fifo_pop_count + 1;

            if ((frame_byte_index >= 14) && (frame_byte_index < FRAME_BYTES) &&
                !fifo_out_valid)
                saw_fifo_empty_mid_frame <= 1'b1;

            if (last_stall_enable && frame_valid && frame_last && !frame_ready) begin
                last_stall_count    <= last_stall_count + 1;
                saw_last_byte_stall <= 1'b1;
            end else if (!last_stall_enable) begin
                last_stall_count <= 0;
            end

            if (frame_valid && frame_ready) begin
                frame_handshake_count <= frame_handshake_count + 1;

                if (expected_read >= expected_write)
                    $fatal(1, "Unexpected frame byte %02x at index %0d",
                           frame_data, frame_byte_index);

                if (frame_byte_index < 14) begin
                    if (frame_data !== header_byte(frame_byte_index))
                        $fatal(1, "Header mismatch index=%0d got=%02x exp=%02x",
                               frame_byte_index, frame_data,
                               header_byte(frame_byte_index));
                end else begin
                    if (frame_data !== payload_byte(
                            expected_ids[expected_read], frame_byte_index - 14))
                        $fatal(1, "Payload mismatch packet=%0d index=%0d got=%02x exp=%02x",
                               expected_ids[expected_read], frame_byte_index - 14,
                               frame_data, payload_byte(expected_ids[expected_read],
                                                        frame_byte_index - 14));
                end

                if (frame_last !== (frame_byte_index == FRAME_BYTES - 1))
                    $fatal(1, "TLAST position mismatch at frame index %0d",
                           frame_byte_index);

                if (frame_last) begin
                    frame_byte_index <= 0;
                    completed_frames <= completed_frames + 1;
                    expected_read    <= expected_read + 1;
                end else begin
                    frame_byte_index <= frame_byte_index + 1;
                end
            end
        end
    end

    // Both producer-facing FIFO output and adapter output must remain stable
    // for the whole interval in which valid=1 and ready=0.
    always @(posedge clk) begin
        if (rst) begin
            prev_frame_valid <= 1'b0;
            prev_fifo_valid  <= 1'b0;
        end else begin
            if (prev_frame_valid && !prev_frame_ready) begin
                if (!frame_valid || frame_data !== prev_frame_data ||
                    frame_last !== prev_frame_last)
                    $fatal(1, "Frame AXIS changed while stalled");
            end

            if (prev_fifo_valid && !prev_fifo_ready) begin
                if (!fifo_out_valid || fifo_out_data !== prev_fifo_data)
                    $fatal(1, "Byte_FIFO output changed while stalled");
            end

            prev_frame_data  <= frame_data;
            prev_frame_valid <= frame_valid;
            prev_frame_ready <= frame_ready;
            prev_frame_last  <= frame_last;
            prev_fifo_data   <= fifo_out_data;
            prev_fifo_valid  <= fifo_out_valid;
            prev_fifo_ready  <= fifo_out_ready;
        end
    end

    task automatic queue_expected(input integer packet_id);
        begin
            expected_ids[expected_write] = packet_id;
            expected_write = expected_write + 1;
        end
    endtask

    // Drives consecutive FIFO input handshakes with no intentional bubbles.
    task automatic send_bytes(input integer packet_id,
                              input integer first_byte,
                              input integer byte_count);
        integer index;
        integer accepted;
        begin
            index = first_byte;
            accepted = 0;
            @(negedge clk);
            fifo_in_data  = {(index == PACKET_BYTES-1),
                             payload_byte(packet_id, index)};
            fifo_in_valid = 1'b1;

            while (accepted < byte_count) begin
                @(posedge clk);
                if (fifo_in_valid && fifo_in_ready) begin
                    accepted = accepted + 1;
                    index = index + 1;
                    @(negedge clk);
                    if (accepted == byte_count) begin
                        fifo_in_valid = 1'b0;
                        fifo_in_data  = 9'd0;
                    end else begin
                        fifo_in_data = {(index == PACKET_BYTES-1),
                                        payload_byte(packet_id, index)};
                    end
                end
            end
        end
    endtask

    task automatic wait_for_frames(input integer target);
        begin
            while (completed_frames < target)
                @(posedge clk);
        end
    endtask

    initial begin
        repeat (6) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // FIFO-empty boundary: no source data must not create a frame.
        repeat (20) @(posedge clk);
        if (frame_valid || fifo_out_valid || fifo_level != 0)
            $fatal(1, "Empty FIFO produced output activity");

        // 1) Normal continuous packet.
        queue_expected(0);
        send_bytes(0, 0, PACKET_BYTES);
        wait_for_frames(1);

        // 2) Temporary FIFO empty in the middle of a frame.  Taxi's eventual
        // frame FIFO can absorb this legal AXI-Stream pause without data loss.
        queue_expected(1);
        send_bytes(1, 0, 8);
        repeat (50) @(posedge clk);
        send_bytes(1, 8, PACKET_BYTES-8);
        wait_for_frames(2);

        // 3) Periodic backpressure plus a guaranteed five-cycle stall on the
        // final payload byte.  Data and TLAST stability are checked above.
        periodic_stall_enable = 1'b1;
        last_stall_enable = 1'b1;
        queue_expected(2);
        send_bytes(2, 0, PACKET_BYTES);
        wait_for_frames(3);
        periodic_stall_enable = 1'b0;
        last_stall_enable = 1'b0;

        while (fifo_level != 0 || fifo_out_valid)
            @(posedge clk);

        // 4) Reset interrupts an incomplete packet.  The partial FIFO contents
        // and partial Adapter frame are discarded; no stale byte may reappear.
        queue_expected(3);
        send_bytes(3, 0, 32);
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        if (fifo_level != 0 || fifo_out_valid || frame_valid)
            $fatal(1, "Reset did not clear FIFO/Adapter visible state");

        // 5/6) Post-reset continuous and stalled packets.  Final counters are
        // checked in the reset epoch so unexplained FIFO backlog is detectable.
        queue_expected(4);
        send_bytes(4, 0, PACKET_BYTES);
        wait_for_frames(4);

        periodic_stall_enable = 1'b1;
        last_stall_enable = 1'b1;
        queue_expected(5);
        send_bytes(5, 0, PACKET_BYTES);
        wait_for_frames(5);
        periodic_stall_enable = 1'b0;
        last_stall_enable = 1'b0;

        while (fifo_level != 0 || fifo_out_valid)
            @(posedge clk);
        repeat (5) @(posedge clk);

        if (!saw_fifo_empty_mid_frame)
            $fatal(1, "Temporary-empty coverage point was not reached");
        if (!saw_last_byte_stall)
            $fatal(1, "Last-byte stall coverage point was not reached");
        if (fifo_push_count != 2*PACKET_BYTES ||
            fifo_pop_count != 2*PACKET_BYTES)
            $fatal(1, "Post-reset FIFO handshake count mismatch push=%0d pop=%0d",
                   fifo_push_count, fifo_pop_count);
        if (frame_handshake_count != 2*FRAME_BYTES)
            $fatal(1, "Post-reset frame handshake count mismatch got=%0d exp=%0d",
                   frame_handshake_count, 2*FRAME_BYTES);
        if (expected_read != expected_write)
            $fatal(1, "Expected packet queue not empty read=%0d write=%0d",
                   expected_read, expected_write);

        $display("PASS: Byte_FIFO Ethernet source normal/empty/backpressure/last-stall/reset");
        $display("PASS: completed_frames=%0d post_reset_push=%0d pop=%0d frame_hs=%0d",
                 completed_frames, fifo_push_count, fifo_pop_count,
                 frame_handshake_count);
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "TIMEOUT: tb_Byte_FIFO_Ethernet_Source");
    end

endmodule

`default_nettype wire

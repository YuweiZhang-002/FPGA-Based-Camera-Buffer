`timescale 1ns / 1ps
`default_nettype none

module tb_Ethernet_Frame_Adapter;

    logic       clk = 1'b0;
    logic       rst = 1'b1;
    logic [7:0] packet_data = 8'h00;
    logic       packet_valid = 1'b0;
    wire        packet_ready;
    logic       packet_last = 1'b0;
    wire [7:0]  frame_data;
    wire        frame_valid;
    logic       frame_ready = 1'b0;
    wire        frame_last;

    logic [7:0] previous_data;
    logic       previous_valid;
    logic       previous_last;
    logic       previous_stalled = 1'b0;

    integer payload_index = 0;
    integer frame_index = 0;
    integer cycle_count = 0;

    Ethernet_Frame_Adapter dut (
        .clk          (clk),
        .rst          (rst),
        .packet_data  (packet_data),
        .packet_valid (packet_valid),
        .packet_ready (packet_ready),
        .packet_last  (packet_last),
        .frame_data   (frame_data),
        .frame_valid  (frame_valid),
        .frame_ready  (frame_ready),
        .frame_last   (frame_last)
    );

    always #5 clk = ~clk;

    function automatic logic [7:0] expected_byte(input integer index);
        if (index < 6) begin
            expected_byte = 8'hff;
        end else begin
            case (index)
                6: expected_byte = 8'h02;
                7, 8, 9, 10: expected_byte = 8'h00;
                11: expected_byte = 8'h02;
                12: expected_byte = 8'h88;
                13: expected_byte = 8'hb5;
                default: expected_byte = index - 14;
            endcase
        end
    endfunction

    // Deterministic stalls exercise header, payload, and final-byte holding.
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            frame_ready <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            frame_ready <= !((cycle_count % 7 == 2) ||
                             (cycle_count % 11 == 5) ||
                             (payload_index == 127 && cycle_count[1:0] != 2'b11));
        end
    end

    // Ready/valid source for one fixed 128-byte payload, 00..7F.
    always_ff @(posedge clk) begin
        if (rst) begin
            payload_index <= 0;
            packet_data   <= 8'h00;
            packet_valid  <= 1'b0;
            packet_last   <= 1'b0;
        end else begin
            packet_valid <= 1'b1;
            packet_data  <= payload_index[7:0];
            packet_last  <= payload_index == 127;

            if (packet_valid && packet_ready) begin
                if (packet_last) begin
                    packet_valid <= 1'b0;
                end else begin
                    payload_index <= payload_index + 1;
                    packet_data   <= payload_index + 1;
                    packet_last   <= payload_index == 126;
                end
            end
        end
    end

    // Check every accepted byte and tlast placement.
    always_ff @(posedge clk) begin
        if (rst) begin
            frame_index <= 0;
        end else if (frame_valid && frame_ready) begin
            if (frame_data !== expected_byte(frame_index)) begin
                $fatal(1, "byte %0d: got %02x expected %02x",
                       frame_index, frame_data, expected_byte(frame_index));
            end

            if (frame_last !== (frame_index == 141)) begin
                $fatal(1, "byte %0d: unexpected frame_last=%b",
                       frame_index, frame_last);
            end

            if (frame_index == 141) begin
                $display("PASS: 14-byte Ethernet header + 128-byte payload; stall stability verified");
                $finish;
            end

            frame_index <= frame_index + 1;
        end
    end

    // AXI-Stream stability rule: once stalled, valid/data/last cannot change.
    always_ff @(posedge clk) begin
        if (rst) begin
            previous_stalled <= 1'b0;
        end else begin
            if (previous_stalled) begin
                if (!frame_valid || frame_data !== previous_data ||
                    frame_last !== previous_last) begin
                    $fatal(1, "AXI-Stream output changed while stalled");
                end
            end

            previous_data    <= frame_data;
            previous_valid   <= frame_valid;
            previous_last    <= frame_last;
            previous_stalled <= frame_valid && !frame_ready;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;

        repeat (2000) @(posedge clk);
        $fatal(1, "timeout");
    end

endmodule

`default_nettype wire

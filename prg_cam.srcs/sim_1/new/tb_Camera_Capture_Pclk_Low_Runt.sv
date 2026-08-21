`timescale 1ns / 1ps

// Hardware regression for attempt21.  ILA observed a legitimate byte boundary
// whose synchronized PCLK low phase lasted exactly one 100 MHz sample.  DATA
// changed to the next byte and the following high phase was stable, so the
// receiver must accept that high phase while continuing to require two high
// samples (which still rejects a one-sample high glitch).
module tb_Camera_Capture_Pclk_Low_Runt;
    localparam integer PACKET_BYTES = 16;

    reg        sys_clk = 1'b0;
    reg        pclk = 1'b0;
    reg        rst = 1'b1;
    reg        capture_enable = 1'b1;
    reg        href = 1'b0;
    reg  [7:0] camera_data = 8'h00;

    wire [7:0] byte_data;
    wire       byte_valid;
    wire       line_start;
    wire       line_end;
    wire [7:0] line_flags;
    wire [15:0] last_line_byte_count;
    wire       length_error_pulse;

    integer errors = 0;
    integer received = 0;
    integer i;

    always #5 sys_clk = ~sys_clk;

    Camera_Capture #(
        .CAM_ID              (2'd0),
        .PACKET_BYTES        (PACKET_BYTES),
        .LINES_PER_FRAME     (480),
        .INGRESS_CRC_ENABLE  (1'b0), // low-runt test uses no CRC vector
        .PCLK_FILTER_LEN     (2),
        .PCLK_LOW_FILTER_LEN (1)
    ) dut (
        .pclk                 (pclk),
        .sys_clk              (sys_clk),
        .rst                  (rst),
        .capture_enable       (capture_enable),
        .href                 (href),
        .camera_data          (camera_data),
        .byte_data            (byte_data),
        .byte_valid           (byte_valid),
        .line_start           (line_start),
        .line_end             (line_end),
        .line_cam_id          (),
        .line_flags           (line_flags),
        .current_row_idx      (),
        .current_byte_count   (),
        .last_line_byte_count (last_line_byte_count),
        .length_error_pulse   (length_error_pulse)
    );

    always @(posedge sys_clk) begin
        if (!rst && byte_valid) begin
            if (byte_data !== received[7:0]) begin
                $error("low-runt byte mismatch index=%0d got=%02x expected=%02x",
                       received, byte_data, received[7:0]);
                errors = errors + 1;
            end
            received = received + 1;
        end
    end

    // Change PCLK only on sys_clk falling edges.  Therefore a one-cycle low
    // interval is propagated by the 2FF synchronizer as exactly one low sample,
    // matching ILA samples 2104/2106 in the attempt21 capture.
    task automatic send_byte;
        input integer value;
        input integer low_cycles_after;
        integer cycle;
        begin
            camera_data = value[7:0];
            @(negedge sys_clk);
            pclk = 1'b1;
            for (cycle = 0; cycle < 4; cycle = cycle + 1)
                @(negedge sys_clk);
            pclk = 1'b0;
            for (cycle = 0; cycle < low_cycles_after; cycle = cycle + 1)
                @(negedge sys_clk);
        end
    endtask

    initial begin
        repeat (8) @(posedge sys_clk);
        rst = 1'b0;
        repeat (10) @(posedge sys_clk);

        href = 1'b1;
        for (i = 0; i < PACKET_BYTES; i = i + 1)
            // Boundary 5->6 has only one observable low sample.  All other
            // phases retain the nominal four-sample width.
            send_byte(i, (i == 5) ? 1 : 4);

        href = 1'b0;
        wait (line_end);
        repeat (6) @(posedge sys_clk);

        if (received != PACKET_BYTES) begin
            $error("low-runt byte count=%0d expected=%0d", received, PACKET_BYTES);
            errors = errors + 1;
        end
        if (last_line_byte_count != PACKET_BYTES ||
            line_flags != 8'h00 || length_error_pulse) begin
            $error("low-runt line result count=%0d flags=%02x pulse=%0b",
                   last_line_byte_count, line_flags, length_error_pulse);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: one-sample low phase re-arms a stable high byte");
        else
            $fatal(1, "FAIL: errors=%0d", errors);
        $finish;
    end

    initial begin
        #100us;
        $fatal(1, "TIMEOUT: Camera_Capture low-runt regression");
    end
endmodule

`timescale 1ns / 1ps

// Regression for the RP2350A -> FPGA asynchronous PCLK boundary.
// A one-sys_clk-wide high sample inside the physical PCLK low phase must not
// consume a byte, suppress the next real edge, or replay the previous byte.
module tb_Camera_Capture_Pclk_Glitch;
    localparam integer PACKET_BYTES = 128;

    reg        sys_clk = 1'b0;
    reg        pclk = 1'b0;
    reg        rst = 1'b1;
    reg        capture_enable = 1'b1;
    reg        href = 1'b0;
    reg  [7:0] camera_data = 8'd0;

    wire [7:0] byte_data;
    wire       byte_valid;
    wire       line_start;
    wire       line_end;
    wire [7:0] line_flags;
    wire [15:0] last_line_byte_count;
    wire       length_error_pulse;

    integer errors = 0;
    integer received = 0;
    integer total_received = 0;
    integer expected_base = 0;
    integer starts = 0;
    integer ends = 0;

    always #5 sys_clk = ~sys_clk;

    Camera_Capture #(
        .CAM_ID          (2'd0),
        .PACKET_BYTES    (PACKET_BYTES),
        .LINES_PER_FRAME (480),
        .INGRESS_CRC_ENABLE(1'b0), // glitch test uses no CRC vector
        .PCLK_FILTER_LEN (2)
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
        if (!rst) begin
            if (line_start) begin
                starts = starts + 1;
                received = 0;
            end
            if (byte_valid) begin
                if (byte_data !== ((expected_base + received) & 8'hff)) begin
                    $error("PCLK CDC byte mismatch index=%0d got=%02x expected=%02x",
                           received, byte_data,
                           ((expected_base + received) & 8'hff));
                    errors = errors + 1;
                end
                received = received + 1;
                total_received = total_received + 1;
            end
            if (line_end)
                ends = ends + 1;
        end
    end

    task automatic real_pclk_byte;
        input integer value;
        input integer inject_high_glitch;
        begin
            // Data is established before the real rising edge and remains
            // stable for the whole byte cell, matching the source contract.
            camera_data = value[7:0];
            #5 pclk = 1'b1;
            #30 pclk = 1'b0;

            // Ten ns is one 100 MHz observation interval.  The old consecutive
            // low-vote filter can merge the surrounding real pulses when this
            // sample lands between them.
            if (inject_high_glitch) begin
                #10 pclk = 1'b1;
                #10 pclk = 1'b0;
                #5;
            end else begin
                // Together with the next call's leading #5, the physical low
                // phase is exactly 20 ns.  That still satisfies a two-sample
                // 100 MHz qualifier, but exposes nonblocking-state gating that
                // consults the previous qualified-high state.
                #15;
            end
        end
    endtask

    task automatic slow_pclk_byte_with_optional_glitch;
        input integer value;
        input integer inject_high_glitch;
        begin
            camera_data = value[7:0];
            #20 pclk = 1'b1;
            #30 pclk = 1'b0;
            if (inject_high_glitch) begin
                #10 pclk = 1'b1;
                #10 pclk = 1'b0;
                #10;
            end else begin
                #30;
            end
        end
    endtask

    integer i;
    initial begin
        repeat (8) @(posedge sys_clk);
        rst = 1'b0;
        repeat (10) @(posedge sys_clk);

        expected_base = 0;
        href = 1'b1;
        // Exercise several header offsets, including offset 8/9 where an old
        // byte replay becomes a false row_flags value.
        for (i = 0; i < PACKET_BYTES; i = i + 1)
            real_pclk_byte(i, 0);

        #1 href = 1'b0;
        wait (line_end);
        repeat (8) @(posedge sys_clk);

        expected_base = 128;
        href = 1'b1;
        for (i = 0; i < PACKET_BYTES; i = i + 1)
            slow_pclk_byte_with_optional_glitch(
                expected_base + i, (i == 7) || (i == 31) || (i == 95));
        #1 href = 1'b0;
        wait (line_end);
        repeat (4) @(posedge sys_clk);

        if (starts != 2 || ends != 2) begin
            $error("line boundary mismatch starts=%0d ends=%0d", starts, ends);
            errors = errors + 1;
        end
        if (total_received != 2*PACKET_BYTES) begin
            $error("total byte count mismatch received=%0d expected=%0d",
                   total_received, 2*PACKET_BYTES);
            errors = errors + 1;
        end
        if (last_line_byte_count != PACKET_BYTES ||
            line_flags != 8'h00 || length_error_pulse) begin
            $error("length result count=%0d flags=%02x pulse=%0b",
                   last_line_byte_count, line_flags, length_error_pulse);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: PCLK low-phase glitches neither drop nor replay bytes");
        else
            $fatal(1, "FAIL: errors=%0d", errors);
        $finish;
    end

    initial begin
        #100us;
        $fatal(1, "TIMEOUT: PCLK glitch regression");
    end
endmodule

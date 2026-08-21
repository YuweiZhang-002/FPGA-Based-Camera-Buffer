`timescale 1ns / 1ps

module tb_Camera_Capture_Boundary_Control;
    localparam integer PACKET_BYTES = 128;

    reg        sys_clk = 1'b0;
    reg        pclk = 1'b0;
    reg        rst = 1'b1;
    reg        capture_enable = 1'b0;
    reg        href = 1'b0;
    reg  [7:0] camera_data = 8'd0;

    wire [7:0] byte_data;
    wire       byte_valid;
    wire       line_start;
    wire       line_end;
    wire [1:0] line_cam_id;
    wire [7:0] line_flags;
    wire [15:0] current_row_idx;
    wire [15:0] current_byte_count;
    wire [15:0] last_line_byte_count;
    wire       length_error_pulse;

    integer errors = 0;
    integer accepted_lines = 0;
    integer accepted_bytes = 0;
    integer expected_base = 0;
    integer line_start_count = 0;
    integer line_end_count = 0;

    always #5  sys_clk = ~sys_clk; // 100 MHz
    always #40 pclk = ~pclk;       // 12.5 MHz source clock

    Camera_Capture #(
        .CAM_ID          (2'd0),
        .PACKET_BYTES    (PACKET_BYTES),
        .LINES_PER_FRAME (480),
        .INGRESS_CRC_ENABLE(1'b0), // boundary test, not a CRC-vector test
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
        .line_cam_id          (line_cam_id),
        .line_flags           (line_flags),
        .current_row_idx      (current_row_idx),
        .current_byte_count   (current_byte_count),
        .last_line_byte_count (last_line_byte_count),
        .length_error_pulse   (length_error_pulse)
    );

    always @(posedge sys_clk) begin
        if (!rst) begin
            if (line_start) begin
                line_start_count = line_start_count + 1;
                accepted_bytes = 0;
            end

            if (byte_valid) begin
                if (byte_data !== ((expected_base + accepted_bytes) & 8'hff)) begin
                    $error("byte mismatch line=%0d index=%0d got=%02x expected=%02x",
                           accepted_lines, accepted_bytes, byte_data,
                           ((expected_base + accepted_bytes) & 8'hff));
                    errors = errors + 1;
                end
                accepted_bytes = accepted_bytes + 1;
            end

            if (line_end) begin
                line_end_count = line_end_count + 1;
                if (accepted_bytes != PACKET_BYTES) begin
                    $error("accepted byte count=%0d expected=%0d",
                           accepted_bytes, PACKET_BYTES);
                    errors = errors + 1;
                end
                if (last_line_byte_count != PACKET_BYTES) begin
                    $error("DUT byte count=%0d expected=%0d",
                           last_line_byte_count, PACKET_BYTES);
                    errors = errors + 1;
                end
                if (line_flags != 8'h00 || length_error_pulse) begin
                    $error("unexpected length error flags=%02x pulse=%0b",
                           line_flags, length_error_pulse);
                    errors = errors + 1;
                end
                accepted_lines = accepted_lines + 1;
            end
        end
    end

    task automatic send_partial_while_disabled;
        integer i;
        begin
            // Begin with HREF already high, then request capture.  No part of
            // this line may leak through; arming waits for the low interval.
            @(negedge pclk);
            href = 1'b1;
            for (i = 0; i < 32; i = i + 1) begin
                camera_data = 8'hD0 + i;
                if (i == 8)
                    capture_enable = 1'b1;
                @(negedge pclk);
            end
            #1 href = 1'b0;
            repeat (8) @(posedge sys_clk);
        end
    endtask

    task automatic send_full_line;
        input integer base;
        input integer disable_after_byte;
        integer i;
        begin
            expected_base = base;
            @(negedge pclk);
            href = 1'b1;
            camera_data = base[7:0];
            for (i = 1; i < PACKET_BYTES; i = i + 1) begin
                @(negedge pclk);
                camera_data = (base + i) & 8'hff;
                if (i == disable_after_byte)
                    capture_enable = 1'b0;
            end
            // Stress the old mismatch: HREF falls just after the last physical
            // PCLK rising edge, while that edge is still in the debounce pipe.
            @(posedge pclk);
            #1 href = 1'b0;
            wait (line_end);
            @(posedge sys_clk);
            camera_data = 8'h00;
            repeat (6) @(posedge sys_clk);
        end
    endtask

    task automatic send_ignored_line;
        integer i;
        begin
            @(negedge pclk);
            href = 1'b1;
            for (i = 0; i < PACKET_BYTES; i = i + 1) begin
                camera_data = i[7:0];
                @(negedge pclk);
            end
            #1 href = 1'b0;
            repeat (10) @(posedge sys_clk);
        end
    endtask

    initial begin
        repeat (8) @(posedge sys_clk);
        rst = 1'b0;
        repeat (8) @(posedge sys_clk);

        send_partial_while_disabled();
        if (line_start_count != 0 || line_end_count != 0) begin
            $error("mid-line enable leaked a partial line start=%0d end=%0d",
                   line_start_count, line_end_count);
            errors = errors + 1;
        end

        // Capture one complete line, but request stop in its middle.  The line
        // must finish normally and no downstream reset is involved.
        send_full_line(8'h10, 64);
        send_ignored_line();
        if (accepted_lines != 1) begin
            $error("disabled line was not ignored accepted_lines=%0d", accepted_lines);
            errors = errors + 1;
        end

        // Re-enable between lines and capture the next complete line.
        capture_enable = 1'b1;
        repeat (8) @(posedge sys_clk);
        send_full_line(8'h80, -1);

        if (accepted_lines != 2 || line_start_count != 2 || line_end_count != 2) begin
            $error("boundary counts lines=%0d start=%0d end=%0d",
                   accepted_lines, line_start_count, line_end_count);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: coherent PCLK data, delayed line commit, and boundary-safe enable");
        else
            $fatal(1, "FAIL: errors=%0d", errors);
        $finish;
    end

    initial begin
        #100us;
        $fatal(1, "TIMEOUT: Camera_Capture boundary-control test");
    end
endmodule

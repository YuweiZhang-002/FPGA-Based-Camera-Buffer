`timescale 1ns / 1ps

// Regression for the failure observed in attempt18..20: the source clock can
// reach the FPGA before all DATA bits have settled.  The early synchronized
// sample can therefore contain the preceding byte, while DATA is stable by the
// phase-qualified PCLK event later in the high phase.
module tb_Camera_Capture_Data_Phase;
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
    integer early_stale_seen = 0;
    reg [7:0] expected [0:PACKET_BYTES-1];

    always #5 sys_clk = ~sys_clk;

    Camera_Capture #(
        .CAM_ID          (2'd0),
        .PACKET_BYTES    (PACKET_BYTES),
        .LINES_PER_FRAME (480),
        .INGRESS_CRC_ENABLE(1'b0), // DATA phase test uses no CRC vector
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
        if (!rst && dut.pclk_pulse && dut.line_active &&
            (dut.data_on_pclk_rise !== dut.data_sync))
            early_stale_seen = early_stale_seen + 1;

        if (!rst && byte_valid) begin
            if (received >= PACKET_BYTES) begin
                $error("unexpected extra byte %02x", byte_data);
                errors = errors + 1;
            end else if (byte_data !== expected[received]) begin
                $error("qualified DATA mismatch index=%0d got=%02x expected=%02x early=%02x",
                       received, byte_data, expected[received],
                       dut.data_on_pclk_rise);
                errors = errors + 1;
            end
            received = received + 1;
        end
    end

    // PCLK rises one ns before a sys_clk edge, while DATA changes six ns after
    // PCLK.  This deliberately makes the first synchronized DATA observation
    // stale.  DATA remains stable for the rest of the 50 ns byte cell, so the
    // phase-qualified observation must recover the intended byte.
    task automatic send_late_data_byte;
        input [7:0] value;
        begin
            #9 pclk = 1'b1;
            #6 camera_data = value;
            #24 pclk = 1'b0;
            #11;
        end
    endtask

    integer i;
    initial begin
        expected[0]  = 8'hA5;
        expected[1]  = 8'hA0;
        expected[2]  = 8'h5A;
        expected[3]  = 8'h50;
        expected[4]  = 8'h00;
        expected[5]  = 8'h00;
        expected[6]  = 8'h7F;
        expected[7]  = 8'h00;
        expected[8]  = 8'hFF;
        expected[9]  = 8'h00; // row_flags after a high-popcount row_idx byte
        expected[10] = 8'h50;
        expected[11] = 8'hFF;
        expected[12] = 8'hFE;
        expected[13] = 8'h00;
        expected[14] = 8'h00;
        expected[15] = 8'h00;

        repeat (8) @(posedge sys_clk);
        rst = 1'b0;
        repeat (10) @(posedge sys_clk);

        // Arm only in an HREF-low interval.
        href = 1'b1;
        for (i = 0; i < PACKET_BYTES; i = i + 1)
            send_late_data_byte(expected[i]);

        #1 href = 1'b0;
        wait (line_end);
        repeat (4) @(posedge sys_clk);

        if (received != PACKET_BYTES) begin
            $error("byte count mismatch received=%0d expected=%0d",
                   received, PACKET_BYTES);
            errors = errors + 1;
        end
        if (last_line_byte_count != PACKET_BYTES ||
            line_flags != 8'h00 || length_error_pulse) begin
            $error("line result count=%0d flags=%02x pulse=%0b",
                   last_line_byte_count, line_flags, length_error_pulse);
            errors = errors + 1;
        end
        if (early_stale_seen == 0) begin
            $error("stimulus did not expose an early stale DATA sample");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: qualified PCLK sample rejects preceding-byte contamination");
        else
            $fatal(1, "FAIL: errors=%0d", errors);
        $finish;
    end

    initial begin
        #100us;
        $fatal(1, "TIMEOUT: Camera_Capture DATA phase regression");
    end
endmodule

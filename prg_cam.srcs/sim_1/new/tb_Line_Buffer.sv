`timescale 1ns / 1ps

module tb_Line_Buffer;
    reg sys_clk = 1'b0;
    reg rst = 1'b1;

    reg [7:0] capture_data = 8'd0;
    reg       capture_valid = 1'b0;
    reg       capture_line_start = 1'b0;
    reg       capture_line_end = 1'b0;
    reg [1:0] capture_cam_id = 2'd2;
    reg [7:0] capture_flags = 8'd0;
    wire      request;
    reg       grant = 1'b0;
    wire [7:0] tx_data;
    wire       tx_valid;
    reg        tx_ready = 1'b1;
    wire       tx_packet_last;
    wire [1:0] tx_cam_id;
    wire [7:0] tx_flags;
    wire       overflow_pulse;
    wire [31:0] dropped_packet_count;
    wire [2:0] used_count;
    wire [2:0] committed_count;

    integer output_byte = 0;
    integer output_packet = 0;
    integer errors = 0;

    always #5 sys_clk = ~sys_clk;

    Line_Buffer dut (
        .sys_clk(sys_clk), .rst(rst),
        .capture_data(capture_data), .capture_valid(capture_valid),
        .capture_line_start(capture_line_start),
        .capture_line_end(capture_line_end),
        .capture_cam_id(capture_cam_id), .capture_flags(capture_flags),
        .request(request), .grant(grant),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx_packet_last(tx_packet_last), .tx_cam_id(tx_cam_id),
        .tx_flags(tx_flags), .overflow_pulse(overflow_pulse),
        .dropped_packet_count(dropped_packet_count),
        .used_count(used_count), .committed_count(committed_count)
    );

    task automatic send_packet;
        input [7:0] base;
        input [7:0] flags;
        integer i;
        begin
            for (i = 0; i < 128; i = i + 1) begin
                @(negedge sys_clk);
                capture_line_start = (i == 0);
                capture_valid      = 1'b1;
                capture_data       = base + i;
                capture_flags      = flags;
            end
            @(negedge sys_clk);
            capture_line_start = 1'b0;
            capture_valid      = 1'b0;
            capture_line_end   = 1'b1;
            capture_flags      = flags;
            @(negedge sys_clk);
            capture_line_end   = 1'b0;
        end
    endtask

    always @(posedge sys_clk) begin
        if (!rst && tx_valid && tx_ready) begin
            if (output_byte == 0) begin
                if (tx_cam_id !== 2'd2) begin
                    $display("ERROR Line_Buffer cam_id=%0d", tx_cam_id);
                    errors = errors + 1;
                end
                if ((output_packet == 4) && (tx_flags !== 8'h03)) begin
                    $display("ERROR sticky overflow flags=%02x expected=06",
                             tx_flags);
                    errors = errors + 1;
                end
            end

            if (tx_packet_last !== (output_byte == 127)) begin
                $display("ERROR Line_Buffer last packet=%0d byte=%0d",
                         output_packet, output_byte);
                errors = errors + 1;
            end

            if (output_byte == 127) begin
                output_byte   = 0;
                output_packet = output_packet + 1;
            end else begin
                output_byte = output_byte + 1;
            end
        end
    end

    initial begin
        repeat (4) @(posedge sys_clk);
        @(negedge sys_clk);
        rst = 1'b0;

        // Fill all four slots without granting TX.
        send_packet(8'h10, 8'h00);
        send_packet(8'h20, 8'h00);
        send_packet(8'h30, 8'h00);
        send_packet(8'h40, 8'h00);

        if ((used_count !== 4) || (committed_count !== 4) || !request) begin
            $display("ERROR Line_Buffer did not fill: used=%0d committed=%0d",
                     used_count, committed_count);
            errors = errors + 1;
        end

        // Fifth packet is dropped. Its overflow condition must not disappear.
        send_packet(8'h50, 8'h00);
        if (dropped_packet_count !== 1) begin
            $display("ERROR drop count=%0d expected=1", dropped_packet_count);
            errors = errors + 1;
        end

        grant = 1'b1;
        wait (output_packet == 1);

        // A slot is now free. This LAST_ROW packet must inherit bit2, producing
        // flags 0x02 | 0x01 = 0x03 when it eventually reaches TX.
        send_packet(8'h60, 8'h02);

        wait (output_packet == 5);
        repeat (5) @(posedge sys_clk);

        if ((used_count !== 0) || (committed_count !== 0) || request) begin
            $display("ERROR Line_Buffer did not drain: used=%0d committed=%0d",
                     used_count, committed_count);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: Line_Buffer counters, drop and sticky overflow");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: Line_Buffer simulation timeout");
        $finish;
    end
endmodule

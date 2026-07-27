`timescale 1ns / 1ps

module tb_Camera_Pipeline;
    localparam integer PACKET_BYTES = 128;
    localparam integer TEST_PACKETS = 4;

    reg sys_clk = 1'b0;
    reg rst = 1'b1;

    reg cam0_pclk = 1'b0;
    reg cam1_pclk = 1'b0;
    reg cam2_pclk = 1'b0;
    reg cam3_pclk = 1'b0;
    reg cam0_href = 1'b0;
    reg cam1_href = 1'b0;
    reg cam2_href = 1'b0;
    reg cam3_href = 1'b0;
    reg [7:0] cam0_data = 8'd0;
    reg [7:0] cam1_data = 8'd0;
    reg [7:0] cam2_data = 8'd0;
    reg [7:0] cam3_data = 8'd0;

    wire [7:0] packet_data;
    wire       packet_valid;
    reg        packet_ready = 1'b1;
    wire       packet_last;
    wire [3:0] arb_grant;
    wire [3:0] overflow_pulse;
    wire [31:0] drop0, drop1, drop2, drop3;
    wire [11:0] used_count;
    wire [11:0] committed_count;
    wire [15:0] fifo_level;
    wire        fifo_almost_full;

    reg [7:0] expected [0:TEST_PACKETS*PACKET_BYTES-1];
    integer output_index = 0;
    integer errors = 0;
    integer ready_cycle = 0;

    always #5  sys_clk = ~sys_clk; // 100 MHz FPGA clock
    always #40 cam0_pclk = ~cam0_pclk;
    always #40 cam1_pclk = ~cam1_pclk;
    always #40 cam2_pclk = ~cam2_pclk;
    always #40 cam3_pclk = ~cam3_pclk;

    Camera_Pipeline #(
        .LINES_PER_FRAME   (2),
        .PACKET_FIFO_DEPTH (256)
    ) dut (
        .sys_clk(sys_clk), .rst(rst),
        .cam0_pclk(cam0_pclk), .cam0_href(cam0_href), .cam0_data(cam0_data),
        .cam1_pclk(cam1_pclk), .cam1_href(cam1_href), .cam1_data(cam1_data),
        .cam2_pclk(cam2_pclk), .cam2_href(cam2_href), .cam2_data(cam2_data),
        .cam3_pclk(cam3_pclk), .cam3_href(cam3_href), .cam3_data(cam3_data),
        .packet_data(packet_data), .packet_valid(packet_valid),
        .packet_ready(packet_ready), .packet_last(packet_last),
        .arb_grant(arb_grant), .overflow_pulse(overflow_pulse),
        .dropped_packet_count_0(drop0), .dropped_packet_count_1(drop1),
        .dropped_packet_count_2(drop2), .dropped_packet_count_3(drop3),
        .buffer_used_count(used_count),
        .buffer_committed_count(committed_count),
        .packet_fifo_level(fifo_level),
        .packet_fifo_almost_full(fifo_almost_full)
    );

    function automatic [7:0] source_byte;
        input integer packet_no;
        input integer offset;
        begin
            // Distinct deterministic packets. RP2350A owns FIRST/LAST in the
            // incoming row_flags byte; FPGA only ORs capture errors.
            source_byte = (8'h31 + packet_no * 8'h27 + offset) & 8'hff;
            if (offset == 4)
                source_byte = 8'hA0 + packet_no;
            if (offset == 9)
                source_byte = (packet_no == 0) ? 8'h84 :
                              (packet_no == 1) ? 8'h44 :
                              (packet_no == 2) ? 8'h22 : 8'h24;
            if ((offset == 126) || (offset == 127))
                source_byte = 8'hEE;
        end
    endfunction

    function automatic [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] data_in;
        integer b;
        reg [15:0] c;
        begin
            c = crc_in ^ {data_in, 8'h00};
            for (b = 0; b < 8; b = b + 1)
                c = c[15] ? ({c[14:0], 1'b0} ^ 16'h1021)
                          :  {c[14:0], 1'b0};
            crc16_byte = c;
        end
    endfunction

    task automatic build_expected;
        input integer packet_no;
        input [1:0] cam_id;
        input [7:0] generated_flags;
        integer i;
        reg [7:0] value;
        reg [15:0] crc;
        begin
            crc = 16'hFFFF;
            for (i = 0; i < 126; i = i + 1) begin
                value = source_byte(packet_no, i);
                if (i == 4)
                    value = {6'd0, cam_id};
                if (i == 9)
                    value = value | generated_flags;
                expected[packet_no*PACKET_BYTES+i] = value;
                crc = crc16_byte(crc, value);
            end
            expected[packet_no*PACKET_BYTES+126] = crc[7:0];
            expected[packet_no*PACKET_BYTES+127] = crc[15:8];
        end
    endtask

    task automatic send_cam0_packet;
        input integer packet_no;
        integer i;
        begin
            for (i = 0; i < PACKET_BYTES; i = i + 1) begin
                @(negedge cam0_pclk);
                if (i == 0)
                    cam0_href = 1'b1;
                cam0_data = source_byte(packet_no, i);
            end
            @(negedge cam0_pclk);
            cam0_href = 1'b0;
            cam0_data = 8'd0;
        end
    endtask

    task automatic send_cam1_packet;
        input integer packet_no;
        integer i;
        begin
            for (i = 0; i < PACKET_BYTES; i = i + 1) begin
                @(negedge cam1_pclk);
                if (i == 0)
                    cam1_href = 1'b1;
                cam1_data = source_byte(packet_no, i);
            end
            @(negedge cam1_pclk);
            cam1_href = 1'b0;
            cam1_data = 8'd0;
        end
    endtask

    task automatic send_cam2_short_packet;
        input integer packet_no;
        integer i;
        begin
            // Only bytes 0..125 arrive. Line_Buffer pads the missing CRC tail,
            // Camera_Capture sets LENGTH_ERROR, and Byte_Replacer creates CRC.
            for (i = 0; i < 126; i = i + 1) begin
                @(negedge cam2_pclk);
                if (i == 0)
                    cam2_href = 1'b1;
                cam2_data = source_byte(packet_no, i);
            end
            @(negedge cam2_pclk);
            cam2_href = 1'b0;
            cam2_data = 8'd0;
        end
    endtask

    // Exercise output backpressure. Indexing and CRC must remain unchanged.
    always @(posedge sys_clk) begin
        if (rst) begin
            ready_cycle  <= 0;
            packet_ready <= 1'b1;
        end else begin
            ready_cycle  <= ready_cycle + 1;
            packet_ready <= ((ready_cycle % 7) != 3);
        end
    end

    always @(posedge sys_clk) begin
        if (!rst && packet_valid && packet_ready) begin
            if (packet_data !== expected[output_index]) begin
                $display("ERROR output byte %0d got=%02x expected=%02x",
                         output_index, packet_data, expected[output_index]);
                errors = errors + 1;
            end

            if (packet_last !== ((output_index % PACKET_BYTES) == 127)) begin
                $display("ERROR packet_last at output byte %0d value=%b",
                         output_index, packet_last);
                errors = errors + 1;
            end
            output_index = output_index + 1;
        end
    end

    initial begin
        // packet 0 = cam0 row0 (FIRST), packet 1 = cam1 row0 (FIRST),
        // packet 2 = cam0 row1 (LAST). Existing row_flags are OR-preserved.
        build_expected(0, 2'd0, 8'h00);
        build_expected(1, 2'd1, 8'h00);
        build_expected(2, 2'd0, 8'h00);
        build_expected(3, 2'd2, 8'h08); // preserve FIRST, OR LENGTH_ERROR

        repeat (8) @(posedge sys_clk);
        @(negedge sys_clk);
        rst = 1'b0;

        // Both first packets commit together. Round robin must choose cam0 then
        // cam1 without interleaving either 128-byte packet.
        fork
            send_cam0_packet(0);
            send_cam1_packet(1);
        join

        repeat (4) @(negedge cam0_pclk);
        send_cam0_packet(2);

        repeat (4) @(negedge cam2_pclk);
        send_cam2_short_packet(3);

        wait (output_index == TEST_PACKETS * PACKET_BYTES);
        repeat (10) @(posedge sys_clk);

        if ({drop3, drop2, drop1, drop0} !== 128'd0) begin
            $display("ERROR unexpected dropped packet count");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: 4-camera LB arbitration, header merge and CRC-16");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #300000;
        $display("FAIL: simulation timeout, output_index=%0d", output_index);
        $finish;
    end
endmodule

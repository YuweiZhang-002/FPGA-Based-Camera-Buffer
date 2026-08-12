`timescale 1ns / 1ps

module tb_Camera_Pipeline;
    localparam integer PACKET_BYTES = 128;
    localparam integer TEST_PACKETS = 6;

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

    reg [7:0] source_packet [0:TEST_PACKETS*PACKET_BYTES-1];
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
        .PACKET_FIFO_DEPTH (256),
        .ENABLE_CAM1       (1)
    ) dut (
        .sys_clk(sys_clk), .rst(rst), .capture_enable(1'b1),
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
            // Distinct deterministic packets. RP2350A owns row_flags at
            // offset 9; FPGA status is written separately at offset 13.
            source_byte = 8'h00;
            case (offset)
                0: source_byte = 8'hA5;
                1: source_byte = 8'hA0;
                2: source_byte = 8'h5A;
                3: source_byte = 8'h50;
                4: source_byte = 8'hF0; // FPGA replaces with cam_id.
                5: source_byte = 8'h12;
                6: source_byte = packet_no[7:0];
                7: source_byte = 8'h00;
                8: source_byte = packet_no[7:0];
                9: source_byte = (packet_no == 2) ? 8'h04 :
                                 (packet_no == 5) ? 8'h02 : 8'h00;
                10: source_byte = 8'd80;
                11: source_byte = 8'h00;
                12: source_byte = packet_no[7:0];
                13: source_byte = 8'h00;
                default: begin
                    if ((offset >= 24) && (offset <= 103))
                        source_byte = (8'h31 + packet_no * 8'h27 +
                                       offset) & 8'hff;
                    else if ((offset >= 114) && (offset <= 125))
                        source_byte = offset[0] ? 8'h5A : 8'hA5;
                end
            endcase
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

    task automatic build_packet;
        input integer packet_no;
        input [1:0] cam_id;
        input [7:0] generated_flags;
        integer i;
        reg [7:0] value;
        reg [15:0] ingress_crc;
        reg [15:0] egress_crc;
        begin
            ingress_crc = 16'hFFFF;
            egress_crc = 16'hFFFF;
            for (i = 0; i < 126; i = i + 1) begin
                value = source_byte(packet_no, i);
                source_packet[packet_no*PACKET_BYTES+i] = value;
                ingress_crc = crc16_byte(ingress_crc, value);
                if (i == 4)
                    value = {6'd0, cam_id};
                if (i == 13)
                    value = generated_flags;
                expected[packet_no*PACKET_BYTES+i] = value;
                egress_crc = crc16_byte(egress_crc, value);
            end
            source_packet[packet_no*PACKET_BYTES+126] = ingress_crc[15:8];
            source_packet[packet_no*PACKET_BYTES+127] = ingress_crc[7:0];
            expected[packet_no*PACKET_BYTES+126] = egress_crc[15:8];
            expected[packet_no*PACKET_BYTES+127] = egress_crc[7:0];
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
                cam0_data = source_packet[packet_no*PACKET_BYTES+i];
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
                cam1_data = source_packet[packet_no*PACKET_BYTES+i];
            end
            @(negedge cam1_pclk);
            cam1_href = 1'b0;
            cam1_data = 8'd0;
        end
    endtask

    task automatic send_cam2_packet;
        input integer packet_no;
        input integer packet_length;
        integer i;
        begin
            for (i = 0; i < packet_length; i = i + 1) begin
                @(negedge cam2_pclk);
                if (i == 0)
                    cam2_href = 1'b1;
                cam2_data = source_packet[packet_no*PACKET_BYTES+i];
            end
            @(negedge cam2_pclk);
            cam2_href = 1'b0;
            cam2_data = 8'd0;
        end
    endtask

    task automatic send_cam3_long_packet;
        input integer packet_no;
        integer i;
        begin
            for (i = 0; i < 129; i = i + 1) begin
                @(negedge cam3_pclk);
                if (i == 0)
                    cam3_href = 1'b1;
                cam3_data = (i < PACKET_BYTES)
                            ? source_packet[packet_no*PACKET_BYTES+i]
                            : 8'hDE;
            end
            @(negedge cam3_pclk);
            cam3_href = 1'b0;
            cam3_data = 8'd0;
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
        // offset 9 is sender-owned and byte exact.  Packets 3 and 4 exercise
        // the 127-byte pad and 129-byte truncate paths; packet 5 proves that
        // neither malformed row contaminates the next normal row.
        build_packet(0, 2'd0, 8'h00);
        build_packet(1, 2'd1, 8'h00);
        build_packet(2, 2'd0, 8'h00);
        build_packet(3, 2'd2, 8'h08);
        build_packet(4, 2'd3, 8'h08);
        build_packet(5, 2'd2, 8'h00);

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
        send_cam2_packet(3, 127);

        repeat (4) @(negedge cam3_pclk);
        send_cam3_long_packet(4);

        repeat (4) @(negedge cam2_pclk);
        send_cam2_packet(5, 128);

        wait (output_index == TEST_PACKETS * PACKET_BYTES);
        repeat (40) @(posedge sys_clk);

        if (output_index != TEST_PACKETS * PACKET_BYTES) begin
            $display("ERROR normalized packet count output_index=%0d",
                     output_index);
            errors = errors + 1;
        end

        if ({drop3, drop2, drop1, drop0} !== 128'd0) begin
            $display("ERROR unexpected dropped packet count");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: 4-camera arbitration, 127/129 normalization, status and CRC-16");
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

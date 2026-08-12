`timescale 1ns / 1ps

// Integration regression for the active real-time source boundary:
// GPIO-equivalent camera0 -> Camera_Pipeline (Line Buffers/arbiter/replacer/FIFO)
// -> Ethernet_Frame_Adapter.
module tb_Camera_Pipeline_Ethernet_Source;
    localparam integer PACKET_BYTES = 128;
    localparam integer TEST_PACKETS = 3;

    logic sys_clk = 1'b0;
    logic rst = 1'b1;
    logic cam_pclk = 1'b0;
    logic cam_href = 1'b0;
    logic [7:0] cam_data = 8'd0;

    wire [7:0] camera_packet_data;
    wire       camera_packet_valid;
    wire       camera_packet_ready;
    wire       camera_packet_last;
    wire [3:0] arb_grant;
    wire [3:0] overflow_pulse;
    wire [31:0] drop0, drop1, drop2, drop3;
    wire [11:0] buffer_used_count;
    wire [11:0] buffer_committed_count;
    wire [15:0] packet_fifo_level;
    wire        packet_fifo_almost_full;

    wire [7:0] frame_data;
    wire       frame_valid;
    logic      frame_ready = 1'b0;
    wire       frame_last;

    logic [7:0] expected_payload [0:TEST_PACKETS*PACKET_BYTES-1];
    logic [7:0] source_packet [0:TEST_PACKETS*PACKET_BYTES-1];
    integer frame_count = 0;
    integer frame_index = 0;
    integer frame_handshake_count = 0;
    integer camera_packet_handshake_count = 0;
    integer errors = 0;
    integer ready_cycle = 0;
    bit last_stall_done = 1'b0;

    logic stalled_d = 1'b0;
    logic [7:0] stalled_data_d = 8'd0;
    logic stalled_last_d = 1'b0;

    always #5  sys_clk = ~sys_clk;  // 100 MHz logic clock
    always #40 cam_pclk = ~cam_pclk; // 12.5 MHz, safely observable by Alarmer

    Camera_Pipeline #(
        .LINES_PER_FRAME   (TEST_PACKETS),
        .PACKET_FIFO_DEPTH (512)
    ) u_camera_pipeline (
        .sys_clk                  (sys_clk),
        .rst                      (rst),
        .capture_enable           (1'b1),
        .cam0_pclk                (cam_pclk),
        .cam0_href                (cam_href),
        .cam0_data                (cam_data),
        .cam1_pclk                (1'b0),
        .cam1_href                (1'b0),
        .cam1_data                (8'd0),
        .cam2_pclk                (1'b0),
        .cam2_href                (1'b0),
        .cam2_data                (8'd0),
        .cam3_pclk                (1'b0),
        .cam3_href                (1'b0),
        .cam3_data                (8'd0),
        .packet_data              (camera_packet_data),
        .packet_valid             (camera_packet_valid),
        .packet_ready             (camera_packet_ready),
        .packet_last              (camera_packet_last),
        .arb_grant                (arb_grant),
        .overflow_pulse           (overflow_pulse),
        .dropped_packet_count_0   (drop0),
        .dropped_packet_count_1   (drop1),
        .dropped_packet_count_2   (drop2),
        .dropped_packet_count_3   (drop3),
        .buffer_used_count        (buffer_used_count),
        .buffer_committed_count   (buffer_committed_count),
        .packet_fifo_level        (packet_fifo_level),
        .packet_fifo_almost_full  (packet_fifo_almost_full)
    );

    Ethernet_Frame_Adapter u_frame_adapter (
        .clk          (sys_clk),
        .rst          (rst),
        .packet_data  (camera_packet_data),
        .packet_valid (camera_packet_valid),
        .packet_ready (camera_packet_ready),
        .packet_last  (camera_packet_last),
        .frame_data   (frame_data),
        .frame_valid  (frame_valid),
        .frame_ready  (frame_ready),
        .frame_last   (frame_last)
    );

    function automatic [7:0] source_byte;
        input integer packet_no;
        input integer offset;
        begin
            source_byte = 8'h00;
            case (offset)
                0: source_byte = 8'hA5;
                1: source_byte = 8'hA0;
                2: source_byte = 8'h5A;
                3: source_byte = 8'h50;
                4: source_byte = 8'hF0; // replaced with camera id 0
                5: source_byte = 8'h34;
                6: source_byte = packet_no[7:0];
                7: source_byte = 8'h00;
                8: source_byte = packet_no[7:0];
                9: source_byte = (packet_no == 1) ? 8'h04 :
                                 (packet_no == TEST_PACKETS-1) ? 8'h02 :
                                 8'h00;
                10: source_byte = 8'd80;
                11: source_byte = 8'h00;
                12: source_byte = packet_no[7:0];
                13: source_byte = 8'h00;
                default: begin
                    if ((offset >= 24) && (offset <= 103))
                        source_byte = (8'h23 + packet_no * 8'h35 +
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

    task automatic build_expected;
        input integer packet_no;
        integer i;
        reg [7:0] value;
        reg [7:0] generated_flags;
        reg [15:0] ingress_crc;
        reg [15:0] egress_crc;
        begin
            generated_flags = 8'h00;
            ingress_crc = 16'hFFFF;
            egress_crc = 16'hFFFF;
            for (i = 0; i < 126; i = i + 1) begin
                value = source_byte(packet_no, i);
                source_packet[packet_no*PACKET_BYTES+i] = value;
                ingress_crc = crc16_byte(ingress_crc, value);
                if (i == 4)
                    value = 8'h00;
                if (i == 13)
                    value = generated_flags;
                expected_payload[packet_no*PACKET_BYTES+i] = value;
                egress_crc = crc16_byte(egress_crc, value);
            end
            source_packet[packet_no*PACKET_BYTES+126] = ingress_crc[15:8];
            source_packet[packet_no*PACKET_BYTES+127] = ingress_crc[7:0];
            expected_payload[packet_no*PACKET_BYTES+126] = egress_crc[15:8];
            expected_payload[packet_no*PACKET_BYTES+127] = egress_crc[7:0];
        end
    endtask

    task automatic send_camera_packet;
        input integer packet_no;
        integer i;
        begin
            for (i = 0; i < PACKET_BYTES; i = i + 1) begin
                @(negedge cam_pclk);
                if (i == 0)
                    cam_href = 1'b1;
                cam_data = source_packet[packet_no*PACKET_BYTES+i];
            end
            @(negedge cam_pclk);
            cam_href = 1'b0;
            cam_data = 8'd0;
            repeat (2) @(negedge cam_pclk);
        end
    endtask

    function automatic [7:0] expected_frame_byte;
        input integer packet_no;
        input integer index;
        begin
            if (index < 6)
                expected_frame_byte = 8'hFF;
            else if (index == 6)
                expected_frame_byte = 8'h02;
            else if ((index >= 7) && (index <= 10))
                expected_frame_byte = 8'h00;
            else if (index == 11)
                expected_frame_byte = 8'h02;
            else if (index == 12)
                expected_frame_byte = 8'h88;
            else if (index == 13)
                expected_frame_byte = 8'hB5;
            else
                expected_frame_byte =
                    expected_payload[packet_no*PACKET_BYTES+index-14];
        end
    endfunction

    // Periodic backpressure plus an explicit three-cycle stall on one TLAST.
    initial begin
        wait (!rst);
        forever begin
            @(negedge sys_clk);
            if (frame_valid && frame_last && !last_stall_done) begin
                frame_ready = 1'b0;
                repeat (3) @(negedge sys_clk);
                frame_ready = 1'b1;
                last_stall_done = 1'b1;
            end else begin
                frame_ready = ((ready_cycle % 9) != 4) &&
                              ((ready_cycle % 9) != 5);
                ready_cycle = ready_cycle + 1;
            end
        end
    end

    // Scoreboard, TLAST location and valid/data/last stall stability.
    always @(posedge sys_clk) begin
        if (rst) begin
            frame_count <= 0;
            frame_index <= 0;
            frame_handshake_count <= 0;
            camera_packet_handshake_count <= 0;
            stalled_d <= 1'b0;
        end else begin
            if (stalled_d) begin
                if (!frame_valid || (frame_data !== stalled_data_d) ||
                    (frame_last !== stalled_last_d)) begin
                    $error("frame changed while stalled at time %0t", $time);
                    errors = errors + 1;
                end
            end

            stalled_d <= frame_valid && !frame_ready;
            if (frame_valid && !frame_ready) begin
                stalled_data_d <= frame_data;
                stalled_last_d <= frame_last;
            end

            if (camera_packet_valid && camera_packet_ready)
                camera_packet_handshake_count <=
                    camera_packet_handshake_count + 1;

            if (frame_valid && frame_ready) begin
                frame_handshake_count <= frame_handshake_count + 1;
                if (frame_data !== expected_frame_byte(frame_count,
                                                       frame_index)) begin
                    $error("frame byte mismatch frame=%0d index=%0d got=%02x exp=%02x",
                           frame_count, frame_index, frame_data,
                           expected_frame_byte(frame_count, frame_index));
                    errors = errors + 1;
                end
                if (frame_last !== (frame_index == 141)) begin
                    $error("TLAST mismatch frame=%0d index=%0d last=%0b",
                           frame_count, frame_index, frame_last);
                    errors = errors + 1;
                end

                if (frame_index == 141) begin
                    frame_index <= 0;
                    frame_count <= frame_count + 1;
                end else begin
                    frame_index <= frame_index + 1;
                end
            end
        end
    end

    initial begin : stimulus
        integer p;
        for (p = 0; p < TEST_PACKETS; p = p + 1)
            build_expected(p);

        repeat (8) @(posedge sys_clk);
        rst = 1'b0;
        repeat (8) @(posedge sys_clk);

        for (p = 0; p < TEST_PACKETS; p = p + 1)
            send_camera_packet(p);

        wait (frame_count == TEST_PACKETS);
        repeat (30) @(posedge sys_clk);

        if (frame_handshake_count != TEST_PACKETS * 142) begin
            $error("frame handshake count=%0d expected=%0d",
                   frame_handshake_count, TEST_PACKETS * 142);
            errors = errors + 1;
        end
        if (camera_packet_handshake_count != TEST_PACKETS * 128) begin
            $error("camera packet handshake count=%0d expected=%0d",
                   camera_packet_handshake_count, TEST_PACKETS * 128);
            errors = errors + 1;
        end
        if ((packet_fifo_level != 0) || (buffer_used_count != 0) ||
            (buffer_committed_count != 0)) begin
            $error("unexplained backlog fifo=%0d used=%03x committed=%03x",
                   packet_fifo_level, buffer_used_count,
                   buffer_committed_count);
            errors = errors + 1;
        end
        if ((drop0 != 0) || (drop1 != 0) || (drop2 != 0) ||
            (drop3 != 0) || (overflow_pulse != 0)) begin
            $error("unexpected drop/overflow drop0=%0d drop1=%0d drop2=%0d drop3=%0d ovf=%x",
                   drop0, drop1, drop2, drop3, overflow_pulse);
            errors = errors + 1;
        end
        if (!last_stall_done) begin
            $error("explicit last-byte stall was not exercised");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS: Camera_Pipeline -> Byte_FIFO -> Frame Adapter");
            $display("PASS: frames=%0d packet_hs=%0d frame_hs=%0d stalls_and_last_stall=covered",
                     frame_count, camera_packet_handshake_count,
                     frame_handshake_count);
        end else begin
            $fatal(1, "FAIL: errors=%0d", errors);
        end
        $finish;
    end

    initial begin : timeout
        #500us;
        $fatal(1, "TIMEOUT: Camera Pipeline Ethernet integration");
    end

endmodule

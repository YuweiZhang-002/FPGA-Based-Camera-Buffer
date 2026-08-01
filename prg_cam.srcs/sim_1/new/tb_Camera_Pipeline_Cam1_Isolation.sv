`timescale 1ns / 1ps

module tb_Camera_Pipeline_Cam1_Isolation;
    reg sys_clk = 1'b0;
    reg rst = 1'b1;
    reg cam1_pclk = 1'b0;
    reg cam1_href = 1'b0;
    reg [7:0] cam1_data = 8'd0;

    wire [7:0] packet_data;
    wire packet_valid;
    wire packet_last;
    wire [3:0] arb_grant;
    wire [3:0] overflow_pulse;
    wire [31:0] drop0, drop1, drop2, drop3;
    wire [11:0] used_count;
    wire [11:0] committed_count;
    wire [15:0] fifo_level;
    wire fifo_almost_full;
    integer errors = 0;

    always #5 sys_clk = ~sys_clk;
    always #40 cam1_pclk = ~cam1_pclk;

    Camera_Pipeline #(
        .LINES_PER_FRAME(480),
        .PACKET_FIFO_DEPTH(256),
        .ENABLE_CAM1(0)
    ) dut (
        .sys_clk(sys_clk), .rst(rst), .capture_enable(1'b1),
        .cam0_pclk(1'b0), .cam0_href(1'b0), .cam0_data(8'd0),
        .cam1_pclk(cam1_pclk), .cam1_href(cam1_href),
        .cam1_data(cam1_data),
        .cam2_pclk(1'b0), .cam2_href(1'b0), .cam2_data(8'd0),
        .cam3_pclk(1'b0), .cam3_href(1'b0), .cam3_data(8'd0),
        .packet_data(packet_data), .packet_valid(packet_valid),
        .packet_ready(1'b1), .packet_last(packet_last),
        .arb_grant(arb_grant), .overflow_pulse(overflow_pulse),
        .dropped_packet_count_0(drop0), .dropped_packet_count_1(drop1),
        .dropped_packet_count_2(drop2), .dropped_packet_count_3(drop3),
        .buffer_used_count(used_count),
        .buffer_committed_count(committed_count),
        .packet_fifo_level(fifo_level),
        .packet_fifo_almost_full(fifo_almost_full),
        .debug_cam0_current_byte_count(),
        .debug_cam0_last_line_byte_count(),
        .debug_cam0_line_flags(), .debug_cam0_line_end(),
        .debug_cam0_length_error_pulse(), .debug_cam0_byte_valid()
    );

    always @(posedge sys_clk) begin
        if (!rst && (packet_valid || arb_grant[1] || overflow_pulse[1])) begin
            $error("disabled cam1 affected active pipeline");
            errors = errors + 1;
        end
    end

    initial begin : stimulus
        integer index;
        repeat (8) @(posedge sys_clk);
        rst = 1'b0;
        repeat (8) @(posedge sys_clk);

        // Present a complete, otherwise valid-looking cam1 HREF/PCLK packet.
        // ENABLE_CAM1=0 must prevent line_start and all downstream activity.
        for (index = 0; index < 128; index = index + 1) begin
            @(negedge cam1_pclk);
            if (index == 0)
                cam1_href = 1'b1;
            cam1_data = index[7:0];
        end
        @(negedge cam1_pclk);
        cam1_href = 1'b0;

        repeat (100) @(posedge sys_clk);
        if (used_count[5:3] != 3'd0 || committed_count[5:3] != 3'd0 ||
            drop1 != 32'd0 || fifo_level != 16'd0) begin
            $error("disabled cam1 changed buffer/FIFO accounting");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: ENABLE_CAM1=0 isolates routed cam1 input activity");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule

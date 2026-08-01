`timescale 1ns / 1ps

module tb_Byte_Replacer_Status_Separation;
    localparam integer PACKET_BYTES = 128;

    reg        sys_clk = 1'b0;
    reg        rst = 1'b1;
    reg        in_valid = 1'b0;
    wire       in_ready;
    wire [7:0] in_data;
    wire       in_packet_last;
    reg        out_ready = 1'b0;
    wire [7:0] out_data;
    wire       out_valid;
    wire       out_packet_last;

    integer send_index = 0;
    integer cycle_count = 0;
    integer errors = 0;
    reg [15:0] expected_crc;
    reg        held_valid = 1'b0;
    reg [7:0]  held_data;
    reg        held_last;

    always #5 sys_clk = ~sys_clk;

    function automatic [7:0] source_byte;
        input integer index;
        begin
            source_byte = (8'h31 + index) & 8'hff;
            if (index == 4)
                source_byte = 8'hE3;
            if (index == 9)
                source_byte = 8'hA6;
            if (index == 13)
                source_byte = 8'h00;
        end
    endfunction

    function automatic [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] data_in;
        integer bit_index;
        reg [15:0] crc_work;
        begin
            crc_work = crc_in ^ {data_in, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                crc_work = crc_work[15]
                    ? ({crc_work[14:0], 1'b0} ^ 16'h1021)
                    :  {crc_work[14:0], 1'b0};
            crc16_byte = crc_work;
        end
    endfunction

    assign in_data = source_byte(send_index);
    assign in_packet_last = (send_index == PACKET_BYTES-1);

    Byte_Replacer dut (
        .sys_clk         (sys_clk),
        .rst             (rst),
        .in_data         (in_data),
        .in_valid        (in_valid),
        .in_ready        (in_ready),
        .in_packet_last  (in_packet_last),
        .in_cam_id       (2'd2),
        .in_row_flags    (8'h09),
        .out_data        (out_data),
        .out_valid       (out_valid),
        .out_ready       (out_ready),
        .out_packet_last (out_packet_last)
    );

    always @(posedge sys_clk) begin
        if (rst) begin
            send_index  <= 0;
            cycle_count <= 0;
            in_valid    <= 1'b0;
            out_ready   <= 1'b0;
            held_valid  <= 1'b0;
        end else begin
            in_valid    <= (send_index < PACKET_BYTES);
            cycle_count <= cycle_count + 1;
            out_ready   <= ((cycle_count % 7) != 3);

            if (held_valid &&
                ({out_valid, out_data, out_packet_last} !==
                 {1'b1, held_data, held_last})) begin
                $error("stall stability failure index=%0d", send_index);
                errors = errors + 1;
            end
            held_valid <= out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                held_data <= out_data;
                held_last <= out_packet_last;
            end

            if (out_valid && out_ready) begin
                if (send_index == 4 && out_data !== 8'h02) begin
                    $error("cam_id patch failed: %02x", out_data);
                    errors = errors + 1;
                end
                if (send_index == 9 && out_data !== 8'hA6) begin
                    $error("MCU row_flags changed: %02x", out_data);
                    errors = errors + 1;
                end
                if (send_index == 13 && out_data !== 8'h09) begin
                    $error("FPGA status not written to reserved[0]: %02x", out_data);
                    errors = errors + 1;
                end
                if (send_index == 126 && out_data !== expected_crc[7:0]) begin
                    $error("CRC low mismatch: %02x", out_data);
                    errors = errors + 1;
                end
                if (send_index == 127 && out_data !== expected_crc[15:8]) begin
                    $error("CRC high mismatch: %02x", out_data);
                    errors = errors + 1;
                end
                if (out_packet_last !== (send_index == 127)) begin
                    $error("packet_last mismatch index=%0d", send_index);
                    errors = errors + 1;
                end

                if (send_index == PACKET_BYTES-1) begin
                    if (errors == 0)
                        $display("PASS: offset9 transparent, offset13 FPGA status, CRC and stall");
                    else
                        $display("FAIL: %0d errors", errors);
                    $finish;
                end
                send_index <= send_index + 1;
            end
        end
    end

    initial begin : build_crc
        integer index;
        reg [7:0] value;
        expected_crc = 16'hffff;
        for (index = 0; index < 126; index = index + 1) begin
            value = source_byte(index);
            if (index == 4)
                value = 8'h02;
            if (index == 13)
                value = 8'h09;
            expected_crc = crc16_byte(expected_crc, value);
        end

        repeat (5) @(posedge sys_clk);
        rst = 1'b0;
    end

    initial begin
        #100000;
        $display("FAIL: timeout index=%0d", send_index);
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_Byte_Replacer_Status_Separation;
    localparam integer PACKET_BYTES = 128;
    localparam integer PACKETS = 4;

    reg        sys_clk = 1'b0;
    reg        rst = 1'b1;
    reg [7:0]  in_data = 8'd0;
    reg        in_valid = 1'b0;
    reg        in_packet_last = 1'b0;
    reg [1:0]  in_cam_id = 2'd0;
    reg [7:0]  in_fpga_status = 8'd0;
    wire       in_ready_crc;
    wire       in_ready_placeholder;

    reg        out_ready = 1'b0;
    wire [7:0] out_data_crc;
    wire       out_valid_crc;
    wire       out_last_crc;
    wire [7:0] out_data_placeholder;
    wire       out_valid_placeholder;
    wire       out_last_placeholder;

    reg [7:0] source_packet [0:PACKETS*PACKET_BYTES-1];
    reg [7:0] expected_crc [0:PACKETS*PACKET_BYTES-1];
    reg [7:0] expected_placeholder [0:PACKETS*PACKET_BYTES-1];
    reg [1:0] packet_cam_id [0:PACKETS-1];
    reg [7:0] packet_status [0:PACKETS-1];

    integer output_count_crc = 0;
    integer output_count_placeholder = 0;
    integer errors = 0;
    integer stall_remaining = 0;
    reg [127:0] stalled_offset = 128'd0;
    reg saw_input_backpressure = 1'b0;

    reg held_crc = 1'b0;
    reg [7:0] held_data_crc;
    reg held_last_crc;
    reg held_placeholder = 1'b0;
    reg [7:0] held_data_placeholder;
    reg held_last_placeholder;

    always #5 sys_clk = ~sys_clk;

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

    function automatic [7:0] source_byte;
        input integer packet_no;
        input integer offset;
        begin
            source_byte = (8'h31 + packet_no * 8'h29 + offset) & 8'hFF;
            if (offset == 4)
                source_byte = 8'hE0 + packet_no;
            if (offset == 9)
                source_byte = (packet_no == 0) ? 8'h04 :
                              (packet_no == 1) ? 8'h02 : 8'h00;
            if (offset == 13)
                source_byte = 8'hC0 + packet_no;
            if ((offset >= 14) && (offset <= 23))
                source_byte = 8'h00;
            if ((offset >= 104) && (offset <= 113))
                source_byte = 8'h00;
            if ((offset >= 114) && (offset <= 125))
                source_byte = offset[0] ? 8'h5A : 8'hA5;
        end
    endfunction

    function automatic stall_target;
        input integer offset;
        begin
            stall_target = (offset == 4) || (offset == 9) ||
                           (offset == 13) || (offset == 125) ||
                           (offset == 126) || (offset == 127);
        end
    endfunction

    Byte_Replacer #(.CRC_ENABLE(1'b1)) dut_crc (
        .sys_clk(sys_clk), .rst(rst),
        .in_data(in_data), .in_valid(in_valid), .in_ready(in_ready_crc),
        .in_packet_last(in_packet_last), .in_cam_id(in_cam_id),
        .in_fpga_status(in_fpga_status),
        .out_data(out_data_crc), .out_valid(out_valid_crc),
        .out_ready(out_ready), .out_packet_last(out_last_crc)
    );

    Byte_Replacer #(.CRC_ENABLE(1'b0)) dut_placeholder (
        .sys_clk(sys_clk), .rst(rst),
        .in_data(in_data), .in_valid(in_valid),
        .in_ready(in_ready_placeholder),
        .in_packet_last(in_packet_last), .in_cam_id(in_cam_id),
        .in_fpga_status(in_fpga_status),
        .out_data(out_data_placeholder),
        .out_valid(out_valid_placeholder), .out_ready(out_ready),
        .out_packet_last(out_last_placeholder)
    );

    task automatic send_packet;
        input integer packet_no;
        integer index;
        begin
            in_cam_id = packet_cam_id[packet_no];
            in_fpga_status = packet_status[packet_no];
            for (index = 0; index < PACKET_BYTES; index = index + 1) begin
                @(negedge sys_clk);
                in_data = source_packet[packet_no*PACKET_BYTES+index];
                in_valid = 1'b1;
                in_packet_last = (index == PACKET_BYTES - 1);
                while (!(in_ready_crc && in_ready_placeholder))
                    @(negedge sys_clk);
            end
        end
    endtask

    // Inject two-cycle stalls exactly at all protocol-sensitive offsets.
    always @(negedge sys_clk) begin
        if (rst) begin
            out_ready = 1'b0;
            stall_remaining = 0;
            stalled_offset = 128'd0;
        end else if (stall_remaining != 0) begin
            out_ready = 1'b0;
            stall_remaining = stall_remaining - 1;
        end else if (out_valid_crc &&
                     stall_target(output_count_crc % PACKET_BYTES) &&
                     !stalled_offset[output_count_crc % PACKET_BYTES]) begin
            out_ready = 1'b0;
            stall_remaining = 1;
            stalled_offset[output_count_crc % PACKET_BYTES] = 1'b1;
        end else begin
            out_ready = 1'b1;
        end
    end

    always @(posedge sys_clk) begin
        if (!rst && in_valid && !(in_ready_crc && in_ready_placeholder))
            saw_input_backpressure <= 1'b1;

        if (held_crc &&
            ({out_valid_crc, out_data_crc, out_last_crc} !==
             {1'b1, held_data_crc, held_last_crc})) begin
            $display("ERROR CRC-mode output changed under backpressure");
            errors = errors + 1;
        end
        held_crc <= out_valid_crc && !out_ready;
        if (out_valid_crc && !out_ready) begin
            held_data_crc <= out_data_crc;
            held_last_crc <= out_last_crc;
        end

        if (held_placeholder &&
            ({out_valid_placeholder, out_data_placeholder,
              out_last_placeholder} !==
             {1'b1, held_data_placeholder, held_last_placeholder})) begin
            $display("ERROR placeholder output changed under backpressure");
            errors = errors + 1;
        end
        held_placeholder <= out_valid_placeholder && !out_ready;
        if (out_valid_placeholder && !out_ready) begin
            held_data_placeholder <= out_data_placeholder;
            held_last_placeholder <= out_last_placeholder;
        end

        if (!rst && out_valid_crc && out_ready) begin
            if (out_data_crc !== expected_crc[output_count_crc]) begin
                $display("ERROR CRC output[%0d]=%02x expected=%02x",
                         output_count_crc, out_data_crc,
                         expected_crc[output_count_crc]);
                errors = errors + 1;
            end
            if (out_last_crc !==
                ((output_count_crc % PACKET_BYTES) == 127)) begin
                $display("ERROR CRC packet_last at %0d", output_count_crc);
                errors = errors + 1;
            end
            output_count_crc = output_count_crc + 1;
        end

        if (!rst && out_valid_placeholder && out_ready) begin
            if (out_data_placeholder !==
                expected_placeholder[output_count_placeholder]) begin
                $display("ERROR placeholder output[%0d]=%02x expected=%02x",
                         output_count_placeholder, out_data_placeholder,
                         expected_placeholder[output_count_placeholder]);
                errors = errors + 1;
            end
            if (out_last_placeholder !==
                ((output_count_placeholder % PACKET_BYTES) == 127)) begin
                $display("ERROR placeholder packet_last at %0d",
                         output_count_placeholder);
                errors = errors + 1;
            end
            output_count_placeholder = output_count_placeholder + 1;
        end
    end

    initial begin : build_packets
        integer packet_no;
        integer index;
        reg [15:0] egress_crc;
        reg [7:0] value;

        packet_cam_id[0] = 2'd2;
        packet_cam_id[1] = 2'd1;
        packet_cam_id[2] = 2'd3;
        packet_cam_id[3] = 2'd0;
        packet_status[0] = 8'h04;
        packet_status[1] = 8'h04;
        packet_status[2] = 8'h08;
        packet_status[3] = 8'h00;

        for (packet_no = 0; packet_no < PACKETS;
             packet_no = packet_no + 1) begin
            for (index = 0; index < 126; index = index + 1) begin
                value = source_byte(packet_no, index);
                source_packet[packet_no*PACKET_BYTES+index] = value;
            end
            // Current MCU contract: the ingress tail is a placeholder. The
            // enabled DUT must accept it without adding status 0x10, then
            // replace it with the CRC of the patched outgoing packet.
            source_packet[packet_no*PACKET_BYTES+126] = 8'hFF;
            source_packet[packet_no*PACKET_BYTES+127] = 8'hFF;

            egress_crc = 16'hFFFF;
            for (index = 0; index < 126; index = index + 1) begin
                value = source_packet[packet_no*PACKET_BYTES+index];
                if (index == 4)
                    value = {6'd0, packet_cam_id[packet_no]};
                if (index == 13)
                    value = packet_status[packet_no];
                expected_crc[packet_no*PACKET_BYTES+index] = value;
                egress_crc = crc16_byte(egress_crc, value);

                if (index == 13)
                    value = packet_status[packet_no];
                expected_placeholder[packet_no*PACKET_BYTES+index] = value;
            end
            expected_crc[packet_no*PACKET_BYTES+126] = egress_crc[15:8];
            expected_crc[packet_no*PACKET_BYTES+127] = egress_crc[7:0];
            expected_placeholder[packet_no*PACKET_BYTES+126] = 8'hFF;
            expected_placeholder[packet_no*PACKET_BYTES+127] = 8'hFF;
        end

        repeat (5) @(posedge sys_clk);
        @(negedge sys_clk);
        rst = 1'b0;

        for (packet_no = 0; packet_no < PACKETS;
             packet_no = packet_no + 1)
            send_packet(packet_no);

        @(negedge sys_clk);
        in_valid = 1'b0;
        in_packet_last = 1'b0;

        wait ((output_count_crc == PACKETS*PACKET_BYTES) &&
              (output_count_placeholder == PACKETS*PACKET_BYTES));
        repeat (5) @(posedge sys_clk);

        if (!saw_input_backpressure) begin
            $display("ERROR two full banks never deasserted in_ready");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: dual-bank status, CRC modes, offsets and stalls");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #300000;
        $display("FAIL: timeout crc=%0d placeholder=%0d",
                 output_count_crc, output_count_placeholder);
        $finish;
    end
endmodule

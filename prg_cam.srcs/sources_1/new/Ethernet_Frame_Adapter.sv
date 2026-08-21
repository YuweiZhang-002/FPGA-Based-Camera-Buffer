`timescale 1ns / 1ps
`default_nettype none

// Prepends a 14-byte Ethernet II header to each Byte_FIFO packet.
// The packet source must obey the normal ready/valid rule and hold
// packet_data/packet_valid/packet_last while packet_ready is low.
module Ethernet_Frame_Adapter (
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] packet_data,
    input  wire       packet_valid,
    output logic      packet_ready,
    input  wire       packet_last,

    output logic [7:0] frame_data,
    output logic       frame_valid,
    input  wire        frame_ready,
    output logic       frame_last
);

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_HEADER,
        STATE_PAYLOAD
    } state_t;

    state_t     state = STATE_IDLE;
    logic [3:0] header_index = 4'd0;

    function automatic logic [7:0] header_byte(input logic [3:0] index);
        case (index)
            // Destination MAC: FF:FF:FF:FF:FF:FF
            4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5:
                header_byte = 8'hff;

            // Source MAC: 02:00:00:00:00:02
            4'd6:  header_byte = 8'h02;
            4'd7, 4'd8, 4'd9, 4'd10: header_byte = 8'h00;
            4'd11: header_byte = 8'h02;

            // EtherType: 0x88B5, transmitted in network byte order.
            4'd12: header_byte = 8'h88;
            4'd13: header_byte = 8'hb5;
            default: header_byte = 8'h00;
        endcase
    endfunction

    always_comb begin
        packet_ready = 1'b0;
        frame_data    = 8'h00;
        frame_valid   = 1'b0;
        frame_last    = 1'b0;

        case (state)
            STATE_HEADER: begin
                // Byte_FIFO remains stalled until all header bytes have been
                // accepted by the downstream AXI-Stream sink.
                frame_data  = header_byte(header_index);
                frame_valid = 1'b1;
            end

            STATE_PAYLOAD: begin
                // A zero-copy ready/valid mapping.  packet_last is presented
                // with the final payload byte and remains asserted through a
                // stall; state advances only on the real valid&&ready transfer.
                packet_ready = frame_ready;
                frame_data    = packet_data;
                frame_valid   = packet_valid;
                frame_last    = packet_valid && packet_last;
            end

            default: begin
                // Wait for a complete packet source to become visible before
                // committing a partial Ethernet frame into the Taxi TX FIFO.
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= STATE_IDLE;
            header_index <= 4'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    header_index <= 4'd0;
                    if (packet_valid) begin
                        state <= STATE_HEADER;
                    end
                end

                STATE_HEADER: begin
                    if (frame_valid && frame_ready) begin
                        if (header_index == 4'd13) begin
                            header_index <= 4'd0;
                            state        <= STATE_PAYLOAD;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end

                STATE_PAYLOAD: begin
                    if (packet_valid && frame_ready && packet_last) begin
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state        <= STATE_IDLE;
                    header_index <= 4'd0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire

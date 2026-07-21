`timescale 1ns / 1ps
`default_nettype none

// Repeating 128-byte bring-up packet source.  Each packet contains 00..7F.
// The gap makes individual frames easy to inspect during the first capture.
module Fixed_Packet_Generator (
    input  wire       clk,
    input  wire       rst,
    output logic [7:0] packet_data,
    output logic      packet_valid,
    input  wire       packet_ready,
    output logic      packet_last
);

    logic [7:0] byte_index;
    logic [7:0] gap_counter;
    logic       active;

    always_comb begin
        packet_data  = byte_index;
        packet_valid = active;
        packet_last  = active && (byte_index == 8'h7f);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            byte_index  <= 8'h00;
            gap_counter <= 8'h00;
            active      <= 1'b0;
        end else if (active) begin
            if (packet_valid && packet_ready) begin
                if (packet_last) begin
                    byte_index  <= 8'h00;
                    gap_counter <= 8'h00;
                    active      <= 1'b0;
                end else begin
                    byte_index <= byte_index + 1'b1;
                end
            end
        end else if (gap_counter == 8'hff) begin
            gap_counter <= 8'h00;
            active      <= 1'b1;
        end else begin
            gap_counter <= gap_counter + 1'b1;
        end
    end

endmodule

`default_nettype wire

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Byte_FIFO
// Synchronous BRAM FIFO used as the second buffering level after the four-line
// ring. The ninth stored bit carries the fixed-packet boundary marker.
//////////////////////////////////////////////////////////////////////////////////
module Byte_FIFO #(
    parameter integer DEPTH        = 512,
    parameter integer PACKET_BYTES = 128
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [8:0]  in_data,
    input  wire        in_valid,
    output wire        in_ready,

    output wire [8:0]  out_data,
    output wire        out_valid,
    input  wire        out_ready,

    output wire [15:0] level,
    output wire        almost_full
);

    function integer clog2;
        input integer value;
        integer i;
        begin
            value = value - 1;
            for (i = 0; value > 0; i = i + 1)
                value = value >> 1;
            clog2 = (i == 0) ? 1 : i;
        end
    endfunction

    localparam integer ADDR_W = clog2(DEPTH);
    (* ram_style = "block" *) reg [8:0] mem [0:DEPTH-1];
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W-1:0] rd_ptr;
    reg [ADDR_W:0]   mem_count;
    reg [8:0]        out_data_r;
    reg              out_valid_r;

    wire push  = in_valid && in_ready;
    wire pop   = out_valid_r && out_ready;
    wire fetch = (mem_count != 0) && (!out_valid_r || out_ready);

    assign in_ready    = (mem_count < DEPTH);
    assign out_data    = out_data_r;
    assign out_valid   = out_valid_r;
    assign level       = mem_count + out_valid_r;
    assign almost_full = (mem_count >= DEPTH - PACKET_BYTES);

    // Standard synchronous BRAM template. The output validity bit, not RAM
    // contents, is reset; this allows Vivado to infer a RAMB18 primitive.
    always @(posedge clk) begin
        if (push)
            mem[wr_ptr] <= in_data;

        if (fetch)
            out_data_r <= mem[rd_ptr];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr      <= {ADDR_W{1'b0}};
            rd_ptr      <= {ADDR_W{1'b0}};
            mem_count   <= {(ADDR_W+1){1'b0}};
            out_valid_r <= 1'b0;
        end else begin
            if (push) begin
                if (wr_ptr == DEPTH - 1)
                    wr_ptr <= {ADDR_W{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            if (fetch) begin
                out_valid_r <= 1'b1;
                if (rd_ptr == DEPTH - 1)
                    rd_ptr <= {ADDR_W{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end else if (pop) begin
                out_valid_r <= 1'b0;
            end

            case ({push, fetch})
                2'b10: mem_count <= mem_count + 1'b1;
                2'b01: mem_count <= mem_count - 1'b1;
                default: mem_count <= mem_count;
            endcase
        end
    end

endmodule

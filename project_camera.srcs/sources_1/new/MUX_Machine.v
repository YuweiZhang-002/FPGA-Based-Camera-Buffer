`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: MUX_Machine
// Role: Pure combinational 4:1 selector for the granted camera's data + metadata.
//
// Why combinational now:
//   - Arbitration already LATCHES grant_onehot and holds it stable for the whole
//     transaction, so MUX does not need its own grant_locked register.
//   - The AXI-side FIFO is the elastic buffer, so MUX does not need a skid stage.
//   - back-pressure (px_ready) is routed straight from AXI to the Line_Generators,
//     so MUX no longer participates in the ready path.
// Net effect on Block Design: MUX loses clk, rst, drawback, ready_in, src_ready,
//   work, px_in/px_out -> far fewer nets.
//////////////////////////////////////////////////////////////////////////////////
module MUX_Machine (
    // ---- Camera 0 ----
    input  wire [15:0] data_in_0,
    input  wire [9:0]  line_in_0,
    input  wire [3:0]  buf_in_0,    // frame number / buffer index
    input  wire        valid_0,
    // ---- Camera 1 ----
    input  wire [15:0] data_in_1,
    input  wire [9:0]  line_in_1,
    input  wire [3:0]  buf_in_1,
    input  wire        valid_1,
    // ---- Camera 2 ----
    input  wire [15:0] data_in_2,
    input  wire [9:0]  line_in_2,
    input  wire [3:0]  buf_in_2,
    input  wire        valid_2,
    // ---- Camera 3 ----
    input  wire [15:0] data_in_3,
    input  wire [9:0]  line_in_3,
    input  wire [3:0]  buf_in_3,
    input  wire        valid_3,

    // ---- Control ----
    input  wire [3:0]  grant,       // One-hot, already held stable by Arbitration.

    // ---- Selected outputs ----
    output reg  [15:0] data_out,
    output reg  [9:0]  line_out,
    output reg  [3:0]  buf_out,     // frame number for Address_Generator
    output reg  [1:0]  cam_id,
    output reg         valid_out
);

    // One-hot select. cam_id is decoded from the grant itself, so neither the
    // Arbitration cam_id nor any per-camera cam_id input is needed here.
    always @(*) begin
        data_out  = 16'd0;
        line_out  = 10'd0;
        buf_out   = 4'd0;
        cam_id    = 2'd0;
        valid_out = 1'b0;

        case (grant)
            4'b0001: begin data_out=data_in_0; line_out=line_in_0; buf_out=buf_in_0; cam_id=2'd0; valid_out=valid_0; end
            4'b0010: begin data_out=data_in_1; line_out=line_in_1; buf_out=buf_in_1; cam_id=2'd1; valid_out=valid_1; end
            4'b0100: begin data_out=data_in_2; line_out=line_in_2; buf_out=buf_in_2; cam_id=2'd2; valid_out=valid_2; end
            4'b1000: begin data_out=data_in_3; line_out=line_in_3; buf_out=buf_in_3; cam_id=2'd3; valid_out=valid_3; end
            default: ; // no grant -> outputs stay 0 / valid_out low
        endcase
    end

endmodule

`timescale 1ns / 1ps

module MUX_Machine(
    input  wire [15:0] pixel_in_0,
    input  wire [15:0] pixel_in_1,
    input  wire [15:0] pixel_in_2,
    input  wire [15:0] pixel_in_3,
    input  wire        px_valid_0,
    input  wire        px_valid_1,
    input  wire        px_valid_2,
    input  wire        px_valid_3,

    input  wire [3:0]  grant,
    input  wire        drawback,   // AXI completion pulse in this clk domain.
    input  wire        px_ready,   // Ready from AXI4_Compiler.
    input  wire        clk,
    input  wire        rst,

    output reg  [15:0] pixel_out,
    output reg  [1:0]  cam_id,
    output reg         px_valid,
    output wire        src_ready,  // Ready back to the selected LG.
    output wire        work
);

    reg [3:0] grant_locked;

    wire grant_is_onehot = (grant == 4'b0001) ||
                           (grant == 4'b0010) ||
                           (grant == 4'b0100) ||
                           (grant == 4'b1000);
    wire [3:0] selected_grant = (grant_locked != 4'd0) ? grant_locked :
                                (grant_is_onehot ? grant : 4'd0);

    reg [15:0] selected_pixel;
    reg [1:0]  selected_cam_id;
    reg        selected_valid;

    always @(*) begin
        selected_pixel  = 16'd0;
        selected_cam_id = 2'd0;
        selected_valid  = 1'b0;

        case (selected_grant)
            4'b0001: begin
                selected_pixel  = pixel_in_0;
                selected_cam_id = 2'd0;
                selected_valid  = px_valid_0;
            end
            4'b0010: begin
                selected_pixel  = pixel_in_1;
                selected_cam_id = 2'd1;
                selected_valid  = px_valid_1;
            end
            4'b0100: begin
                selected_pixel  = pixel_in_2;
                selected_cam_id = 2'd2;
                selected_valid  = px_valid_2;
            end
            4'b1000: begin
                selected_pixel  = pixel_in_3;
                selected_cam_id = 2'd3;
                selected_valid  = px_valid_3;
            end
        endcase
    end

    assign work = (grant_locked != 4'd0);
    assign src_ready = !px_valid || px_ready;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            grant_locked <= 4'd0;
            pixel_out    <= 16'd0;
            cam_id       <= 2'd0;
            px_valid     <= 1'b0;
        end else begin
            // Lock one camera for the whole AXI transaction.  Grant changes from
            // arbitration are ignored until AXI drawback closes this transaction.
            if (drawback) begin
                grant_locked <= 4'd0;
                pixel_out    <= 16'd0;
                cam_id       <= 2'd0;
                px_valid     <= 1'b0;
            end else begin
                if ((grant_locked == 4'd0) && grant_is_onehot) begin
                    grant_locked <= grant;
                end

                // One-stage ready/valid buffer.  When AXI is not ready, hold the
                // registered byte and deassert src_ready so the selected LG does
                // not pop and lose the next byte.
                if (src_ready) begin
                    pixel_out <= selected_pixel;
                    cam_id    <= selected_cam_id;
                    px_valid  <= selected_valid;
                end
            end
        end
    end

endmodule

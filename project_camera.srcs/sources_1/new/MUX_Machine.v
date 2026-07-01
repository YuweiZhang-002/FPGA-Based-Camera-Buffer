`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: MUX_Machine
// Role: Pure combinational 8:1 selector supporting up to 8 cameras.
//       Selects the granted camera's pixel data, line count, and control signals
//       based on the 8-bit one-hot arbitration grant vector.
//
// Revision History:
// - Compressed the grant bus width to [7:0] (8 bits total) for up to 8 camera 
//   channels, achieving a clean 1-to-1 direct mapping.
// - Input buses remain packed: data_in [127:0], line_in [79:0], valid_in [7:0], 
//   and final_frame_in [7:0].
// - Output 'cam_id' remains [2:0] to distinguish cameras 0 through 7.
// - Pure combinational design; Valid-Ready bidirectional signals pass through 
//   with zero delay to eliminate packet loss.
//////////////////////////////////////////////////////////////////////////////////
module MUX_Machine (
    // ---- Packed 8-Camera Bus Interfaces (Concatenation: {Cam7, Cam6, ..., Cam0}) ----
    input  wire [127:0] data_in,        // Aggregated pixel data (8 cameras * 16-bit)
    input  wire [79:0]  line_in,        // Aggregated line numbers (8 cameras * 10-bit)
    input  wire [7:0]   valid_in,       // Aggregated pixel valid signals (8 cameras * 1-bit)
    input  wire [7:0]   final_frame_in, // Aggregated frame done signals (8 cameras * 1-bit)

    // ---- Arbitration Control Interface ----
    input  wire [7:0]   grant,          // 8-bit one-hot grant bus (1 bit per camera)

    // ---- Selected Outputs to AXI4_Compiler ----
    output reg  [15:0]  data_out,
    output reg  [9:0]   line_out,
    output reg  [2:0]   cam_id,         // Decoded current camera ID (0-7)
    output reg          valid_out,      // Output pixel valid flag
    output reg          final_frame     // Output frame done flag
);

    // ==========================================================================
    // High-performance, one-hot priority decoding combinational logic 
    // based on the case(1'b1) structure.
    // ==========================================================================
    always @(*) begin
        // Safe default assignments to prevent synthesis of dangerous transparent latches
        data_out    = 16'd0;
        line_out    = 10'd0;
        cam_id      = 3'd0;
        valid_out   = 1'b0;
        final_frame = 1'b0;

        case (1'b1)
            // Camera 0 is selected
            grant[0]: begin
                data_out    = data_in[15:0];
                line_out    = line_in[9:0];
                cam_id      = 3'd0;
                valid_out   = valid_in[0];
                final_frame = final_frame_in[0];
            end
            
            // Camera 1 is selected
            grant[1]: begin
                data_out    = data_in[31:16];
                line_out    = line_in[19:10];
                cam_id      = 3'd1;
                valid_out   = valid_in[1];
                final_frame = final_frame_in[1];
            end
            
            // Camera 2 is selected
            grant[2]: begin
                data_out    = data_in[47:32];
                line_out    = line_in[29:20];
                cam_id      = 3'd2;
                valid_out   = valid_in[2];
                final_frame = final_frame_in[2];
            end
            
            // Camera 3 is selected
            grant[3]: begin
                data_out    = data_in[63:48];
                line_out    = line_in[39:30];
                cam_id      = 3'd3;
                valid_out   = valid_in[3];
                final_frame = final_frame_in[3];
            end

            // Camera 4 is selected
            grant[4]: begin
                data_out    = data_in[79:64];
                line_out    = line_in[49:40];
                cam_id      = 3'd4;
                valid_out   = valid_in[4];
                final_frame = final_frame_in[4];
            end
            
            // Camera 5 is selected
            grant[5]: begin
                data_out    = data_in[95:80];
                line_out    = line_in[59:50];
                cam_id      = 3'd5;
                valid_out   = valid_in[5];
                final_frame = final_frame_in[5];
            end

            // Camera 6 is selected
            grant[6]: begin
                data_out    = data_in[111:96];
                line_out    = line_in[69:60];
                cam_id      = 3'd6;
                valid_out   = valid_in[6];
                final_frame = final_frame_in[6];
            end

            // Camera 7 is selected
            grant[7]: begin
                data_out    = data_in[127:112];
                line_out    = line_in[79:70];
                cam_id      = 3'd7;
                valid_out   = valid_in[7];
                final_frame = final_frame_in[7];
            end
            
            default: begin
                // Under default state (no active grant), outputs remain grounded
            end
        endcase
    end

endmodule

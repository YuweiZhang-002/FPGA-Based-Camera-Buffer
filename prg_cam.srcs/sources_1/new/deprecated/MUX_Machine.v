`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): direct one-hot stream selection at
// the top level replaces this extra mux wrapper.
`ifdef ENABLE_DEPRECATED_CAMERA_GLUE
//////////////////////////////////////////////////////////////////////////////////
// Module Name: MUX_Machine
// Role: Pure combinational multiplexer for 4 camera interfaces. It selects the
//       granted camera's pixel data, line number, and control signals.
//
// Scalable Design Note (User Hint):
// This module is designed with 4 physical camera ports to reduce block diagram
// complexity. To support 8 cameras, instantiate this module twice.
//   - Instance 1 (for Cams 0-3): Set BASE_CAM_ID = 0 and use grant[3:0].
//   - Instance 2 (for Cams 4-7): Set BASE_CAM_ID = 4 and use grant[7:4].
// The two instances must then be merged by the top-level control logic before
// their outputs are consumed by AXI4_Compiler.
//
// C6 Repackaging Notice:
// This module's ports have changed. You MUST re-package this IP in Vivado
// and upgrade the instances in your block design.
//////////////////////////////////////////////////////////////////////////////////
module MUX_Machine #(
    parameter BASE_CAM_ID = 0
) (
    // ---- Camera Interfaces (4 physical ports) ----
    input  wire [15:0] data_in_0,
    input  wire [9:0]  line_in_0,
    input  wire [3:0]  frame_cnt_0,
    input  wire        px_valid_0,
    input  wire        final_frame_0,

    input  wire [15:0] data_in_1,
    input  wire [9:0]  line_in_1,
    input  wire [3:0]  frame_cnt_1,
    input  wire        px_valid_1,
    input  wire        final_frame_1,

    input  wire [15:0] data_in_2,
    input  wire [9:0]  line_in_2,
    input  wire [3:0]  frame_cnt_2,
    input  wire        px_valid_2,
    input  wire        final_frame_2,

    input  wire [15:0] data_in_3,
    input  wire [9:0]  line_in_3,
    input  wire [3:0]  frame_cnt_3,
    input  wire        px_valid_3,
    input  wire        final_frame_3,

    // ---- Control Interface ----
    input  wire [3:0]  grant,            // 8-bit one-hot grant from the global arbiter

    // ---- Selected Outputs to AXI4_Compiler ----
    output wire  [15:0] data_out,
    output wire  [9:0]  line_out,
    output wire  [3:0]  frame_cnt_out,
    output wire  [2:0]  cam_id,           // Global Camera ID (0-7), calculated with BASE_CAM_ID
    output wire         px_valid_ext,
    output wire         final_frame,      // Output frame complete flag
    output wire         valid             // Output data valid flag
);

    localparam MODULE_DEPRECATED = 1'b1;



    // ==========================================================================
    // Combinational multiplexing logic using direct assign statements for
    // highly-optimized, one-hot priority routing, eliminating any sequential
    // inference and ensuring zero transmission delay.
    // ==========================================================================
    assign valid = (grant != 0) ? 1'b1 : 1'b0;

    // Determine the selected local camera ID based on the local 4-bit grant slice.
    wire [1:0] selected_local_cam_id = grant[0] ? 2'd0 :
                                       grant[1] ? 2'd1 :
                                       grant[2] ? 2'd2 :
                                       grant[3] ? 2'd3 : 2'd0;

    // Assign outputs based on selected camera, ensuring a default value when no grant is active
    assign data_out      = (selected_local_cam_id == 2'd0 && valid) ? data_in_0 :
                           (selected_local_cam_id == 2'd1 && valid) ? data_in_1 :
                           (selected_local_cam_id == 2'd2 && valid) ? data_in_2 :
                           (selected_local_cam_id == 2'd3 && valid) ? data_in_3 : 16'd0;

    assign line_out      = (selected_local_cam_id == 2'd0 && valid) ? line_in_0 :
                           (selected_local_cam_id == 2'd1 && valid) ? line_in_1 :
                           (selected_local_cam_id == 2'd2 && valid) ? line_in_2 :
                           (selected_local_cam_id == 2'd3 && valid) ? line_in_3 : 10'd0;

    assign frame_cnt_out = (selected_local_cam_id == 2'd0 && valid) ? frame_cnt_0 :
                           (selected_local_cam_id == 2'd1 && valid) ? frame_cnt_1 :
                           (selected_local_cam_id == 2'd2 && valid) ? frame_cnt_2 :
                           (selected_local_cam_id == 2'd3 && valid) ? frame_cnt_3 : 4'd0;
                           
    assign px_valid_ext  = (selected_local_cam_id == 2'd0 && valid) ? px_valid_0 :
                           (selected_local_cam_id == 2'd1 && valid) ? px_valid_1 :
                           (selected_local_cam_id == 2'd2 && valid) ? px_valid_2 :
                           (selected_local_cam_id == 2'd3 && valid) ? px_valid_3 : 1'b0;

    assign final_frame   = (selected_local_cam_id == 2'd0 && valid) ? final_frame_0 :
                           (selected_local_cam_id == 2'd1 && valid) ? final_frame_1 :
                           (selected_local_cam_id == 2'd2 && valid) ? final_frame_2 :
                           (selected_local_cam_id == 2'd3 && valid) ? final_frame_3 : 1'b0;
                           

    // Calculate the global camera ID by adding the base to the locally selected ID.
    assign cam_id        = selected_local_cam_id + BASE_CAM_ID[2:0];

endmodule
`endif

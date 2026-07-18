`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): AXI4-Full/DDR2 writer removed from
// the active design. Historical source is retained only for archaeology.
// Define ENABLE_DEPRECATED_AXI_DDR2 explicitly to compile this legacy module.
`ifdef ENABLE_DEPRECATED_AXI_DDR2
//////////////////////////////////////////////////////////////////////////////////
// Module Name: AXI4_Compiler
// Role: FIFO-based stream compiler (AXI4-DDR2 path deprecated).
//
// Migration note:
// - Legacy AXI4 write interface is kept for block-design compatibility only.
// - Active datapath is now: ingress FIFO (L1) -> formatter FIFO (L2).
// - No DDR2 write is performed in this module.
//////////////////////////////////////////////////////////////////////////////////
module AXI4_Compiler #(
    parameter LINE_WORDS  = 640,
    parameter FIFO0_DEPTH = 1024,
    parameter FIFO1_DEPTH = 1024
)(
    // ---- Input Data Interface ----
    input  wire [15:0]  pixel,

    // ---- Coordinate & Control Interface (from MUX) ----
    input  wire [2:0]   cam_id,
    input  wire [3:0]   frame_num,
    input  wire [9:0]   line_num,
    input  wire         is_final_line,

    // ---- Clocks & Reset ----
    input  wire         clk,
    input  wire         axi_clk,
    input  wire         rst,
    input  wire         rst_axi,

    // ---- Flow Control ----
    input  wire         permit,
    input  wire         px_valid,
    output wire         px_ready,

    // ---- System Control ----
    output wire         drawback,

    // ---- Ring Buffer Handoff to Send_Control (kept for compatibility) ----
    output wire         frame_done_pulse,
    output wire [2:0]   done_cam_id,
    output wire [3:0]   done_frame_ptr,

    // ---- (Debug) AXI Connection Status Observe ----
    output wire [1:0]   m_axi_connstatus,

    // ---- AXI4 Write Address Channel ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY"  *) input  wire         m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR"   *) output wire [31:0]  m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN"    *) output wire [7:0]   m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID"  *) output wire         m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE"   *) output wire [2:0]   m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST"  *) output wire [1:0]   m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK"   *) output wire         m_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID"     *) output wire [3:0]   m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS"    *) output wire [3:0]   m_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE"  *) output wire [2:0]   m_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT"   *) output wire [2:0]   m_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREGION" *) output wire [3:0]   m_axi_awregion,

    // ---- AXI4 Write Data Channel ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY"   *) input  wire         m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA"    *) output wire [63:0]  m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID"   *) output wire         m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST"    *) output wire         m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB"    *) output wire [7:0]   m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WID"      *) output wire [3:0]   m_axi_wid,

    // ---- AXI4 Write Response Channel ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID"   *) input  wire         m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP"    *) input  wire [1:0]   m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BUSER"    *) input  wire         m_axi_buser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID"      *) input  wire [3:0]   m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY"   *) output wire         m_axi_bready
);

    localparam MODULE_DEPRECATED_DDR_PATH = 1'b1;

    function integer clog2;
        input integer value;
        integer i;
        begin
            value = value - 1;
            for (i = 0; value > 0; i = i + 1)
                value = value >> 1;
            clog2 = i;
        end
    endfunction

    localparam FIFO0_AW = clog2(FIFO0_DEPTH);
    localparam FIFO1_AW = clog2(FIFO1_DEPTH);

    reg [15:0] fifo0_mem [0:FIFO0_DEPTH-1];
    reg [15:0] fifo1_mem [0:FIFO1_DEPTH-1];

    reg [FIFO0_AW-1:0] fifo0_wr_ptr;
    reg [FIFO0_AW-1:0] fifo0_rd_ptr;
    reg [FIFO0_AW:0]   fifo0_count;

    reg [FIFO1_AW-1:0] fifo1_wr_ptr;
    reg [FIFO1_AW-1:0] fifo1_rd_ptr;
    reg [FIFO1_AW:0]   fifo1_count;

    reg line_active;
    reg [10:0] words_out_count;

    reg [2:0] done_cam_id_r;
    reg [3:0] done_frame_ptr_r;
    reg       frame_done_pulse_r;
    reg       drawback_r;

    reg       final_line_latched;
    reg [2:0] cam_id_latched;
    reg [3:0] frame_num_latched;
    reg [9:0] line_num_latched;

    wire ingress_fire = px_valid && px_ready;
    wire move_fire    = (fifo0_count != 0) && (fifo1_count != FIFO1_DEPTH);
    wire egress_fire  = line_active && (fifo1_count != 0);

    assign px_ready = (fifo0_count != FIFO0_DEPTH);

    assign drawback        = drawback_r;
    assign frame_done_pulse = frame_done_pulse_r;
    assign done_cam_id      = done_cam_id_r;
    assign done_frame_ptr   = done_frame_ptr_r;

    // Legacy AXI path is explicitly disabled in FIFO mode.
    assign m_axi_connstatus = 2'b00;
    assign m_axi_awaddr     = 32'd0;
    assign m_axi_awlen      = 8'd0;
    assign m_axi_awvalid    = 1'b0;
    assign m_axi_awsize     = 3'd0;
    assign m_axi_awburst    = 2'd0;
    assign m_axi_awlock     = 1'b0;
    assign m_axi_awid       = 4'd0;
    assign m_axi_awqos      = 4'd0;
    assign m_axi_awcache    = 3'd0;
    assign m_axi_awprot     = 3'd0;
    assign m_axi_awregion   = 4'd0;

    assign m_axi_wdata      = 64'd0;
    assign m_axi_wvalid     = 1'b0;
    assign m_axi_wlast      = 1'b0;
    assign m_axi_wstrb      = 8'd0;
    assign m_axi_wid        = 4'd0;

    assign m_axi_bready     = 1'b0;

    // Keep unused legacy ports referenced to avoid synthesis warnings.
    wire _unused_legacy_inputs;
    assign _unused_legacy_inputs = axi_clk ^ m_axi_awready ^ m_axi_wready ^ m_axi_bvalid ^ m_axi_buser ^ rst_axi ^ m_axi_bid[0] ^ m_axi_bresp[0] ^ line_num[0];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fifo0_wr_ptr      <= {FIFO0_AW{1'b0}};
            fifo0_rd_ptr      <= {FIFO0_AW{1'b0}};
            fifo0_count       <= {(FIFO0_AW+1){1'b0}};

            fifo1_wr_ptr      <= {FIFO1_AW{1'b0}};
            fifo1_rd_ptr      <= {FIFO1_AW{1'b0}};
            fifo1_count       <= {(FIFO1_AW+1){1'b0}};

            line_active       <= 1'b0;
            words_out_count   <= 11'd0;

            frame_done_pulse_r <= 1'b0;
            drawback_r         <= 1'b0;
            done_cam_id_r      <= 3'd0;
            done_frame_ptr_r   <= 4'd0;

            final_line_latched <= 1'b0;
            cam_id_latched     <= 3'd0;
            frame_num_latched  <= 4'd0;
            line_num_latched   <= 10'd0;
        end else begin
            frame_done_pulse_r <= 1'b0;
            drawback_r         <= 1'b0;

            if (permit && !line_active) begin
                line_active        <= 1'b1;
                words_out_count    <= 11'd0;
                final_line_latched <= is_final_line;
                cam_id_latched     <= cam_id;
                frame_num_latched  <= frame_num;
                line_num_latched   <= line_num;
            end

            // FIFO0 write/read (ingress stage)
            if (ingress_fire) begin
                fifo0_mem[fifo0_wr_ptr] <= pixel;
                if (fifo0_wr_ptr == FIFO0_DEPTH - 1)
                    fifo0_wr_ptr <= {FIFO0_AW{1'b0}};
                else
                    fifo0_wr_ptr <= fifo0_wr_ptr + 1'b1;
            end

            if (move_fire) begin
                if (fifo0_rd_ptr == FIFO0_DEPTH - 1)
                    fifo0_rd_ptr <= {FIFO0_AW{1'b0}};
                else
                    fifo0_rd_ptr <= fifo0_rd_ptr + 1'b1;
            end

            case ({ingress_fire, move_fire})
                2'b10: fifo0_count <= fifo0_count + 1'b1;
                2'b01: fifo0_count <= fifo0_count - 1'b1;
                default: fifo0_count <= fifo0_count;
            endcase

            // FIFO1 write/read (formatter stage)
            if (move_fire) begin
                fifo1_mem[fifo1_wr_ptr] <= fifo0_mem[fifo0_rd_ptr];
                if (fifo1_wr_ptr == FIFO1_DEPTH - 1)
                    fifo1_wr_ptr <= {FIFO1_AW{1'b0}};
                else
                    fifo1_wr_ptr <= fifo1_wr_ptr + 1'b1;
            end

            if (egress_fire) begin
                if (fifo1_rd_ptr == FIFO1_DEPTH - 1)
                    fifo1_rd_ptr <= {FIFO1_AW{1'b0}};
                else
                    fifo1_rd_ptr <= fifo1_rd_ptr + 1'b1;

                if (words_out_count == (LINE_WORDS - 1)) begin
                    words_out_count <= 11'd0;
                    line_active     <= 1'b0;
                    drawback_r      <= 1'b1;

                    if (final_line_latched) begin
                        frame_done_pulse_r <= 1'b1;
                        done_cam_id_r      <= cam_id_latched;
                        done_frame_ptr_r   <= frame_num_latched;
                    end
                end else begin
                    words_out_count <= words_out_count + 1'b1;
                end
            end

            case ({move_fire, egress_fire})
                2'b10: fifo1_count <= fifo1_count + 1'b1;
                2'b01: fifo1_count <= fifo1_count - 1'b1;
                default: fifo1_count <= fifo1_count;
            endcase
        end
    end

endmodule
`endif

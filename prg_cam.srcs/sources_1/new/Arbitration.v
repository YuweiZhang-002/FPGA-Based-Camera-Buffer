`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Arbitration
//
// MODIFIED (2026-07-17): minimal four-camera packet arbiter.
// - request[i] is a level from Line_Buffer, not a pulse.
// - grant_onehot is the only lock state; a separate locked flag is unnecessary.
// - A grant is held for the complete 128-byte packet.
// - released must be selected_valid && selected_ready && selected_packet_last.
// - Only a two-bit round-robin pointer is retained.  Watchdog, drawback and
//   auxiliary status flags from the older architecture were removed.
//////////////////////////////////////////////////////////////////////////////////
module Arbitration(
    input  wire       sys_clk,      // 统一 100 MHz 控制时钟
    input  wire       rst,          // 高有效异步复位
    input  wire [3:0] request,      // bit[i]=1：第 i 路 LB 至少有一个 committed packet
    input  wire       released,     // 当前 owner 的 packet_last 完成 valid/ready 握手
    output reg  [3:0] grant_onehot  // one-hot 包所有权；0000 表示当前未授权
);

    // ========================================================================
    // SHARED SM FLAG -- 组合优先级和时序 owner 更新共同读取
    // ========================================================================
    // rr_ptr 表示“下一次优先从哪一路开始查找”，不是当前相机编号。
    // 例如 rr_ptr=2 时检查顺序是 2 -> 3 -> 0 -> 1。
    reg [1:0] rr_ptr;

    // Four explicit priority orders are easier to audit than a rotating barrel
    // shifter and synthesize to a small priority network for exactly four cams.
    // ========================================================================
    // COMBINATIONAL-ONLY FLAG -- 只由下方 next-grant 组合块写入
    // ========================================================================
    // next_grant 是组合优先网络的候选结果，只在 grant_onehot==0 时装入。
    // 默认 0000 避免 request 全低时推断 latch。
    reg [3:0] next_grant;

    always @(*) begin
        next_grant = 4'b0000;
        case (rr_ptr)
            2'd0: begin
                if      (request[0]) next_grant = 4'b0001;
                else if (request[1]) next_grant = 4'b0010;
                else if (request[2]) next_grant = 4'b0100;
                else if (request[3]) next_grant = 4'b1000;
            end
            2'd1: begin
                if      (request[1]) next_grant = 4'b0010;
                else if (request[2]) next_grant = 4'b0100;
                else if (request[3]) next_grant = 4'b1000;
                else if (request[0]) next_grant = 4'b0001;
            end
            2'd2: begin
                if      (request[2]) next_grant = 4'b0100;
                else if (request[3]) next_grant = 4'b1000;
                else if (request[0]) next_grant = 4'b0001;
                else if (request[1]) next_grant = 4'b0010;
            end
            default: begin
                if      (request[3]) next_grant = 4'b1000;
                else if (request[0]) next_grant = 4'b0001;
                else if (request[1]) next_grant = 4'b0010;
                else if (request[2]) next_grant = 4'b0100;
            end
        endcase
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            grant_onehot <= 4'b0000;
            rr_ptr       <= 2'd0;
        end else if (grant_onehot == 0) begin
            // 空闲态：采样当前 request 并锁定一名 owner。request 后续变化
            // 不会改变 grant，直到 released 到达，从而保证包内 byte 不交叉。
            grant_onehot <= next_grant;
        end else if (released) begin
            // 释放后把起始优先级移动到刚完成通道的下一路，形成 round-robin。
            case (grant_onehot)
                4'b0001: rr_ptr <= 2'd1;
                4'b0010: rr_ptr <= 2'd2;
                4'b0100: rr_ptr <= 2'd3;
                default: rr_ptr <= 2'd0;
            endcase
            // One idle arbitration cycle cleanly separates packet owners.
            // 该空拍还让上一个 LB 撤销 valid、下一个 LB 预取 BRAM 首字节。
            grant_onehot <= 4'b0000;
        end
    end

endmodule

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Alarmer
//
// MODIFIED (2026-07-17): active lightweight pclk-to-sys_clk edge detector.
// Camera pclk is asynchronous to the 100 MHz FPGA system clock.  The two
// ASYNC_REG stages reduce metastability risk; alarm is one sys_clk-wide pulse
// for each observed pclk rising edge.
//
// IMPORTANT: this pulse-sampling scheme requires sys_clk to be sufficiently
// faster than pclk and camera data to remain stable until the synchronized edge
// is observed.  If that timing contract cannot be met, use a pclk-written
// asynchronous FIFO instead of synchronizing the data strobe.
//////////////////////////////////////////////////////////////////////////////////
module Alarmer(
    input  wire clk_data, // 异步输入：Camera PCLK；不能直接驱动 sys_clk 域状态机
    input  wire clk,      // 目标时钟：FPGA sys_clk（当前设计为 100 MHz）
    input  wire rst,      // 高有效异步复位，只复位同步链和边沿历史值
    output wire alarm     // clk 域单周期脉冲：检测到一次 clk_data 上升沿
);

    // ========================================================================
    // SHARED CDC FLAGS -- 同步 always 和组合 alarm 判断共同使用
    // ========================================================================
    // clk_meta 是同步链第一级，最可能出现亚稳态；clk_sync 是供逻辑使用的
    // 稳定副本。ASYNC_REG 属性要求布局工具把两级触发器相邻放置，以增加
    // 亚稳态恢复时间。它不等价于数据总线 CDC，仅适用于这里的单 bit 时钟采样。
    (* ASYNC_REG = "TRUE" *) reg clk_meta;
    (* ASYNC_REG = "TRUE" *) reg clk_sync;

    // clk_sync_d 保存 clk_sync 的上一拍值；当前为 1、上一拍为 0 即上升沿。
    reg clk_sync_d;

    // 纯组合边沿判断。alarm 不会自行保持，高电平宽度恰好为一个 clk 周期。
    assign alarm = clk_sync && !clk_sync_d;

    // 同一个 always block 更新同步链和历史寄存器。非阻塞赋值保证每一级读取
    // 的都是上一拍结果，因此逻辑顺序是 clk_data -> meta -> sync -> sync_d。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_meta   <= 1'b0;
            clk_sync   <= 1'b0;
            clk_sync_d <= 1'b0;
        end else begin
            clk_meta   <= clk_data;
            clk_sync   <= clk_meta;
            clk_sync_d <= clk_sync;
        end
    end

endmodule

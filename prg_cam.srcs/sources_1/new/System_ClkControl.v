`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: System_ClkControl
//
// 可选的 Clocking Wizard 复位释放器。locked=0 时异步拉低 rst_sys_n；
// locked 恢复后，利用两级移位寄存器在 clk_sys 域同步释放复位。
//
// 注意：当前 Camera_Pipeline 顶层直接接收高有效 rst，没有实例化本模块。
// 如果板级设计使用本模块，通常需要把 rst_sys_n 反相后连接到该 rst 端口。
//////////////////////////////////////////////////////////////////////////////////
module System_ClkControl (
    input  wire clk_sys,  // Clocking Wizard 输出时钟，也是释放复位的目标域
    input  wire locked,   // PLL/MMCM 锁定指示；低电平充当异步复位源
    output wire rst_sys_n // 同步释放后的低有效系统复位
);

    // 文档标记，不参与控制逻辑；0 表示这是可选工具而非废弃模块。
    localparam MODULE_DEPRECATED = 1'b0;

    // ========================================================================
    // RESET-SM-ONLY FLAG -- 仅下方复位释放 always 写入
    // ========================================================================
    // reset_sync_reg[0] 是释放链第一级，bit[1] 是最终输出。初始化值只作为
    // FPGA 上电辅助，真正的异步清零条件仍是 locked 的下降/低电平。
    reg [1:0] reset_sync_reg = 2'b00;

    // 异步置于复位、同步退出复位：locked 丢失时无需等待 clk_sys；恢复时
    // 必须连续经过两个 clk_sys 上升沿，避免把异步 locked 直接送到下游。
    always @(posedge clk_sys or negedge locked) begin
        if (!locked) begin
            // 当 PLL 未锁定时（locked=0），立刻强制整个系统进入复位
            reset_sync_reg <= 2'b00;
        end else begin
            // 左移注入 1：00 -> 01 -> 11，第二拍后 rst_sys_n 才拉高。
            reset_sync_reg <= {reset_sync_reg[0], 1'b1};
        end
    end

    // 组合输出 bit[1]；下游仅在 rst_sys_n=1 时运行。
    assign rst_sys_n = reset_sync_reg[1];

endmodule

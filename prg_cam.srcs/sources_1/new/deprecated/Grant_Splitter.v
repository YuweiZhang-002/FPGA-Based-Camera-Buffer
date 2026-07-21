`timescale 1ns / 1ps
// DEPRECATED (2026-07 FIFO/SRAM refactor): use direct grant bus slicing.
`ifdef ENABLE_DEPRECATED_CAMERA_GLUE
// 注释导读：本模块没有时钟、状态机或寄存器，只是四根 wire 的名字转换。
// bus_in 是 one-hot grant；outN 与 bus_in[N] 完全相同。IDX 参数未参与逻辑，
// 是历史 IP 打包遗留项。当前顶层直接使用 arb_grant[N]，无需额外层级。
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Grant_Splitter
//
// OBSELETE MODULE NOTICE:
// This module was originally used to split an 8-bit grant bus into individual
// wires. This functionality is trivial and can be accomplished by direct
// bus slicing/wiring in the Vivado Block Design.
//
// With the system upgrade to 8 cameras (16 grant channels), the grant bus is
// now 16 bits wide, making this module incompatible.
//
// RECOMMENDATION: This module should be deleted from the project. The 16-bit
// 'grant_onehot' output from the 'Arbitration' module should be split
// manually in the block design to connect to the two 'MUX_Machine' instances.
// e.g.:
//   - grant_onehot[7:0]   -> MUX_Machine_0.grant
//   - grant_onehot[15:8]  -> MUX_Machine_1.grant
//
//////////////////////////////////////////////////////////////////////////////////
module Grant_Splitter #(
    parameter IDX = 0 // 历史兼容参数；当前实现中未使用
)
(
    input  wire [3:0] bus_in,

    output wire out0,
    output wire out1,
    output wire out2,
    output wire out3
);

// 仅供源码阅读/工具检索的常量，不控制数据路径。
localparam MODULE_DEPRECATED = 1'b1;

// Trivial assignments, better handled by direct wiring.
// 连续赋值属于纯组合连线，不会推断 latch/flip-flop。
assign out0 = bus_in[0];
assign out1 = bus_in[1];
assign out2 = bus_in[2];
assign out3 = bus_in[3];

endmodule
`endif

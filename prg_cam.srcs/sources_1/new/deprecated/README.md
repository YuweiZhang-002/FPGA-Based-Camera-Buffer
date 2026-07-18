# Deprecated RTL archive

2026-07-17 update: `Packet_Formatter.v` and `Stream_Byte_Replacer.v` are now
archived here. The camera supplies the complete 128-byte packet, so active
`Byte_Replacer.v` only patches `cam_id`/`row_flags` and regenerates CRC-16.

本目录只保存 FIFO/SRAM 重构前的历史手写 RTL，不属于当前 `Camera_Pipeline` 数据链。

这些 Verilog 仍由 `ENABLE_DEPRECATED_*` 宏整体隔离，Vivado 工程中保持 `AutoDisabled`。不要在新的 top module 中例化它们；若未来确实恢复 AXI4/DDR2/DMA，应建立独立 legacy fileset 或单独分支，而不是重新混入 `new/` 根目录。

| 类别 | 文件 |
|---|---|
| AXI4/DDR2/DMA | `AXI4_Compiler.v`、`AXI4_CompilerSM.v`、`Send_Control.v`、`System_RefControl.v` |
| 旧相机前端 | `Pixel_Generator.v`、`Line_Generator.v`、`Alarmer.v` |
| 旧仲裁 glue | `MUX_Machine.v`、`Grant_Splitter.v` |
| 旧 location 原型 | `Location_Generator.v`、`Location_Buffer.v` |

当前有效 RTL 列表和模块连接见 [fpga_module_structure.md](../../../../docs/fpga_module_structure.md)。

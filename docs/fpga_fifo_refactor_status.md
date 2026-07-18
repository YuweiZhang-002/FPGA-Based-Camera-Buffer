# FPGA FIFO 重构状态

更新日期：2026-07-17

详细模块连接、ASM、包布局和 CRC 说明见 [`fpga_module_structure.md`](fpga_module_structure.md)。

## 当前结论

当前 synthesis top 为四相机 `Camera_Pipeline`，有效链路是：

```text
4 x (pclk/href/8-bit camera data)
    -> 4 x Camera_Capture
    -> 4 x Line_Buffer (每路 4 x 128-byte)
    -> 4-way Arbitration + one-hot mux
    -> Byte_Replacer (cam_id + flags + CRC)
    -> Byte_FIFO
    -> packet ready/valid output
```

`Packet_Formatter` 已经从有效链路删除。原因是输入本身已经包含 16-byte header、数据区和 2-byte CRC tail，总长固定 128 bytes。

## 已完成修改

### Camera Capture

- 输入改为 8-bit `camera_data`。
- `pclk` 是相机异步时钟，`sys_clk` 是 FPGA 100 MHz 主时钟。
- 新增活动版 `Alarmer`，在 sys_clk 域产生 pclk 上升沿 pulse。
- href 上升开始一个包，href 下降提交 metadata。
- reset 后 row 从 0 开始，无 VSYNC。
- 生成 bit0 FIRST、bit1 LAST、bit3 LENGTH_ERROR。

### Line Buffer

- 删除 `slot_busy[]`、`slot_ready[]`、`capture_active`、`capture_drop`。
- 改用 `wr_ptr/rd_ptr/used_count/committed_count`。
- RX 和 TX 分离为两个 agent；共享 count 由单独 accounting block 更新。
- `request` 保持到包发送完成，不使用可能丢失的一拍 pulse。
- 每路 512×8 packet RAM 已确认推断为一个 RAMB18。
- Buffer 满时设置 frame overflow sticky，并累计 dropped packet count。

### Arbitration

- 固定四路接口。
- 只保留 `grant_onehot` 和两位 `rr_ptr`。
- 删除旧 `locked/watchdog/drawback` 等辅助状态。
- grant 锁定到选中包 byte 127 完成 ready/valid 握手。

### Byte Replacer

- 新建 `Byte_Replacer.v`，取代旧 Packet Formatter 和单 offset replacer。
- offset 4 写入 `cam_id`。
- offset 9 输出原 flags OR FPGA flags。
- CRC 覆盖修改后的 offset 0..125。
- offset 126 输出 CRC low，offset 127 输出 CRC high。
- CRC 参数：init `FFFF`、poly `1021`、MSB-first、无 reflection/final xor。

### 包 flags

```text
bit0 FIRST_ROW
bit1 LAST_ROW
bit2 FRAME_OVERFLOW
bit3 LENGTH_ERROR (实际 byte 数 != 128)
bit7..4 保留原包值
```

### 废弃文件

以下文件现在位于 `prg_cam.srcs/sources_1/new/deprecated/`，并由宏默认隔离：

- `Packet_Formatter.v`
- `Stream_Byte_Replacer.v`
- 原 AXI4/DDR2/DMA 模块
- 原 Pixel/Line Generator 和旧胶水模块

## 当前有效接口

每路 Line Buffer 和 Arbitration 之间：

```verilog
Line_Buffer:
    output request;
    input  grant;
    output tx_data/tx_valid/tx_packet_last;
    input  tx_ready;
    output tx_cam_id/tx_flags;

Arbitration:
    input  [3:0] request;
    input        released;
    output [3:0] grant_onehot;
```

顶层 release 定义：

```verilog
released = selected_valid && selected_ready && selected_packet_last;
```

## 验证状态

### XSim

```text
PASS: lightweight four-camera packet arbitration
PASS: 4-camera LB arbitration, header merge and CRC-16
PASS: Line_Buffer counters, drop and sticky overflow
```

端到端 testbench 包含输出 backpressure、一个 126-byte 短包，并检查全部 512 个输出 bytes；独立 Line Buffer testbench 验证四槽满、整包丢弃和 bit2 sticky 传播。

### Vivado OOC synthesis

```text
part:        xc7a50ticsg324-1L
sys_clk:     100 MHz
LUT:         590
register:    554
RAMB18:      5
DSP:         0
WNS:         +3.875 ns
synth:       0 errors, 0 critical warnings, 0 warnings
```

## 必须保留的工程注意事项

1. 当前 pclk 方案是 sys_clk pulse sampling，不是异步 FIFO；必须验证真实 pclk 频率和 data hold time。
2. MCU/相机必须在 FPGA reset 后从第一行开始发送，因为没有 VSYNC 可重新寻找帧边界。
3. 输入必须按固定 128-byte 结构组织。短包会补零、长包截取前 128 bytes，并置 LENGTH_ERROR。
4. 被 Line Buffer 满直接丢弃的包不能给自身写 overflow flag；硬件会在后续成功包报告 sticky bit，并保留 dropped counter。
5. 板级 bitstream 前仍需补真实 pin、I/O standard、sys_clk 和异步输入时序约束。

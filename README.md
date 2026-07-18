# Multi-Camera FIFO-Based FPGA Packet Buffer

## 1. 项目概述

本项目当前实现一个基于 FPGA 内部 FIFO/BRAM 的四摄像头数据缓冲与聚合系统。摄像头输入已经是固定 128-byte 完整行包，包内包含 16-byte header、数据区和 2-byte CRC tail；FPGA 不再依赖 AXI4 或外部 DDR，而是在片内完成跨相机缓冲、完整包仲裁、字段补充、CRC 重算和 ready/valid 输出。

当前设计的核心数据链为：

```text
4 × Camera_Capture
    -> 4 × Line_Buffer (每路 4 × 128-byte)
    -> 4-way Arbitration
    -> Byte_Replacer
    -> Byte_FIFO
    -> ready/valid packet stream
```

仓库同时保留两个版本：

*   **`project_camera.srcs/`**：早期 AXI4/DDR、Line Generator 和 Block Design 工程，作为历史版本保留。
*   **`prg_cam.srcs/`**：当前最新的 FIFO/BRAM 四相机实现，包含有效 RTL、明确废弃的 RTL 和仿真 testbench。

当前模块架构、状态机和综合结果见 [`docs/fpga_module_structure.md`](docs/fpga_module_structure.md)，重构状态见 [`docs/fpga_fifo_refactor_status.md`](docs/fpga_fifo_refactor_status.md)。

## 2. 模块功能说明

系统由以下几个核心 Verilog 模块构成：

*   **`Alarmer`（pclk 边沿同步器）**
    *   **功能**：每路相机 `pclk` 与 FPGA 100 MHz `sys_clk` 异步。该模块使用两级 `ASYNC_REG` 同步器，在 `sys_clk` 域产生单周期 pclk 上升沿 pulse。
    *   **核心机制**：所有后级模块只使用 `sys_clk`，四路相机数据在统一时钟域内进入 Line Buffer 和 Arbitration。

*   **`Camera_Capture`（摄像头采集前端）**
    *   **功能**：接收一组 `pclk`、`href` 和 8-bit camera data。`href` 上升表示 128-byte 包开始，`href` 下降表示包结束。
    *   **核心机制**：统计 href 有效期间的 byte 数；复位后从 row 0 开始，无 VSYNC。生成第一行、最后一行和长度错误 flags。

*   **`Line_Buffer`（四包环形缓冲）**
    *   **功能**：每个摄像头对应一个 Line Buffer，使用 512×8 BRAM 保存四个 128-byte 包，并保存与包对齐的 `cam_id/row_flags/length`。
    *   **核心机制**：使用 `wr_ptr`、`rd_ptr`、`used_count` 和 `committed_count` 管理 FIFO 顺序。RX 和 TX 分别由独立 always block 管理，不使用 `slot_busy[]`、`slot_ready[]`、`capture_active` 或 `capture_drop`。
    *   **溢出策略**：四个 slot 全部占用时，新的 href 包被整体丢弃，累计 dropped counter，并将 frame overflow bit sticky 到后续成功输出的包。

*   **`Arbitration`（四路仲裁机）**
    *   **功能**：接收四个 Line Buffer 的持续 `request`，采用 Round-Robin 方式公平选择一个完整包。
    *   **核心机制**：`grant_onehot` 同时充当授权输出和锁定状态；内部只保留两位 `rr_ptr`。grant 在整个 128-byte 包内保持不变，直到最后一个 byte 完成 valid/ready 握手。

*   **`Byte_Replacer`（字段修改与 CRC 单元）**
    *   **功能**：输入已经是完整 128-byte 包，因此该模块不重新生成 header 或 payload。
    *   **核心机制**：offset 4 写入 `cam_id`；offset 9 输出原始 flags 与 FPGA flags 的 OR；对修改后的 offset 0..125 计算 CRC-16，并覆盖 offset 126/127。
    *   **CRC 参数**：初值 `0xFFFF`、多项式 `0x1021`、MSB-first、无 reflection、无 final XOR，低字节先输出。

*   **`Byte_FIFO`（最终输出 FIFO）**
    *   **功能**：保存仲裁和 CRC 完成后的输出数据，为下游提供 ready/valid backpressure 隔离。
    *   **核心机制**：FIFO word 为 9 bit，其中 bit[7:0] 是数据，bit[8] 是 `packet_last`；默认深度 512 entries。

*   **`Camera_Pipeline`（Top Module）**
    *   **功能**：实例化四套 Camera Capture 和 Line Buffer，以及一套共享 Arbitration、Byte Replacer 和 Byte FIFO。
    *   **核心机制**：one-hot mux 同时选择数据、`cam_id` 和 `row_flags`，确保 metadata 不会与被授权的数据流错位。

*   **`deprecated/`（历史 RTL）**
    *   **功能**：保存已经退出有效数据链的 AXI4/DDR、Packet Formatter、旧单 byte replacer、Pixel/Line Generator 和胶水模块。
    *   **核心机制**：历史模块由 `ENABLE_DEPRECATED_*` 宏整体隔离，默认不会进入综合。

## 3. 架构与信号流

整个系统采用完整包粒度的闭环 ready/valid 握手机制：

1.  **数据采集**：每个 `Camera_Capture` 通过同步后的 pclk pulse 接收 8-bit 数据，并在 href 下降时给出 `line_end` 和本包 flags。
2.  **缓冲提交**：对应 `Line_Buffer` 将最多 128 bytes 写入当前 `wr_ptr`；包结束后增加 `committed_count`。
3.  **请求授权**：只要 `committed_count != 0`，Line Buffer 就持续拉高 `request`。`Arbitration` 从四路请求中选择一个 one-hot grant。
4.  **完整包传输**：获得 grant 的 Line Buffer 从 `rd_ptr` 连续输出 byte 0..127。未选中的 Line Buffer 不会消费数据。
5.  **字段与 CRC 更新**：共享 `Byte_Replacer` 修改 `cam_id` 和 `row_flags`，同时按 byte 更新 CRC；downstream stall 时 byte index 和 CRC 均保持不变。
6.  **FIFO 输出**：修改后的 `{packet_last, packet_data}` 写入 `Byte_FIFO`，再通过标准 ready/valid 接口送往 MCU 或其他下游模块。
7.  **释放授权**：只有 `selected_valid && selected_ready && selected_packet_last` 同时成立时才产生 `released`，仲裁器随后从下一通道开始轮询。

固定包布局为：

| Offset | 字段 | FPGA 行为 |
|---:|---|---|
| 0..3 | `sync0/sync1` | 原样通过 |
| 4 | `cam_id` | 写入当前相机 ID |
| 5..8 | `frame_id/row_idx` | 原样通过 |
| 9 | `row_flags` | 原 flags OR FPGA flags |
| 10..125 | 其余 header 和数据 | 原样通过，短包缺失区补零 |
| 126 | CRC low | FPGA 重算 |
| 127 | CRC high | FPGA 重算，同时产生 `packet_last` |

## 4. 闭环机制深度分析（“权利”模型）

为了确保多相机数据不会交叉、覆盖或失去错误信息，当前设计保留四种明确的权利交接机制。

#### 4.1. 控制权（Control Rights）

*   **核心**：`request`、`grant_onehot` 和 `released` 构成唯一的控制权路径。
*   **流程**：Line Buffer 在存在 committed packet 时持续请求；Arbitration 只选择一路；最后一个 byte 真正被下游接受后才释放。
*   **简化**：不再使用旧架构的 `drawback`、watchdog、Grant Splitter 或额外 `locked` flag。`grant_onehot != 0` 本身就表示当前授权已经锁定。

#### 4.2. 数据权（Data Rights）

*   **核心**：数据只在 `valid && ready` 时移动。
*   **流程**：
    1.  grant 选择唯一 Line Buffer。
    2.  one-hot mux 同时选择该通道的数据、last 和 metadata。
    3.  Byte Replacer、Byte FIFO 和外部输出逐级传播 backpressure。
    4.  grant 在 128-byte 包中间不会改变，因此不同摄像头的 byte 不会交叉。
*   **边界**：`packet_last` 必须和 valid/ready 握手共同使用，不能单独作为释放电平。

#### 4.3. 元数据与完整性权（Metadata and Integrity Rights）

*   **核心**：上游包内已有的字段保持不变，FPGA 只修改自己拥有的信息。
*   **Flags**：
    *   bit0：第一行。
    *   bit1：最后一行。
    *   bit2：该帧出现 Line Buffer overflow。
    *   bit3：href 内实际 byte 数不等于 128。
    *   bit7..4：保留原包值。
*   **CRC**：CRC 输入是已经写入新 `cam_id`、已经合并 `row_flags` 后的 offset 0..125，保证接收端校验的是最终输出内容。

#### 4.4. 容量权（Capacity Rights）

*   **核心**：`used_count` 表示已预留、已提交和正在发送的 slot；`committed_count` 表示完整接收但尚未发送完毕的包。
*   **约束**：始终满足 `0 <= committed_count <= used_count <= 4`。
*   **反压**：下游暂停会依次回传至 Byte FIFO、Byte Replacer 和被授权的 Line Buffer。
*   **溢出熔断**：如果新包到达时 `used_count == 4`，系统丢弃整个包而不是覆盖旧数据。丢包包本身无法携带 overflow bit，因此 bit2 会 sticky 到后续成功包，同时保留独立 dropped counter。

## 5. 后续进展

当前 RTL 和 OOC 综合已经验证，但完整板级工程还需要继续完成以下工作：

1.  根据实际开发板和四路相机接口补充 pin、I/O standard、input delay 和时钟约束。
2.  实测相机 pclk 频率及 data hold time；如果 100 MHz sys_clk pulse-sampling 余量不足，应改成 pclk 写、sys_clk 读的异步 FIFO。
3.  将 128-byte 输出接口与 MCU/RP2354 端的接收状态机、CRC 校验和丢包统计联调。
4.  根据真实数据率评估 4×128-byte 每路缓冲和 512-entry 输出 FIFO 是否需要加深。
5.  完成板级 implementation、bitstream 和长时间四相机压力测试。

## 6. 进展情况

*   **6/27 历史版本**：完成以 Arbitration、MUX Machine、AXI4 Compiler 和 DDR 为核心的多通道写入链路；源码保留在 `project_camera.srcs/`。
*   **7/17 FIFO/BRAM 重构**：新增 `prg_cam.srcs/`，将有效链路改为四路 Camera Capture、四路 Line Buffer、轻量 Arbitration、共享 Byte Replacer 和 Byte FIFO。
*   **7/17 协议更新**：固定 128-byte 包；offset 4 写 cam_id，offset 9 合并 flags，offset 126/127 重算 CRC。
*   **7/17 Line Buffer 简化**：删除逐 slot busy/ready flags，使用双指针和两个 count；RX/TX 分离；每路 512×8 存储映射为一个 RAMB18。
*   **验证结果**：
    *   `tb_Arbitration`：四路 round-robin 和完整包锁定通过。
    *   `tb_Camera_Pipeline`：四相机链路、短包、flags、cam_id、CRC 和 backpressure 通过。
    *   `tb_Line_Buffer`：四槽填满、整包丢弃、双 count 和 sticky overflow 通过。
    *   Vivado 2025.2.1 OOC 综合：590 LUT、554 Registers、5 RAMB18、0 DSP。
    *   100 MHz `sys_clk`：WNS `+3.875 ns`，综合 0 error、0 critical warning、0 warning。

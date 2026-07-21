# FPGA 四相机模块结构与运行逻辑

更新日期：2026-07-20

本文描述当前 Vivado synthesis top `Camera_Pipeline`。当前协议的关键前提是：相机侧送入的已经是一个完整的固定 128-byte 行包，FPGA 不再生成包头或拆分 payload，只补入 FPGA 才能确定的 `cam_id`、`row_flags`，并重算包尾 CRC。

## 1. 当前有效 RTL

| 文件 | 实例数量 | 作用 |
|---|---:|---|
| [`Camera_Pipeline.v`](../prg_cam.srcs/sources_1/new/Camera_Pipeline.v) | 1 | 四相机顶层、one-hot 数据选择、最终输出 FIFO |
| [`Alarmer.v`](../prg_cam.srcs/sources_1/new/Alarmer.v) | 4 | 将异步 `pclk` 上升沿转换成 `sys_clk` 域单周期脉冲 |
| [`Camera_Capture.v`](../prg_cam.srcs/sources_1/new/Camera_Capture.v) | 4 | 采集 8-bit 数据、检测 href、统计 128-byte 长度和行号 |
| [`Line_Buffer.v`](../prg_cam.srcs/sources_1/new/Line_Buffer.v) | 4 | 每相机 4×128-byte 环形缓冲、向仲裁器请求完整包 |
| [`Arbitration.v`](../prg_cam.srcs/sources_1/new/Arbitration.v) | 1 | 四路完整包 round-robin 仲裁 |
| [`Byte_Replacer.v`](../prg_cam.srcs/sources_1/new/Byte_Replacer.v) | 1 | 合并 `cam_id/row_flags`，计算 CRC-16 |
| [`Byte_FIFO.v`](../prg_cam.srcs/sources_1/new/Byte_FIFO.v) | 1 | 仲裁和 CRC 后的 9-bit 输出 FIFO |
| [`System_ClkControl.v`](../prg_cam.srcs/sources_1/new/System_ClkControl.v) | 0 | 可选板级 reset 工具，当前 top 未实例化 |

以下两个旧模块已经移到 [`new/deprecated/`](../prg_cam.srcs/sources_1/new/deprecated/README.md)：

- `Packet_Formatter.v`：不再需要重新生成 header、payload padding 和 row sequence。
- `Stream_Byte_Replacer.v`：只能替换一个固定 byte，不能完成双字段合并和 CRC。

## 2. Top module

### 2.1 顶层端口分组

`Camera_Pipeline` 使用一个公共 `sys_clk` 和四组相机输入：

```text
sys_clk, rst

cam0_pclk, cam0_href, cam0_data[7:0]
cam1_pclk, cam1_href, cam1_data[7:0]
cam2_pclk, cam2_href, cam2_data[7:0]
cam3_pclk, cam3_href, cam3_data[7:0]

packet_data[7:0], packet_valid, packet_ready, packet_last
```

调试输出包括：

- `arb_grant[3:0]`：当前 one-hot 仲裁结果。
- `overflow_pulse[3:0]`：对应 Line Buffer 无空槽时的一拍脉冲。
- `dropped_packet_count_0..3`：每路被整包丢弃的累计数量。
- `buffer_used_count[11:0]`：每路 3-bit `used_count`。
- `buffer_committed_count[11:0]`：每路 3-bit `committed_count`。
- `packet_fifo_level`、`packet_fifo_almost_full`：最终输出 FIFO 状态。

### 2.2 完整连接图

```mermaid
flowchart LR
    C0[Camera 0<br/>pclk/href/data] --> CC0[Camera_Capture 0]
    C1[Camera 1<br/>pclk/href/data] --> CC1[Camera_Capture 1]
    C2[Camera 2<br/>pclk/href/data] --> CC2[Camera_Capture 2]
    C3[Camera 3<br/>pclk/href/data] --> CC3[Camera_Capture 3]

    CC0 --> LB0[Line_Buffer 0<br/>4 x 128 B]
    CC1 --> LB1[Line_Buffer 1<br/>4 x 128 B]
    CC2 --> LB2[Line_Buffer 2<br/>4 x 128 B]
    CC3 --> LB3[Line_Buffer 3<br/>4 x 128 B]

    LB0 -->|request 0| ARB[Arbitration]
    LB1 -->|request 1| ARB
    LB2 -->|request 2| ARB
    LB3 -->|request 3| ARB

    ARB -->|grant one-hot| MUX[one-hot stream mux]
    LB0 --> MUX
    LB1 --> MUX
    LB2 --> MUX
    LB3 --> MUX

    MUX -->|data + cam_id + flags| REP[Byte_Replacer<br/>field patch + CRC]
    REP --> FIFO[Byte_FIFO<br/>data + packet_last]
    FIFO --> OUT[packet ready/valid output]
    OUT --> ETHA[Ethernet ingress adapter<br/>optional width/clock conversion]
    ETHA --> MAC[Ethernet MAC / DMA]
    MAC -. ready/backpressure .-> ETHA
    ETHA -. packet_ready .-> FIFO
    REP -->|last byte handshake| ARB
```

`Byte_Replacer` 只实例化一次。CRC 单元位于仲裁之后，因此不会为四路相机复制四份 CRC 组合逻辑。

### 2.3 顶层 ASM

```mermaid
stateDiagram-v2
    [*] --> Capture
    Capture: 四路 Camera_Capture 与 Line_Buffer 并行接收
    Capture --> Request: 任一 Line Buffer commit 完整包
    Request --> Granted: Arbitration 选择一个 request
    Granted --> Stream: 选中 LB 输出 byte 0..127
    Stream --> Stream: valid/ready 握手且不是 byte 127
    Stream --> Release: byte 127 完成 valid/ready 握手
    Release --> Request: 清 grant 并从下一相机开始轮询
    Request --> Capture: 没有 request
```

## 3. 时钟域

### 3.1 `pclk` 和 `sys_clk`

- `pclk0..3`：四个相机各自输出的异步采样时钟。
- `sys_clk`：FPGA 板载 100 MHz 时钟。
- 所有 Line Buffer、Arbitration、Byte Replacer、CRC 和 Byte FIFO 都只在 `sys_clk` 域运行。

每个 `Alarmer` 内部包含两级 `ASYNC_REG` 同步寄存器和一个延迟寄存器：

```text
pclk -> clk_meta -> clk_sync -> clk_sync_d
alarm = clk_sync && !clk_sync_d
```

### 3.2 使用条件

这种方案按照当前指示采用 `sys_clk` 观察 `pclk` 边沿。它要求：

1. `sys_clk` 明显快于 `pclk`，使 pclk 高、低电平都能被同步器观察到。
2. 相机 `data[7:0]` 在物理 pclk 上升沿之后保持稳定，直到同步后的 `alarm` 被处理。
3. 推荐 `sys_clk:pclk` 留出至少约 4:1 的工程余量。

如果实际相机 pclk 太高或数据保持时间不满足上述条件，应将 Camera Capture 改成 pclk 域写入、sys_clk 域读出的异步 FIFO。仅用同步器同步多 bit 数据总线不能替代异步 FIFO。

## 4. 128-byte 包定义

包头保持 MCU 的 packed 结构：

```c
typedef struct __attribute__((packed)) {
    uint16_t sync0;
    uint16_t sync1;
    uint8_t  cam_id;
    uint16_t frame_id;
    uint16_t row_idx;
    uint8_t  row_flags;
    uint8_t  payload_len;
    uint16_t row_seq;
    uint8_t  reserved[3];
} pkt_row_header_t;
```

| Offset | 长度 | 字段 | FPGA 行为 |
|---:|---:|---|---|
| 0..3 | 4 | `sync0/sync1` | 原样通过 |
| 4 | 1 | `cam_id` | 替换为 `{6'd0, cam_id[1:0]}` |
| 5..8 | 4 | `frame_id/row_idx` | 原样通过 |
| 9 | 1 | `row_flags` | 原 byte OR FPGA flags |
| 10..15 | 6 | `payload_len/row_seq/reserved` | 原样通过 |
| 16..125 | 110 | 包数据 | 原样通过；短包缺失区由 LB 补零 |
| 126 | 1 | CRC low | FPGA 重算并覆盖 |
| 127 | 1 | CRC high | FPGA 重算并覆盖，`packet_last=1` |

### 4.1 FPGA flags

| Bit | 名称 | 置位条件 |
|---:|---|---|
| 0 | `FIRST_ROW` | 复位后 row 0，或上一帧最后一行后的 row 0 |
| 1 | `LAST_ROW` | row 等于 `LINES_PER_FRAME-1` |
| 2 | `FRAME_OVERFLOW` | 当前帧至少有一个包因 Line Buffer 满而丢弃 |
| 3 | `LENGTH_ERROR` | href 高电平期间观察到的 byte 数不等于 128 |
| 7..4 | 保留 | FPGA 不主动置位，原包对应 bit 会保留 |

最终 offset 9 的值为：

```text
output_row_flags = original_packet_byte_9 | generated_flags
```

因此 FPGA 不会清除上游已经写入的任何 flags。

## 5. 标志位与位宽语义（Flag & Bit Semantics）

本节只描述当前有效 RTL 中真正存在的信号。`valid`、`ready`、`last` 均不是“提示信息”，而是会直接决定状态机是否前进的协议量。

### 5.1 流接口信号

| 信号 | 类型/位宽 | 驱动模块 | 有效或置位条件 | 保持/清除条件 | 最终流向 |
|---|---|---|---|---|---|
| `capture_data` | data，8 bit | `Camera_Capture` | 同步后的 `pclk_pulse && href_sync` | `capture_valid=0` 时数值无协议意义 | 写入对应 `Line_Buffer.packet_mem` |
| `capture_valid` | pulse，1 bit | `Camera_Capture` | 每个被 `sys_clk` 观察到的 pclk 上升沿 | 下一拍默认清 0 | 作为 Line Buffer BRAM 写使能资格 |
| `capture_line_start` | pulse，1 bit | `Camera_Capture` | `href_rise` | 下一拍默认清 0 | 触发 LB `reserve_event` 或 `drop_event` |
| `capture_line_end` | pulse，1 bit | `Camera_Capture` | `href_fall` | 下一拍默认清 0 | 触发 LB `commit_event` 或退出 `WR_DROP` |
| `request[i]` | level，1 bit/路 | `Line_Buffer[i]` | `committed_count != 0` | 最后一个 committed slot 释放后清除 | `Arbitration.request[i]` |
| `grant_onehot[i]` | state/level，1 bit/路 | `Arbitration` | 空闲时 round-robin 选中 `request[i]` | 当前包最后 byte 握手后清零 | 选择 LB 数据并只打开该路 `tx_ready` |
| `tx_valid` | level，1 bit | 获授权的 `Line_Buffer` | `RD_IDLE -> RD_SEND` 预取首 byte 后 | stall 时保持；最后 byte 握手后清零 | one-hot mux，再到 `Byte_Replacer.in_valid` |
| `tx_ready` | backpressure，1 bit | Top 组合逻辑 | `replacer_in_ready && grant[i]` | 随下游容量组合变化 | 允许相应 LB 前进读指针/byte index |
| `tx_packet_last` | boundary，1 bit | `Line_Buffer` | 当前固定输出位置为 127 | stall 时与 data/valid 一起保持 | 用于 `released` 和 Replacer 防御性重同步 |
| `out_packet_last` | boundary，1 bit | `Byte_Replacer` | `in_valid && byte_index==127` | 无 valid 时不得单独解释 | 存入 `Byte_FIFO` word 的 bit8 |
| `packet_valid` | level，1 bit | `Byte_FIFO` | 输出预取寄存器含有效 word | `packet_ready=0` 时保持 | Ethernet ingress 的 `tvalid` 或适配器输入 valid |
| `packet_ready` | backpressure，1 bit | 下游/Ethernet | 下游可接收当前 byte | 下游 stall 时为 0 | 控制 Byte FIFO `pop`，并逐级向前传播 |
| `packet_last` | boundary，1 bit | `Byte_FIFO` | 当前输出 word 的 bit8=1 | 与 `packet_data` 一起保持到握手 | 单包单帧模式可映射 Ethernet `tlast` |

统一握手定义为：

```text
transfer_fire = valid && ready
```

只有 `transfer_fire=1`，发送方才允许改变当前数据或位置计数器。`valid=1 && ready=0` 时必须保持 `data`、`last` 以及与该 byte 对齐的 metadata。

### 5.2 `row_flags[7:0]`

| Bit | 类型 | 产生者 | 驱动条件 | 清除/保持 | 数据流向 |
|---:|---|---|---|---|---|
| 0 `FIRST_ROW` | 行属性 | `Camera_Capture` | `href_fall && row_idx==0` | 只属于当前 slot；下一行重新计算 | `capture_flags -> flags_mem -> tx_flags -> Byte_Replacer -> packet_data[9]` |
| 1 `LAST_ROW` | 行属性 | `Camera_Capture` | `href_fall && row_idx==LINES_PER_FRAME-1` | 当前行提交后随 slot 保存 | 同上；同时允许 LB 清除已报告的 overflow sticky |
| 2 `FRAME_OVERFLOW` | 帧级 sticky 错误 | `Line_Buffer` | `drop_event` 置 `frame_overflow_pending`；后续成功包提交时 OR 入 metadata | 一个成功提交的 `LAST_ROW` 报告后清 pending | 进入 offset 9；精确次数另见 dropped counter |
| 3 `LENGTH_ERROR` | 包级错误 | `Camera_Capture` | `href_fall && byte_count!=128` | 每行重新计算 | 进入 offset 9；短包仍补零到 128 byte |
| 7..4 | 上游保留位 | Camera/MCU 包内容 | 由原始 packet byte 9 决定 | FPGA 不主动清除 | Replacer 用 OR 保留后送 Ethernet |

这里存在两份 flags，不能混为一谈：

1. 原始 flags 位于输入包 offset 9，随 byte 数据存入 `packet_mem`。
2. FPGA flags 位于 `flags_mem[slot]`，作为包级 metadata 独立于 byte RAM 保存。
3. `Byte_Replacer` 处理 offset 9 时才执行 `original_flags | tx_flags`，之后 CRC 使用合并后的最终值。

### 5.3 状态、计数和容量位宽

| 信号 | 位宽 | 可解释范围 | 语义与限制 |
|---|---:|---:|---|
| `row_idx` | 16 | 0..65535 | 当前参数只使用 0..479；最后一行 href 下降后回到 0 |
| `byte_count` | 9 | 0..511 | 511 饱和；用于判断 href 内是否恰好 128 byte |
| `wr_ptr/rd_ptr` | 2/2 | 0..3 | 分别指向下一写 slot、下一读 slot；按 FIFO 顺序回卷 |
| `used_count` | 3 | 0..4（合法） | 已预留、已提交和正在发送的 slot 总数 |
| `committed_count` | 3 | 0..4（合法） | 完整接收且尚未完成包尾握手的 slot 数 |
| `tx_output_index` | 8 | 0..127（使用） | 只在 `tx_valid && tx_ready` 时递增 |
| `byte_index` | 7 | 0..127 | Replacer 当前包内 offset，只在输入握手时递增 |
| `crc_reg` | 16 | CRC 状态 | offset 0..125 握手后更新；包尾后恢复 `16'hFFFF` |
| `grant_onehot` | 4 | `0000` 或 one-hot | 非零本身就是仲裁锁定状态，不另设 `locked` flag |
| `packet_fifo_level` | 16 | 当前实现 0..513 | 512-word RAM 加一个输出预取寄存器；不是单纯 RAM count |

### 5.4 隐含容量与余量

- 单路 Line Buffer：`4 × 128 = 512 byte`，最多保存 4 个不同完整包。
- 四路 Line Buffer：`4 × 512 = 2048 byte`，最多保存 16 个不同完整包。
- `Byte_FIFO`：512×9 BRAM 可保存 512 个 `{last,data}` word，即 4 个固定包；内部另有一个 9-bit 输出预取寄存器。
- 稳态最大不同包数量为 20：四路 LB 共 16 包，加末级 FIFO 中 4 包。包从 LB 流向 FIFO 的过程中会暂时同时占用源 slot 与目标 FIFO entries，因此不能把这段重叠空间重复计算为额外包。
- `almost_full = (mem_count >= 512-128)`，也就是 RAM 中达到 384 word 时置位。它表示 RAM 空余量已经小于或等于一个 128-byte 包的长度，是预警状态，不直接禁止写入。
- 真正阻止上游的是 `in_ready = (mem_count < 512)`。`almost_full` 当前只输出给监控逻辑，没有参与仲裁或丢包判断。
- `packet_fifo_level = mem_count + out_valid_r`。由于输出预取寄存器独立于 RAM，调试值可能比 RAM 深度多 1；容量判断应使用 `in_ready`，不要用 `level==512` 自行推导 full。

## 6. 各模块逻辑

以下模块说明优先解释信号类型、核心作用、驱动条件和数据流向；未参与状态前进的调试信号不作为控制条件。

### 6.1 `Camera_Capture`

#### 6.1.1 寄存器

| 寄存器 | 用途 |
|---|---|
| `href_meta/href_sync/href_sync_d` | href 两级同步和边沿检测 |
| `row_idx` | 无 VSYNC 行号；复位从 0 开始 |
| `byte_count` | 当前 href 区间观察到的 byte 数，9-bit 饱和 |
| `line_flags` | href 下降时锁存 FIRST/LAST/LENGTH_ERROR |

`cam_id` 是实例参数，不需要运行时寄存器。

#### 6.1.2 接收流程

```mermaid
flowchart TD
    A[href 同步上升] --> B[line_start=1<br/>byte_count=0]
    B --> C{同步 pclk 上升且 href=1?}
    C -->|是| D[采样 camera_data<br/>byte_valid=1<br/>byte_count++]
    D --> C
    C -->|href 同步下降| E[line_end=1]
    E --> F[生成 FIRST/LAST/LENGTH_ERROR]
    F --> G{最后一行?}
    G -->|否| H[row_idx++]
    G -->|是| I[row_idx=0]
```

没有 VSYNC。系统依赖 MCU/相机在 FPGA reset 后从帧 0 的第一行重新开始发送。

### 6.2 `Line_Buffer`

#### 6.2.1 删除的复杂状态

当前实现已经删除：

```text
slot_busy[]
slot_ready[]
capture_active
capture_drop
```

FIFO 顺序保证 `wr_ptr` 和 `rd_ptr` 不会指向需要逐 slot 查询的任意位置，因此没有必要保存四组 busy/ready bit。

#### 6.2.2 核心状态

| 信号 | 含义 |
|---|---|
| `wr_ptr` | RX 下一次预留/提交的 slot |
| `rd_ptr` | TX 下一次发送的 committed slot |
| `used_count` | 已预留、已提交和正在发送的 slot 总数 |
| `committed_count` | 已完整接收但尚未完成最后 byte 握手的包数 |
| `WR_IDLE/WR_STORE/WR_DROP` | 写侧三个状态 |
| `RD_IDLE/RD_SEND` | 读侧两个状态 |

必须始终满足：

```text
0 <= committed_count <= used_count <= 4
request = (committed_count != 0)
```

#### 6.2.3 双 agent 和计数块

RTL 被拆成三个职责明确的时序块：

1. RX agent：只管理 `wr_state/wr_ptr/wr_count`、metadata 和 overflow。
2. TX agent：只管理 `rd_state/rd_ptr`、输出 ready/valid 和发送 metadata。
3. Accounting：只根据 `reserve_event/commit_event/release_event` 更新两个 count。

这样 RX 和 TX 不会共同驱动同一组指针或状态寄存器。第三个计数块用于避免把 `used_count` 同时写在 RX、TX 两个 always 中造成多驱动。

#### 6.2.4 RX ASM

```mermaid
stateDiagram-v2
    [*] --> WR_IDLE
    WR_IDLE --> WR_STORE: line_start && used_count < 4 / reserve
    WR_IDLE --> WR_DROP: line_start && used_count == 4 / overflow
    WR_STORE --> WR_STORE: capture_valid / store byte if index < 128
    WR_STORE --> WR_IDLE: line_end / commit metadata, wr_ptr++
    WR_DROP --> WR_DROP: ignore capture bytes
    WR_DROP --> WR_IDLE: line_end
```

- 短包仍提交；TX 对缺失 byte 补 0，bit3 标记长度错误。
- 长包只保存前 128 bytes，bit3 同样标记长度错误。
- Buffer 满时整个 href 包被丢弃，不移动 `wr_ptr`。

#### 6.2.5 TX ASM

```mermaid
stateDiagram-v2
    [*] --> RD_IDLE
    RD_IDLE --> RD_SEND: grant && committed_count != 0 / read byte 0
    RD_SEND --> RD_SEND: valid && ready && index < 127 / read next byte
    RD_SEND --> RD_IDLE: valid && ready && index == 127 / release, rd_ptr++
```

`request` 是持续电平，不是一拍 pulse；只有 `committed_count` 变成 0 才撤销。这样即使仲裁器正在服务其他相机，请求也不会丢失。

#### 6.2.6 BRAM 模板

每路 `packet_mem` 是 512×8 simple-dual-port RAM：

- Port A：RX 写。
- Port B：TX 同步读。
- RAM 内容不复位，有效性完全由两个 count 控制。

内存端口位于独立、无异步复位的 `always @(posedge sys_clk)` 模板中。这一点是 Vivado 推断 RAMB18 的必要条件；如果把 RAM 访问放回异步复位块，综合器会将其展开成寄存器或 LUTRAM。

#### 6.2.7 overflow sticky 规则

Buffer 满而丢包时，该包不会进入数据链，因此它无法给自己的 offset 9 写 bit2。实现采用：

1. 丢包时置 `frame_overflow_pending=1`。
2. 后续成功提交的包将 bit2 OR 进 metadata。
3. 一个成功提交的 `LAST_ROW` 报告该状态后清零。

如果恰好丢弃最后一行，bit2 会保留到后续成功输出，避免 overflow 完全静默。接收端也应结合 `dropped_packet_count_*` 判断精确丢包位置。

### 6.3 `Arbitration`

接口只有：

```verilog
input  wire       sys_clk;
input  wire       rst;
input  wire [3:0] request;
input  wire       released;
output reg  [3:0] grant_onehot;
```

内部只保留：

- `grant_onehot[3:0]`：同时充当输出和“当前已经锁定”的状态。
- `rr_ptr[1:0]`：下一轮搜索起点。
- `next_grant`：组合 priority 结果，不是寄存器 flag。

没有 `locked`、watchdog、drawback 或额外 one-hot splitter。

四路持续请求时顺序为：

```text
0001 -> 0010 -> 0100 -> 1000 -> 0001 ...
```

释放条件严格是：

```verilog
released = selected_valid && selected_ready && selected_packet_last;
```

不能只观察 `packet_last` 电平，否则下游暂停时会提前切换相机并交叉两个包。

### 6.4 `Byte_Replacer`

#### 6.4.1 数据路径

```mermaid
flowchart TD
    A[in_valid && in_ready] --> B{byte_index}
    B -->|4| C[输出零扩展 cam_id]
    B -->|9| D[输出 in_data OR row_flags]
    B -->|0..125 其他位置| E[原样输出]
    C --> F[CRC 更新]
    D --> F
    E --> F
    B -->|126| G[输出 crc_reg low]
    B -->|127| H[输出 crc_reg high<br/>packet_last=1]
    H --> I[index=0, CRC=FFFF]
```

`byte_index` 和 `crc_reg` 只在真实握手时变化，因此 backpressure 不会造成 offset 错位。

#### 6.4.2 CRC

计算严格匹配给定的 C 函数：

```text
初值       0xFFFF
多项式     0x1021
输入顺序   offset 0 -> offset 125
每 byte    先 crc ^= byte << 8，再执行 8 次 MSB-first shift
反射       无
最终异或   无
输出顺序   offset126=low，offset127=high
```

CRC 输入使用已经替换后的 offset 4 和已经合并后的 offset 9，而不是原始包内容。

### 6.5 `Byte_FIFO`

FIFO word 为 9 bit：

```text
bit[7:0] data
bit[8]   packet_last
```

默认 512 entries，`almost_full` 在剩余空间不足一个 128-byte 包时置位。该 FIFO 位于 CRC 之后，因此下游暂停不会阻塞已经获得 grant 的相机，除非 FIFO 最终被填满并向前传播 backpressure。

## 10. 验证结果

### 10.1 功能仿真

| Testbench | 覆盖内容 | 结果 |
|---|---|---|
| [`tb_Camera_Pipeline.sv`](../prg_cam.srcs/sim_1/new/tb_Camera_Pipeline.sv) | 两路同时提交、第三包随后提交、FIRST/LAST、flags OR、cam_id、CRC、packet_last、输出反压 | PASS |
| [`tb_Arbitration.sv`](../prg_cam.srcs/sim_1/new/tb_Arbitration.sv) | 四路 round-robin、包内 grant 锁定、release | PASS |
| [`tb_Line_Buffer.sv`](../prg_cam.srcs/sim_1/new/tb_Line_Buffer.sv) | 四槽填满、第五包丢弃、双 count、后续包 sticky overflow | PASS |

### 10.2 Vivado 2025.2.1 OOC 综合

器件：`xc7a50ticsg324-1L`，`sys_clk=100 MHz`。

| 指标 | 结果 |
|---|---:|
| Slice LUT | 590 |
| Slice Register | 554 |
| RAMB18 | 5 |
| DSP | 0 |
| WNS | +3.875 ns |
| 综合 error / critical warning / warning | 0 / 0 / 0 |

5 个 RAMB18 的构成为：四路 Line Buffer 各一个 512×8 RAMB18，加一个 512×9 输出 Byte FIFO。

OOC 报告没有板级 input/output delay；生成 bitstream 前仍需按真实引脚、pclk 最大频率、数据保持时间和 I/O standard 补充 XDC。

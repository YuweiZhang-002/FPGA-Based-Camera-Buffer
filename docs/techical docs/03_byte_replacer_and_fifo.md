# 03 Byte Replacer、Byte FIFO 与 Frame Adapter

## Byte_Replacer

<code>Byte_Replacer</code>不重建 camera packet；它只修改 FPGA 拥有的字段并重算包尾 CRC-16：

| offset | 输出 |
|---:|---|
| 4 | <code>{6'd0, in_cam_id}</code> |
| 9 | 原 byte OR <code>in_row_flags</code> |
| 126 | CRC-16 低 byte |
| 127 | CRC-16 高 byte，同时 <code>out_packet_last=1</code> |

CRC 覆盖修改后的 offset 0..125，初值 FFFF，多项式 1021，MSB-first，无反射、无 final XOR。它不同于 Ethernet MAC 最后追加的 CRC-32 FCS。

<code>in_ready=out_ready</code>且<code>out_valid=in_valid</code>。byte index 和 CRC 只在 <code>in_valid && in_ready</code>时推进，stall 不会重复累计。证据：<code>Byte_Replacer.v:20-40, 44-108</code>。

## Byte_FIFO

<code>Byte_FIFO</code>默认深度 512 words，每 word 为 9 bit：

<code>{packet_last, packet_data[7:0]}</code>

这一设计让 last 与 data 一起排队，经历任意 stall 后仍保持对齐。FIFO 由三个单一写者的时序块组成：

- RX：写 RAM 和 <code>wr_ptr</code>。
- TX：读 RAM、<code>rd_ptr</code>和输出 holding register。
- CNT：唯一写 <code>mem_count</code>。

握手事件：

- <code>push = in_valid && in_ready</code>
- <code>fetch = mem_count != 0 && (!out_valid_r || out_ready)</code>
- <code>pop = out_valid_r && out_ready</code>

<code>level = mem_count + out_valid_r</code>，包含 RAM 外的输出寄存器。<code>almost_full</code>在 RAM 中剩余不足一个 128-byte packet 时置位；真正逐 word 阻塞由 <code>in_ready</code>完成。证据：<code>Byte_FIFO.v:14-29, 45-69, 74-133</code>。

## Ethernet_Frame_Adapter

Frame Adapter 把每个 128-byte Byte FIFO packet变为一个 142-byte AXI-Stream MAC frame。它不产生 preamble、FCS 或 IFG；这些由 Taxi MAC 产生。

### ASM

~~~mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> IDLE: packet_valid=0
    IDLE --> HEADER: packet_valid=1 / header_index=0
    HEADER --> HEADER: !(frame_valid && frame_ready)
    HEADER --> HEADER: handshake && header_index<13 / index++
    HEADER --> PAYLOAD: handshake && header_index==13
    PAYLOAD --> PAYLOAD: not(packet_valid && frame_ready && packet_last)
    PAYLOAD --> IDLE: packet_valid && frame_ready && packet_last
~~~

### 各状态的组合输出

| 状态 | packet_ready | frame_valid | frame_data | frame_last |
|---|---:|---:|---|---:|
| IDLE | 0 | 0 | 00 | 0 |
| HEADER | 0 | 1 | header[index] | 0 |
| PAYLOAD | frame_ready | packet_valid | packet_data | packet_valid && packet_last |

Header 的 index 只在 header byte真实握手时增加。Payload 状态为零拷贝映射；只有最后 payload byte同时满足 valid、ready、last 时状态才返回 IDLE。stall 期间上游 packet源必须遵守 ready/valid 稳定规则，Adapter 输出便保持 data/valid/last。

证据：<code>Ethernet_Frame_Adapter.sv:10-108</code>。

## Frame Adapter 反压时序

~~~mermaid
sequenceDiagram
    participant FIFO as Byte_FIFO
    participant AD as Frame Adapter
    participant TAXI as Taxi TX FIFO

    FIFO->>AD: packet_valid=1, first payload byte
    Note over AD: IDLE 观察到 packet_valid
    AD-->>FIFO: packet_ready=0
    loop 14 header bytes
        AD->>TAXI: frame_valid=1, header byte
        TAXI-->>AD: frame_ready
        Note over AD: 仅 valid&&ready 推进 header_index
    end
    AD-->>FIFO: packet_ready=frame_ready
    FIFO->>AD: payload data/valid/last
    alt Taxi stall
        TAXI-->>AD: frame_ready=0
        AD-->>FIFO: packet_ready=0
        Note over FIFO,AD: valid/data/last 保持
    else transfer
        TAXI-->>AD: frame_ready=1
        Note over FIFO,TAXI: payload byte握手
    end
~~~

## 仿真结论

<code>tb_Ethernet_Frame_Adapter</code>：

- reset 5 个 100 MHz 周期；
- 输入一个 00..7F payload；
- 以周期 7、11 的模式 stall header/payload，并专门延迟最后 byte；
- 对 142 个已握手 byte逐一比较；
- 检查 TLAST 只在 frame index 141；
- 显式检查上一周期 stalled 时 valid/data/last 不变；
- 2000 周期 timeout。

日志在 1895 ns 打印 PASS。它只覆盖单帧，不覆盖多帧连续边界；该缺口在 [07_simulation_and_verification.md](07_simulation_and_verification.md) 标为 PENDING。


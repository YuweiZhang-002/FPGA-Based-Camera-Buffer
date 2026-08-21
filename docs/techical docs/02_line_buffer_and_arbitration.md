# 02 Line Buffer 与仲裁

## Line Buffer 存储模型

每路 <code>Line_Buffer</code>默认有 4 个 slot，每 slot 固定对外输出 128 byte。<code>packet_mem</code>是 4×128×8 bit block-RAM 候选，另有每 slot 的 cam_id、flags、实际长度元数据。

两个计数器表达所有权：

- <code>used_count</code>：已 reserve、已 commit、或正在发送的 slot 总数。
- <code>committed_count</code>：完整接收、尚未完成末 byte 握手的包数。
- <code>rx_reserved = used_count > committed_count</code>：当前有一个接收中的 slot。
- <code>request = committed_count != 0</code>：持续电平，不是 pulse。

证据：<code>Line_Buffer.v:29-62, 73-106, 166</code>。

## 事件与计数不变量

| 事件 | 条件 | 结果 |
|---|---|---|
| reserve_event | line_start、无在途 RX、used < 4 | used +1，锁定写 slot |
| drop_event | line_start、无在途 RX、used >= 4 | 不 reserve；drop 计数 +1，置 sticky overflow |
| commit_event | line_end && rx_reserved | committed +1，保存元数据 |
| release_event | tx_valid && tx_ready && tx_packet_last | used -1、committed -1 |

正常协议下保持：

<code>0 <= committed_count <= used_count <= LINE_SLOTS</code>

reserve 与 release、commit 与 release可以同拍，计数不变。证据：<code>Line_Buffer.v:117-131, 302-320</code>。

## request / grant / released

~~~mermaid
sequenceDiagram
    participant LB as Line_Buffer[i]
    participant ARB as Arbitration
    participant MUX as one-hot MUX
    participant R as Byte_Replacer/FIFO

    LB->>ARB: request=1（至少一个 committed packet）
    ARB->>LB: grant[i]=1
    loop 128 bytes
        LB->>MUX: tx_valid, tx_data, tx_last
        MUX->>R: selected_valid/data/last
        R-->>MUX: selected_ready
        MUX-->>LB: tx_ready = selected_ready && grant[i]
    end
    MUX->>ARB: released = valid && ready && last
    ARB->>LB: grant 清零一个周期
    ARB->>LB: 从下一 round-robin 位置重新授权
~~~

关键点：

- 活动 grant 不因 request 变化而改变，避免包内 byte 交叉。
- <code>released</code>必须是末 byte 的真实握手，不能只看 last 电平。
- 未获授权 Line Buffer 的 <code>tx_ready</code>强制为 0，不会误弹数据。

证据：<code>Arbitration.v:6-9, 35-85</code>；<code>Camera_Pipeline.v:185-194, 241-244</code>。

## 反压传播

~~~mermaid
flowchart RL
    FR["Frame Adapter frame_ready"] --> PR["packet_ready"]
    PR --> BF["Byte_FIFO out_ready"]
    BF -->|"in_ready"| BR["Byte_Replacer out_ready/in_ready"]
    BR --> SR["selected_ready"]
    SR -->|"仅 grant 路"| LB["Line_Buffer tx_ready"]

    LB -->|"stall 时保持 tx_valid/data/last"| SR
    BF -->|"输出寄存器保持 {last,data}"| PR
~~~

在目标完整连接中，Taxi 的 <code>s_axis_tx.tready</code>经 Frame Adapter 的 PAYLOAD 状态反向传播到 <code>Byte_FIFO.packet_ready</code>。Header 期间 Frame Adapter 明确把 <code>packet_ready=0</code>，因此 Byte FIFO 头 byte 保持，直到 14-byte header 完成。

## 仲裁 ASM

~~~mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> IDLE: request == 0
    IDLE --> OWN0: rr search selects cam0
    IDLE --> OWN1: rr search selects cam1
    IDLE --> OWN2: rr search selects cam2
    IDLE --> OWN3: rr search selects cam3
    OWN0 --> OWN0: !released
    OWN1 --> OWN1: !released
    OWN2 --> OWN2: !released
    OWN3 --> OWN3: !released
    OWN0 --> IDLE: released / rr_ptr=1
    OWN1 --> IDLE: released / rr_ptr=2
    OWN2 --> IDLE: released / rr_ptr=3
    OWN3 --> IDLE: released / rr_ptr=0
~~~

RTL 不保存独立的 OWN 状态；上图的 OWN0..3就是 <code>grant_onehot</code>四种非零编码。

## 仿真证据与缺口

- <code>tb_Arbitration</code>：验证 1111 请求时 0→1→2→3 round-robin，以及活动授权不被 request 改变；日志 PASS。没有 timeout，也不涉及 byte/stall。
- <code>tb_Line_Buffer</code>：填满 4 slot，第 5 包 drop，释放一包后接收 LAST_ROW 包并合并 sticky overflow，最终 used/committed/request 清零；日志 PASS。它检查 TLAST、cam_id、flags 和计数，但没有比较 <code>tx_data</code>，也没有施加 <code>tx_ready</code> stall。
- <code>tb_Camera_Pipeline</code>：通过真实 byte 握手间接验证包不交叉，覆盖周期性下游 stall；日志 PASS。

因此仲裁功能和基本计数为 PASS；Line Buffer 的独立数据逐 byte 比较和独立 stall stability 仍为 PENDING。


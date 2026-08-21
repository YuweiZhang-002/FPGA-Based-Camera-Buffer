# 01 Camera Pipeline 数据流

## 模块链

<code>Camera_Pipeline</code>在 100 MHz <code>sys_clk</code>域组合以下模块：

1. 4×<code>Camera_Capture</code>
2. 4×<code>Line_Buffer</code>
3. <code>Arbitration</code>和 one-hot 组合 MUX
4. <code>Byte_Replacer</code>
5. <code>Byte_FIFO</code>

输出为 <code>packet_data[7:0]</code>、<code>packet_valid</code>、<code>packet_ready</code>、<code>packet_last</code>。证据：<code>Camera_Pipeline.v:18-48, 82-289</code>。

## Camera_Capture

每路 camera 的 <code>pclk</code>不是模块寄存器时钟。<code>Alarmer</code>把可观测的 pclk 上升沿转换为 <code>sys_clk</code>单周期脉冲；<code>href</code>另经两级同步器并做边沿检测。

- <code>href_rise</code>产生 <code>line_start</code>。
- <code>pclk_pulse && href_sync</code>锁存 <code>camera_data</code>并产生 <code>byte_valid</code>。
- <code>href_fall</code>产生 <code>line_end</code>、行 flags，并递增/回卷行号。
- 期望每个 href 区间观察到 128 byte；否则置 <code>LENGTH_ERROR</code>。

Flags 低四位：

| bit | 名称 | 产生条件 |
|---:|---|---|
| 0 | FIRST_ROW | row_idx = 0 |
| 1 | LAST_ROW | row_idx = LINES_PER_FRAME-1 |
| 2 | FRAME_OVFLOW | 由实际能观察容量不足的 Line Buffer 维护 |
| 3 | LENGTH_ERROR | byte_count != 128 |

证据：<code>Camera_Capture.v:15-18, 47-50, 70-149</code>。

## 包级与 byte 级路径

~~~mermaid
flowchart TD
    P["camera pclk edge"] --> AL["Alarmer -> sys_clk pulse"]
    H["href"] --> HS["2-FF sync + rise/fall"]
    AL --> CC["Camera_Capture byte_data/byte_valid"]
    HS --> CC
    CC -->|"line_start reserve"| LB["Line_Buffer"]
    CC -->|"byte_valid write"| LB
    CC -->|"line_end commit metadata"| LB
    LB -->|"request level"| ARB["Round-robin Arbitration"]
    ARB -->|"grant one-hot"| MUX["Selected LB stream"]
    MUX -->|"valid/ready/last"| REP["Byte_Replacer"]
    REP -->|"9-bit {last,data}"| FIFO["Byte_FIFO"]
    FIFO -->|"packet_*"| DOWN["Frame Adapter（目标）"]
~~~

## 一包的生命周期

1. <code>line_start</code>到来且 Line Buffer 有空 slot：reserve，<code>used_count + 1</code>。
2. capture byte 写入当前 slot；短包后续由 Line Buffer 输出零补足到 128 byte，长包只保存前 128 byte。
3. <code>line_end</code>：commit，<code>committed_count + 1</code>，<code>request</code>持续为 1。
4. Arbiter 给予 one-hot <code>grant</code>，Line Buffer 逐 byte 输出。
5. 最后一 byte 完成 <code>valid && ready</code>后产生 <code>released</code>，slot 才真正释放。
6. Replacer 改 offset 4/9/126/127，Byte FIFO 存储 <code>{last,data}</code>。

## 当前验证边界

<code>tb_Camera_Pipeline</code>并行提交 cam0/cam1 首包，再提交 cam0 第二行和 cam2 的 126-byte 短包；在输出端每 7 周期制造一次 stall，自动比较 512 个已握手 byte及每包 TLAST，并验证 CRC-16 和无意外 drop。根目录 <code>xsim.log</code>记录 PASS。

该 testbench 未显式断言 stall 期间 <code>packet_valid/data/last</code>稳定，也未在结束时检查 <code>packet_fifo_level==0</code>和 4 路 used/committed 全为 0。因此 Camera Pipeline 标记为“RTL PASS（有限覆盖）”，不是完整验收 PASS。

## 与 Ethernet 的实际关系

源码层面接口可以直接对接 Frame Adapter；但当前 <code>Camera_Ethernet_Top</code>把 <code>packet_*</code>连接到 <code>Fixed_Packet_Generator</code>。所以“Camera→Byte_FIFO”和“固定源→Ethernet”目前是分别验证的两段，不是同一活动硬件层次。

证据：<code>Camera_Ethernet_Top.sv:64-79</code>。


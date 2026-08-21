# 05 Taxi Ethernet TX 运行机制

## TX 数据路径

~~~mermaid
flowchart LR
    AX["8-bit AXIS\nlogic_clk 100 MHz"] --> AF["taxi_axis_async_fifo_adapter\nTX_FRAME_FIFO=1\nDEPTH=4096"]
    AF -->|"CDC"| MAC["taxi_eth_mac_mii\nTX clock domain"]
    MAC --> PAD["taxi_axis_pad"]
    PAD --> TX["taxi_axis_gmii_tx"]
    TX -->|"8-bit internal GMII"| SPLIT["mii_select nibble split"]
    SPLIT -->|"4-bit MII"| MII["mii_txd/en/er @ 25 MHz"]
~~~

证据：<code>taxi_eth_mac_mii_fifo.sv:184-506</code>；<code>taxi_eth_mac_mii.sv:198-387</code>；<code>taxi_eth_mac_1g.sv:209-345</code>。

## AXIS 接收与 TX frame FIFO

在 100 MHz logic 域，Frame Adapter 的每个 byte以 <code>tvalid && tready</code>写入 <code>taxi_axis_async_fifo_adapter</code>。当前默认参数：

- <code>TX_FIFO_DEPTH=4096</code>
- <code>TX_FRAME_FIFO=1</code>
- <code>TX_DROP_OVERSIZE_FRAME=1</code>
- <code>TX_DROP_BAD_FRAME=1</code>
- <code>TX_DROP_WHEN_FULL=0</code>

frame FIFO直到接收到 <code>tlast</code>才更新 committed write pointer，使 MII 读侧只看到完整帧。二进制/Gray pointer同步和 reset synchronizer完成 logic_clk到 MII TX clock的 CDC。

<code>tx_fifo_good_frame</code>直接来自 FIFO 写侧 <code>s_status_good_frame</code>。源码在成功接收 <code>tlast</code>并提交 write pointer 时产生该 pulse。因此它证明“完整 AXIS frame已进入并提交到 Taxi TX FIFO”，不证明 MAC 已完成串行发送，更不证明 PHY 或 PC 收到。

证据：<code>taxi_eth_mac_mii_fifo.sv:350-410</code>；<code>taxi_axis_async_fifo.sv:380-500</code>及 <code>s_status_good_frame</code>赋值。

## MAC TX FSM

~~~mermaid
flowchart TD
    I["IDLE\n等待完整 frame 可见"] --> P["PREAMBLE\n7 × 0x55"]
    P --> S["SFD\n0xD5"]
    S --> D["PAYLOAD\n输入的 Ethernet header + payload"]
    D --> L["LAST"]
    L --> Q{"长度达到最小值?"}
    Q -- 否 --> Z["PAD\n追加 0x00"]
    Z --> F["FCS\nCRC-32 4 bytes"]
    Q -- 是 --> F
    F --> G["IFG\ncfg_tx_ifg=12 byte times"]
    G --> I
~~~

### Preamble 与 SFD

<code>STATE_IDLE</code>检测到有效输入后先输出 <code>ETH_PRE</code>；<code>STATE_PREAMBLE</code>通过计数器发送其余 preamble，最后输出 <code>ETH_SFD</code>，随后进入 payload。AXIS 的首 byte在 preamble末尾预取。

### Payload 与 underflow

Payload每个有效 byte更新 CRC 和帧长度。若 MAC需要下一个 byte时 <code>s_axis_tx.tvalid=0</code>，就记录 <code>stat_tx_err_underflow</code>并以错误帧结束。正常情况下，前级 frame FIFO隔离了 100 MHz供数与25 MHz发送。

### Padding

wrapper设置 <code>cfg_tx_pad_en=1</code>、<code>cfg_tx_min_pkt_len=59</code>。当前 Adapter产生 142 byte，所以无需 pad；短于配置下限时 <code>STATE_PAD</code>发送零并纳入 CRC。

### CRC-32 FCS

<code>taxi_lfsr</code>配置：

- width 32
- polynomial <code>0x04C11DB7</code>
- Galois、reverse输入处理

<code>STATE_FCS</code>按 <code>~crc_state_reg[7:0]</code>、<code>[15:8]</code>、<code>[23:16]</code>、<code>[31:24]</code>顺序发送 4 byte。该 Ethernet FCS与 camera packet内部 offset 126/127 的 CRC-16是两个独立校验层。

### IFG

wrapper设置 <code>cfg_tx_ifg=12</code>。MII模式每个8-bit内部 byte拆成两个4-bit周期，FSM使用对应的半速计数条件维持 96 bit times 的标准 IFG。

证据：<code>taxi_axis_gmii_tx.sv:175-520</code>；wrapper配置见 <code>Taxi_Ethernet_Subsystem.sv:126-135</code>。

## MII 输出

<code>taxi_eth_mac_mii</code>固定设置 <code>tx_mii_select=1</code>。<code>taxi_axis_gmii_tx</code>先保留高 nibble，再在 odd cycle输出它，因此每个8-bit MAC byte转换成两个连续4-bit MII transfer。MII TX clock由外部 bridge提供，在 100M模式为25 MHz。

## 未使用输出

TX-only阶段仍启用 RX MAC，但 wrapper把 RX、TX completion和statistics的 <code>tready</code>全拉高，避免未消费 source阻塞内部路径。MDIO不控制 PHY；顶层令 MDC=0、MDIO=Z。

## 当前运行证据

<code>tb_Fixed_Frame_Taxi_Rmii</code>运行 50.2 µs，观察到 RMII TX enable、无 <code>tx_error_underflow</code>/<code>tx_fifo_overflow</code>，并计到 12 次 <code>tx_fifo_good_frame</code>。这只足以判为“TX FIFO提交和RMII活动 PASS”。该 TB 没有解码 preamble/SFD/payload/FCS/IFG，所以这些线上值仍需 protocol monitor或PC捕获验证。


# 10 接口与信号参考

本页只记录当前本地源码中的端口和参数。方向均以所列模块为视角。

## Camera_Capture

参数：<code>CAM_ID[1:0]=0</code>、<code>PACKET_BYTES=128</code>、<code>LINES_PER_FRAME=480</code>。

| 端口 | 方向/宽度 | 含义 |
|---|---|---|
| pclk | in 1 | camera异步byte时钟输入，仅供Alarmer检测 |
| sys_clk | in 1 | 100 MHz处理时钟 |
| rst | in 1 | 高有效异步reset |
| href | in 1 | 一个128-byte行包区间 |
| camera_data | in 8 | camera byte |
| byte_data/byte_valid | out 8/1 | sys_clk域byte与脉冲 |
| line_start/line_end | out 1/1 | href边沿事件 |
| line_cam_id | out 2 | 固定CAM_ID |
| line_flags | out 8 | FIRST/LAST/LENGTH_ERROR |
| current_row_idx | out 16 | 调试行号 |
| current_byte_count | out 9 | 调试byte计数 |

证据：<code>Camera_Capture.v:15-34</code>。

## Line_Buffer

参数：<code>PACKET_BYTES=128</code>、<code>LINE_SLOTS=4</code>。

| 分组 | 端口 |
|---|---|
| 时钟/reset | <code>sys_clk</code>, <code>rst</code> |
| capture输入 | <code>capture_data[7:0]</code>, <code>capture_valid</code>, <code>capture_line_start</code>, <code>capture_line_end</code>, <code>capture_cam_id[1:0]</code>, <code>capture_flags[7:0]</code> |
| 仲裁 | out <code>request</code>, in <code>grant</code> |
| stream输出 | <code>tx_data[7:0]</code>, <code>tx_valid</code>, in <code>tx_ready</code>, <code>tx_packet_last</code>, <code>tx_cam_id[1:0]</code>, <code>tx_flags[7:0]</code> |
| 状态 | <code>overflow_pulse</code>, <code>dropped_packet_count[31:0]</code>, <code>used_count[2:0]</code>, <code>committed_count[2:0]</code> |

证据：<code>Line_Buffer.v:29-62</code>。

## Arbitration

| 端口 | 方向/宽度 | 语义 |
|---|---|---|
| sys_clk, rst | in 1 | 100 MHz；reset高有效 |
| request | in 4 | 每路持续请求 |
| released | in 1 | 当前owner末byte的valid&&ready&&last |
| grant_onehot | out 4 | 包级one-hot所有权 |

证据：<code>Arbitration.v:13-18</code>。

## Byte_Replacer

参数：<code>PACKET_BYTES=128</code>、<code>CAM_ID_OFFSET=4</code>、<code>ROW_FLAG_OFFSET=9</code>、<code>CRC_LOW_OFFSET=126</code>、<code>CRC_HIGH_OFFSET=127</code>。

输入stream为 <code>in_data/in_valid/in_ready/in_packet_last</code>，并带 <code>in_cam_id[1:0]</code>、<code>in_row_flags[7:0]</code>。输出stream为 <code>out_data/out_valid/out_ready/out_packet_last</code>。

证据：<code>Byte_Replacer.v:20-40</code>。

## Byte_FIFO

参数：<code>DEPTH=512</code>、<code>PACKET_BYTES=128</code>。

| 端口 | 方向/宽度 | 语义 |
|---|---|---|
| in_data | in 9 | {last,data} |
| in_valid/in_ready | in/out | 写侧握手 |
| out_data | out 9 | 稳定输出word |
| out_valid/out_ready | out/in | 读侧握手 |
| level | out 16 | RAM+holding register总占用 |
| almost_full | out 1 | RAM剩余不足一整包 |

证据：<code>Byte_FIFO.v:14-31</code>。

## Camera_Pipeline

参数：<code>LINES_PER_FRAME=480</code>、<code>PACKET_FIFO_DEPTH=512</code>、CAM0..3_ID=0..3。

| 分组 | 端口 |
|---|---|
| 时钟/reset | <code>sys_clk</code>, <code>rst</code> |
| camera 0..3 | 每路 <code>camN_pclk</code>, <code>camN_href</code>, <code>camN_data[7:0]</code> |
| packet输出 | <code>packet_data[7:0]</code>, <code>packet_valid</code>, in <code>packet_ready</code>, <code>packet_last</code> |
| 调试 | <code>arb_grant[3:0]</code>, <code>overflow_pulse[3:0]</code>, 4×drop count, <code>buffer_used_count[11:0]</code>, <code>buffer_committed_count[11:0]</code>, <code>packet_fifo_level[15:0]</code>, <code>packet_fifo_almost_full</code> |

证据：<code>Camera_Pipeline.v:18-62</code>。

## Ethernet_Frame_Adapter

| 端口 | 方向 | 语义 |
|---|---|---|
| clk, rst | in | logic域 |
| packet_data[7:0] | in | Byte FIFO byte |
| packet_valid | in | packet byte有效 |
| packet_ready | out | 仅PAYLOAD时跟随frame_ready |
| packet_last | in | payload末byte |
| frame_data[7:0] | out | Ethernet header或payload |
| frame_valid | out | AXIS有效 |
| frame_ready | in | Taxi ready |
| frame_last | out | 仅最后payload byte |

证据：<code>Ethernet_Frame_Adapter.sv:10-25</code>。

## Taxi_Ethernet_Subsystem

| 分组 | 端口 |
|---|---|
| reset/logic | <code>mac_rst</code>, <code>logic_clk</code>, <code>logic_rst</code> |
| flat frame输入 | <code>frame_data[7:0]</code>, <code>frame_valid</code>, <code>frame_ready</code>, <code>frame_last</code> |
| MII RX | <code>mii_rx_clk</code>, <code>mii_rxd[3:0]</code>, <code>mii_rx_dv</code>, <code>mii_rx_er</code> |
| MII TX | <code>mii_tx_clk</code>, <code>mii_txd[3:0]</code>, <code>mii_tx_en</code>, <code>mii_tx_er</code> |
| 调试 | <code>tx_error_underflow</code>, <code>tx_fifo_overflow</code>, <code>tx_fifo_good_frame</code> |

Taxi实例参数只显式传 <code>VENDOR</code>、<code>FAMILY</code>、<code>STAT_EN</code>。本地MII FIFO模块无 <code>DATA_W</code>参数。

证据：<code>Taxi_Ethernet_Subsystem.sv:8-26, 87-135</code>。

## Ethernet_Mii_Rmii_Bridge

| 分组 | 端口 |
|---|---|
| 控制 | <code>rst</code>, <code>mode_speed_100</code>, <code>rmii_ref_clk</code> |
| MII状态/RX | <code>mii_crs</code>, <code>mii_rx_rst</code>, <code>mii_rx_clk</code>, <code>mii_rx_dv</code>, <code>mii_rx_er</code>, <code>mii_rxd[3:0]</code> |
| MII TX | <code>mii_tx_rst</code>, <code>mii_tx_clk</code>, in <code>mii_tx_en</code>, <code>mii_tx_er</code>, <code>mii_txd[3:0]</code> |
| RMII RX | <code>rmii_crs_dv</code>, <code>rmii_rx_er</code>, <code>rmii_rxd[1:0]</code> |
| RMII TX | <code>rmii_tx_en</code>, <code>rmii_txd[1:0]</code> |

证据：<code>Ethernet_Mii_Rmii_Bridge.sv:8-33</code>；原始core端口见 <code>rmii_phy_if.v:9-32</code>。

## Camera_Ethernet_Top

| 顶层端口 | 方向 | pin |
|---|---|---|
| CLK100MHZ | in | E3 |
| CPU_RESETN | in | C12 |
| ETH_MDC | out | C9 |
| ETH_MDIO | inout | A9 |
| ETH_RSTN | out | B3 |
| ETH_CRSDV | in | D9 |
| ETH_RXERR | in | C10 |
| ETH_RXD[0] | in | C11 |
| ETH_RXD[1] | in | D10 |
| ETH_TXEN | out | B9 |
| ETH_TXD[0] | out | A10 |
| ETH_TXD[1] | out | A8 |
| ETH_REFCLK | out | D5 |
| ETH_INTN | in | B8 |

全部为 LVCMOS33。证据：<code>Camera_Ethernet_Top.sv:9-25</code>；<code>nexys_a7_ethernet.xdc:4-19</code>。

## ready/valid/last 统一规则

1. transfer只在 <code>valid && ready</code>成立。
2. source一旦拉高valid，在transfer前必须保持valid、data和last。
3. last属于当前data beat，不是独立事件。
4. <code>released</code>和Frame Adapter状态转换都必须使用真实末beat握手。
5. <code>tx_fifo_good_frame</code>是状态pulse，不参与AXIS握手，也不是线上完成标志。


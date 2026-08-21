# 06 MII/RMII Bridge

## 当前实现

工程没有实例化 Vivado <code>mii_to_rmii</code> IP。当前使用本地库：

<code>prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main/RTL/rmii_phy_if.v</code>

外层 <code>Ethernet_Mii_Rmii_Bridge</code>只做扁平端口映射和 reset跨域处理；同库的 <code>smii_phy_if.v</code>未使用。证据：<code>Ethernet_Mii_Rmii_Bridge.sv:5-75</code>。

这与早期“优先使用 Vivado IP Catalog mii_to_rmii”的要求不一致，必须作为已知偏差保留，直到用户确认本地 bridge可作为正式方案。

## 速率和位宽

| 接口 | 数据位宽 | 时钟 | 每个 byte |
|---|---:|---:|---:|
| MII | 4 bit | 25 MHz（100M模式） | 2 周期 |
| RMII | 2 bit | 50 MHz | 4 周期 |

两者净数据率均为100 Mbit/s。顶层固定 <code>mode_speed_100=1</code>；本地 core在该模式每个50 MHz动作，生成翻转的 MII TX/RX clock。

## TX 转换

~~~mermaid
sequenceDiagram
    participant MAC as Taxi MII @25 MHz
    participant B as rmii_phy_if @50 MHz
    participant PHY as RMII PHY

    MAC->>B: mii_txd[3:0], tx_en, tx_er
    Note over B: 在一个 MII byte/nibble窗口锁存4 bit
    B->>PHY: rmii_txd[1:0]（低 dibit）
    B->>PHY: rmii_txd[1:0]（高 dibit）
    Note over PHY: 每个4-bit MII nibble拆为两个2-bit RMII周期
~~~

core在 <code>mac_mii_txc</code>相位上先输出 <code>mac_mii_txd[1:0]</code>，保存 <code>[3:2]</code>供下一50 MHz周期输出；<code>mac_mii_txer</code>时改送 <code>4'b1010</code>编码。输出再经过一级 RMII寄存器到 <code>phy_rmii_txd/txen</code>。证据：<code>rmii_phy_if.v:266-305</code>。

## RX 转换

虽然首阶段不消费 RX AXIS，bridge仍把 <code>ETH_CRSDV</code>、<code>ETH_RXERR</code>、<code>ETH_RXD[1:0]</code>组合为4-bit MII RX信号送入 Taxi。RX source由 wrapper保持 <code>tready=1</code>以避免阻塞。证据：<code>rmii_phy_if.v:93-244</code>；<code>Taxi_Ethernet_Subsystem.sv:80-84</code>。

## 时钟

Clock Wizard实际配置：

- <code>rmii_ref_clk</code>：50.000 MHz，0°
- <code>phy_ref_clk</code>：50.000 MHz，45°
- <code>PRIM_SOURCE=Global_buffer</code>

后者连接 <code>ETH_REFCLK</code>，前者驱动 converter。post-route clock summary确认这两个 generated clock分别为20 ns周期，PHY clock波形相对移动2.5 ns。证据：<code>ethernet_clk_wiz.xci</code>；<code>post_route_timing_summary.rpt:163-168</code>。

## reset

1. <code>CPU_RESETN=0</code>或 Clock Wizard未锁定：<code>phy_ready=0</code>、<code>ETH_RSTN=0</code>。
2. 锁定后计数约10.49 ms，释放外部 PHY reset。
3. Bridge收到100 MHz域 <code>logic_rst</code>，在50 MHz域异步 assert、四级同步 deassert。
4. <code>rmii_phy_if</code>再生成 MII RX/TX reset shift registers。
5. Taxi也把 <code>mac_rst</code>同步到自身MII域。

## 管脚

<code>nexys_a7_ethernet.xdc</code>为 CLK100MHZ、CPU_RESETN和全部12个ETH顶层信号位设置了 PACKAGE_PIN与LVCMOS33，ETH pin号与本地 <code>Nexys-A7-50T-Master.xdc</code>对应项一致。

物理 pin约束完整不等于接口时序约束完整：当前 methodology仍报告 CPU_RESETN input delay和 ETH_RSTN output delay缺失；详细见 [08_vivado_build_and_reports.md](08_vivado_build_and_reports.md)。

## 验证状态

- wrapper+bridge可展开：PASS。
- 固定源仿真看到 RMII TX activity：PASS（活动级）。
- dibit顺序、线上完整帧、FCS、IFG：PENDING。
- PHY link LED与100M协商：PENDING。

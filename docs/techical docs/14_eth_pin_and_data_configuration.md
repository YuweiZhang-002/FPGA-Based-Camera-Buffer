# 14 Ethernet 引脚与数据配置

## 事实来源范围

本文只整理当前仓库可直接核实的配置，事实优先级为：当前 RTL/XDC/XCI/BD > 当前 Vivado 报告与 ILA/PCAP > 当前仿真与日志 > 旧文档。主要证据为：

- 活动顶层：<code>../../prg_cam.srcs/sources_1/new/Camera_Ethernet_Top.sv</code>
- Frame Adapter与扁平wrapper：<code>Ethernet_Frame_Adapter.sv</code>、<code>Taxi_Ethernet_Subsystem.sv</code>
- MII/RMII wrapper与本地core：<code>Ethernet_Mii_Rmii_Bridge.sv</code>、<code>lib/FPGA-RMII-SMII-main/RTL/rmii_phy_if.v</code>
- Taxi入口及闭包：<code>lib/taxi-master/eth/rtl/taxi_eth_mac_mii_fifo.f</code>、<code>../taxi_compile_manifest.txt</code>
- 活动约束和本地Master XDC：<code>../../prg_cam.srcs/constrs_1/new/nexys_a7_ethernet.xdc</code>、<code>../../prg_cam.srcs/constrs_1/Nexys-A7-50T-Master.xdc</code>
- Clock Wizard配置：<code>../../prg_cam.srcs/sources_1/ip/ethernet_clk_wiz/ethernet_clk_wiz.xci</code>
- 当前硬件证据：<code>../../build/ethernet_ila/frame_handshake_capture.csv</code>、<code>../../build/ethernet_ila/wireshark_fixed_1000.pcapng</code>

Taxi example目录和各板卡README已扫描，但它们不属于Nexys A7活动层次，不作为本页引脚或时序参数证据。

## 未确认项

- 仓库没有Nexys A7原理图或PHY数据手册，不能从本地文件确认RJ45磁性器件、差分线、板上测试点或PHY内部strap电阻值。
- <code>PACKAGE_PIN D5/B3/B9/A10/A8</code>是FPGA封装管脚名称，不是Pmod插座位置；仓库没有证据允许把它们解释为JA/JB测试点。
- Master XDC中的JA/JB模板仍为注释，但活动XDC已经把JA1..JA4、JA7..JA10映射为<code>GPIO[0:7]</code>，JB1映射为<code>GPIO[8]/PCLK</code>，JB7映射为<code>GPIO[9]/HREF</code>；这10根线当前都是顶层输入，尚未接入Camera_Pipeline。
- 当前没有ETH_REFCLK和ETH_RSTN的示波器截图。链路和PCAP证明它们在当前实现中足以建立链路，但不等价于独立电气测量。
- RMII TX已增加ODDR转发时钟、下降沿IOB输出寄存器和<code>set_output_delay</code>；post-route外部TX setup/hold均为正。RX <code>set_input_delay</code>、板级走线偏差、DRIVE/SLEW和示波器电气测量仍未完成。
- MDIO管理、PHY寄存器读取和完整RX协议栈尚未实现。
- Byte_FIFO已经位于当前固定帧活动链中；Camera_Pipeline尚未实例化，GPIO输入也尚未消费。

## 1. 当前活动层次

<code>prg_cam.xpr</code>的综合顶层为<code>Camera_Ethernet_Top</code>。<code>design_1.bd</code>的<code>design_tree</code>为空，因此当前Ethernet链不经过BD wrapper。

~~~mermaid
flowchart LR
    FG["Fixed_Packet_Generator\n当前活动源"] --> BF["Byte_FIFO\n9-bit {last,data}"]
    BF --> AD["Ethernet_Frame_Adapter"]
    AD --> WR["Taxi_Ethernet_Subsystem\nflat ports"]
    WR -->|"MII 4 bit / 25 MHz"| BR["Ethernet_Mii_Rmii_Bridge"]
    BR -->|"RMII 2 bit / 50 MHz"| PHY["板载PHY / ETH_* pins"]
    PHY --> RJ["RJ45到PC"]
    CAM["Camera_Pipeline\n尚未实例化"] -. "未来替换固定写入端" .-> BF
~~~

当前顶层参数<code>USE_BYTE_FIFO_PATH=1</code>，固定发生器先写入<code>Byte_FIFO</code>，FIFO输出再驱动Adapter；参数为0时才恢复直通诊断路径。固定源经Byte_FIFO的仿真、ILA和PCAP已有证据；真实Camera和RX验收仍为PENDING。

## 2. JA与JB引脚

以下封装管脚先由本地<code>Nexys-A7-50T-Master.xdc</code>模板定位，再由活动<code>nexys_a7_ethernet.xdc</code>与顶层<code>GPIO[9:0]</code>核实。只列活动使用的10根线；其余JB管脚仍未启用。

| Pmod位置 | 顶层端口 | PACKAGE_PIN | IOSTANDARD | 当前方向/用途 |
|---|---|---|---|---|
| JA1 | GPIO[0] | C17 | LVCMOS33 | input / D0 |
| JA2 | GPIO[1] | D18 | LVCMOS33 | input / D1 |
| JA3 | GPIO[2] | E18 | LVCMOS33 | input / D2 |
| JA4 | GPIO[3] | G17 | LVCMOS33 | input / D3 |
| JA7 | GPIO[4] | D17 | LVCMOS33 | input / D4 |
| JA8 | GPIO[5] | E17 | LVCMOS33 | input / D5 |
| JA9 | GPIO[6] | F18 | LVCMOS33 | input / D6 |
| JA10 | GPIO[7] | G18 | LVCMOS33 | input / D7 |
| JB1 | GPIO[8] | D14 | LVCMOS33 | input / PCLK |
| JB7 | GPIO[9] | E16 | LVCMOS33 | input / HREF |

结论：JA/JB现在是相机侧输入管脚，不是Ethernet测量输出；顶层尚未使用这些输入。若要把内部ETH信号镜像到Pmod，必须另增输出端口和约束并重新实现，不能复用上述相机输入定义。

## 3. Clock、Reset与PHY引脚

方向以<code>Camera_Ethernet_Top</code>为视角，PACKAGE_PIN和IOSTANDARD来自活动<code>nexys_a7_ethernet.xdc</code>。

| 顶层端口 | 方向/宽度 | PACKAGE_PIN | IOSTANDARD | RTL连接或常量 | 当前用途 |
|---|---|---|---|---|---|
| CLK100MHZ | in 1 | E3 | LVCMOS33 | IBUF后分到logic BUFG与Clock Wizard | 100 MHz系统输入 |
| CPU_RESETN | in 1 | C12 | LVCMOS33 | 低有效按钮；Clock Wizard端接<code>~CPU_RESETN</code> | 全局启动reset请求 |
| ETH_MDC | out 1 | C9 | LVCMOS33 | 固定0 | MDIO时钟未实现 |
| ETH_MDIO | inout 1 | A9 | LVCMOS33 | 高阻Z | MDIO数据未实现 |
| ETH_RSTN | out 1 | B3 | LVCMOS33 | <code>phy_ready</code> | 外部PHY低有效reset |
| ETH_CRSDV | in 1 | D9 | LVCMOS33 | 进入RMII RX转换 | carrier/RX data valid |
| ETH_RXERR | in 1 | C10 | LVCMOS33 | 进入RMII RX转换 | RX error |
| ETH_RXD[0] | in 1 | C11 | LVCMOS33 | 进入RMII RX转换 | RMII RX dibit bit0 |
| ETH_RXD[1] | in 1 | D10 | LVCMOS33 | 进入RMII RX转换 | RMII RX dibit bit1 |
| ETH_TXEN | out 1 | B9 | LVCMOS33 | <code>rmii_tx_en_dbg</code>经下降沿IOB寄存器 | RMII TX enable |
| ETH_TXD[0] | out 1 | A10 | LVCMOS33 | <code>rmii_txd_dbg[0]</code>经下降沿IOB寄存器 | RMII TX dibit bit0 |
| ETH_TXD[1] | out 1 | A8 | LVCMOS33 | <code>rmii_txd_dbg[1]</code>经下降沿IOB寄存器 | RMII TX dibit bit1 |
| ETH_REFCLK | out 1 | D5 | LVCMOS33 | <code>phy_ref_clk</code>经ODDR转发 | 提供给PHY的50 MHz参考时钟 |
| ETH_INTN | in 1 | B8 | LVCMOS33 | 当前只归入unused表达式 | PHY中断，未处理 |

活动XDC中的12个ETH管脚与本地Master XDC的“SMSC Ethernet PHY”段逐项一致。这里能证明FPGA与板载PHY之间的数字RMII/管理信号分配；RJ45铜缆差分对由PHY连接，不是FPGA顶层端口，Master XDC也没有RJ45差分对条目。

## 4. 时钟配置

### 4.1 XDC时钟

外部时钟约束为：

~~~tcl
create_clock -add -name sys_clk_pin -period 10.00 \
    -waveform {0 5} [get_ports {CLK100MHZ}]
~~~

活动XDC还对综合后实际存在的converter寄存器建立两个/2 generated clock：

~~~tcl
create_generated_clock -name mii_tx_clk \
    -source [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_txc_reg/C}] \
    -divide_by 2 \
    [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_txc_reg/Q}]

create_generated_clock -name mii_rx_clk \
    -source [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_rxc_reg/C}] \
    -divide_by 2 \
    [get_pins {u_ethernet_mii_rmii_bridge/u_rmii_phy_if/mac_mii_rxc_reg/Q}]
~~~

### 4.2 Clock Wizard实际配置

| XCI端口 | 方向 | 配置 | 连接对象 |
|---|---|---|---|
| sys_clk | in | 100 MHz，<code>PRIM_SOURCE=Global_buffer</code> | 顶层IBUF输出 |
| reset | in | <code>RESET_TYPE=ACTIVE_HIGH</code> | <code>~CPU_RESETN</code> |
| locked | out | MMCM lock | PHY reset计数器 |
| rmii_ref_clk | out | 50.000 MHz，0°，BUFG | <code>rmii_phy_if</code> converter |
| phy_ref_clk | out | 50.000 MHz，+45°，BUFG | <code>ETH_REFCLK</code> |

50 MHz的45°等于2.5 ns相移。当前实现报告确认100/50/50/25 MHz时钟网络存在；尚未通过示波器单独验证D5上的幅度、占空比和相位。

### 4.3 Reset极性和顺序

~~~mermaid
sequenceDiagram
    participant BTN as CPU_RESETN
    participant CW as Clock Wizard
    participant TOP as 20-bit counter
    participant PHY as ETH_RSTN
    participant BR as RMII bridge
    participant MAC as Taxi MAC/FIFO

    BTN->>CW: CPU_RESETN=0时reset=1
    CW-->>TOP: locked=0
    TOP->>PHY: ETH_RSTN=0
    CW-->>TOP: locked=1
    Note over TOP: 100 MHz计满20 bit，约10.49 ms
    TOP->>PHY: ETH_RSTN=1
    TOP->>BR: logic_rst=0请求
    Note over BR: 50 MHz域异步assert、4级同步release
    BR-->>MAC: 生成MII TX/RX clock与reset
~~~

| 对象 | 有效极性 | 证据 |
|---|---|---|
| CPU_RESETN | 低有效 | 顶层条件<code>if (!CPU_RESETN)</code> |
| Clock Wizard reset | 高有效 | XCI <code>RESET_TYPE=ACTIVE_HIGH</code>，顶层反相连接 |
| logic_rst/mac_rst | 高有效 | <code>logic_rst=~phy_ready</code> |
| Bridge rst | 高有效 | wrapper端口和<code>posedge rst</code>同步器 |
| rmii_phy_if.rstn_async | 低有效 | core端口和<code>negedge rstn_async</code> |
| ETH_RSTN | 低有效 | 顶层注释与<code>ETH_RSTN=phy_ready</code> |

## 5. AXI-Stream、MII和RMII信号

### 5.1 Byte FIFO与Frame Adapter

| 信号 | 方向 | 位宽 | 时钟域 | reset/保持规则 |
|---|---|---:|---|---|
| Byte_FIFO.in_data | in | 9 | sys_clk/100 MHz | <code>{packet_last,data[7:0]}</code> |
| Byte_FIFO.in_valid/in_ready | in/out | 1/1 | sys_clk | 仅valid&&ready写入 |
| Byte_FIFO.out_data | out | 9 | sys_clk | stall时holding register保持 |
| packet_data | Adapter in | 8 | logic_clk/100 MHz | payload byte |
| packet_valid/packet_ready | in/out | 1/1 | logic_clk | HEADER期间ready=0；PAYLOAD期间ready=frame_ready |
| packet_last | in | 1 | logic_clk | 与第128个payload byte同拍 |
| frame_data | Adapter out | 8 | logic_clk | 14-byte header后接payload |
| frame_valid/frame_ready | out/in | 1/1 | logic_clk | 只有两者同为1才传输 |
| frame_last | out | 1 | logic_clk | 仅最后payload byte |

### 5.2 Taxi内部AXIS映射

| 扁平wrapper信号 | Taxi interface | 位宽/常量 |
|---|---|---|
| frame_data | <code>s_axis_tx.tdata</code> | 8 |
| frame_valid | <code>s_axis_tx.tvalid</code> | 1 |
| frame_ready | <code>s_axis_tx.tready</code> | 1 |
| frame_last | <code>s_axis_tx.tlast</code> | 1 |
| 常量 | tkeep/tstrb | 1/1 |
| 常量 | tuser/tid/tdest | 0/0/0 |

wrapper内部还声明96-bit TX completion、8-bit RX和16-bit statistics interface；三个未消费source的<code>tready</code>均固定为1。Taxi实例显式参数为<code>VENDOR="XILINX"</code>、<code>FAMILY="artix7"</code>、<code>STAT_EN=0</code>。本地<code>taxi_eth_mac_mii_fifo</code>没有<code>DATA_W</code>参数。

### 5.3 MII

方向以bridge为视角。

| 信号 | 方向/宽度 | 时钟域 | 来源/去向 |
|---|---|---|---|
| mii_tx_clk | bridge out 1 | 25 MHz，100M模式 | 给Taxi MII TX |
| mii_txd | bridge in 4 | mii_tx_clk | Taxi到bridge |
| mii_tx_en/mii_tx_er | bridge in 1/1 | mii_tx_clk | Taxi到bridge |
| mii_tx_rst | bridge out 1 | mii_tx_clk相关 | core生成给MAC的reset状态 |
| mii_rx_clk | bridge out 1 | 25 MHz，100M模式 | 给Taxi MII RX |
| mii_rxd | bridge out 4 | mii_rx_clk | bridge到Taxi |
| mii_rx_dv/mii_rx_er | bridge out 1/1 | mii_rx_clk | bridge到Taxi |
| mii_crs | bridge out 1 | RMII RX解析 | bridge到顶层内部 |
| mii_rx_rst | bridge out 1 | mii_rx_clk相关 | core生成给MAC的reset状态 |

### 5.4 RMII

| 信号 | 方向/宽度 | 时钟域 | 顶层对应 |
|---|---|---|---|
| rmii_ref_clk | bridge in 1 | 50 MHz，0° | Clock Wizard内部输出 |
| rmii_tx_en | bridge out 1 | 50 MHz | ETH_TXEN/B9 |
| rmii_txd | bridge out 2 | 50 MHz | ETH_TXD/A10,A8 |
| rmii_crs_dv | bridge in 1 | 50 MHz | ETH_CRSDV/D9 |
| rmii_rx_er | bridge in 1 | 50 MHz | ETH_RXERR/C10 |
| rmii_rxd | bridge in 2 | 50 MHz | ETH_RXD/C11,D10 |
| PHY CLKIN | top out 1 | 50 MHz，+45° | ETH_REFCLK/D5 |

100M模式固定<code>mode_speed_100=1</code>。core把每个4-bit MII nibble拆成两个2-bit RMII dibit；硬件ILA中按<code>phy_ref_clk=1</code>采样解码得到正确字节流。

## 6. 数据与帧格式

### 6.1 Camera packet和Byte FIFO word

Camera链定义每包128 byte。<code>Byte_Replacer</code>在目标Camera路径修改offset 4、9、126、127，其中126/127是camera packet内部CRC-16；<code>Byte_FIFO</code>按9-bit <code>{last,data}</code>保存。当前固定发生器产生<code>00..7F</code>并在<code>7F</code>标记last，再经过Byte_FIFO；Camera和Byte_Replacer不在活动top中。

### 6.2 Frame Adapter输出

| Offset | 长度 | 内容 | 生成者 |
|---:|---:|---|---|
| 0..5 | 6 | FF FF FF FF FF FF | Frame Adapter |
| 6..11 | 6 | 02 00 00 00 00 02 | Frame Adapter |
| 12..13 | 2 | 88 B5 | Frame Adapter |
| 14..141 | 128 | 当前00..7F；未来为Camera packet | 当前固定源经Byte_FIFO |

Frame Adapter输出142 byte并在offset 141置<code>frame_last</code>。它不生成preamble、SFD、padding、FCS或IFG。

### 6.3 Taxi MAC输出

| 区域 | 长度 | 生成者 | 当前固定帧结果 |
|---|---:|---|---|
| Preamble | 7 | Taxi MAC | 55×7，硬件ILA PASS |
| SFD | 1 | Taxi MAC | D5，硬件ILA PASS |
| Adapter frame | 142 | Adapter+payload源 | header和00..7F，硬件ILA/PCAP PASS |
| Padding | 条件性 | Taxi MAC | 当前142-byte输入不需要 |
| FCS | 4 | Taxi MAC CRC-32 | 6F 0D 02 4D，ILA独立CRC复算PASS |
| IFG | 12 byte-times | Taxi MAC，<code>cfg_tx_ifg=12</code> | 48个RMII周期，ILA PASS |

线上从preamble到FCS共154 byte，另有12 byte-times IFG；PC网卡当前剥离preamble和FCS，PCAP显示每帧142 byte。

## 7. 已验证配置

| 项目 | 状态 | 当前证据 |
|---|---|---|
| 活动顶层和空BD关系 | PASS | XPR TopModule和空<code>design_tree</code> |
| ETH PACKAGE_PIN/IOSTANDARD | PASS | 活动XDC与Master XDC逐项一致 |
| Taxi本地.f闭包 | PASS | 8个.f、26个RTL、16个remap、missing=0 |
| 扁平wrapper和SV interface边界 | PASS | wrapper源码及xvlog/xelab |
| 100/50/50/25 MHz数字时钟网络 | PASS | XCI和实现时序报告 |
| Frame header与TLAST | PASS | Frame Adapter TB和硬件ILA |
| RMII TXEN/TXD活动 | PASS | 4096点硬件ILA |
| Preamble/SFD/dibit/FCS/IFG | PASS（当前固定帧） | 两个完整硬件RMII burst解码 |
| PHY link与100M数据通道 | PASS（当前固定帧） | PC实际收到0x88B5帧 |
| Wireshark固定payload | PASS | 1000帧PCAP完全一致，142 byte、00..7F |
| 硬件underflow/overflow | PASS（采样窗口） | ILA两信号均未置位 |
| 固定源→Byte_FIFO→Adapter | PASS | <code>tb_Byte_FIFO_Ethernet_Source</code>五帧回归、活动top和硬件ILA/PCAP |
| ODDR/IOB与RMII TX output delay | PASS（post-route） | <code>eth_refclk_out</code>路径setup +5.288 ns、hold +8.048 ns |

最新ODDR/IOB非ILA实现为WNS +0.492 ns、WHS +0.053 ns、19条DRC warning；1000帧PCAP持续0.013171 s，平均约75 kframe/s。PCAP与旧诊断bitstream对应；ODDR/IOB修改后的新bitstream尚未生成和上板，因此不得把两组证据合并成一次实现。

## 8. 尚未验证或未完成配置

| 项目 | 状态 | 缺失证据或风险 |
|---|---|---|
| JA/JB相机输入电气实测 | PENDING | 管脚和方向已配置，但GPIO尚未接入Camera逻辑 |
| RJ45差分对和板上测试点 | UNKNOWN | 仓库无原理图/测试点表 |
| ETH_REFCLK物理相位/幅度 | PENDING | 无示波器记录 |
| ETH_RSTN精确波形 | PENDING | 无示波器记录；仅功能结果间接证明释放 |
| RMII TX output timing | PASS WITH WARNINGS | 约束已生效且余量为正；methodology仍对TXD/TXEN报告泛化TIMING-18，需书面处置 |
| RMII RX input timing | PENDING | 尚无<code>set_input_delay</code>和RX验收 |
| CFGBVS/CONFIG_VOLTAGE | OPEN WARNING | DRC仍报告CFGBVS-1 |
| Taxi内部IOB属性 | OPEN WARNING | bridge使MII寄存器不直连物理IO |
| Taxi BRAM异步控制 | OPEN WARNING | REQP-1839/1840 |
| MDIO与PHY寄存器 | NOT IMPLEMENTED | MDC=0、MDIO=Z |
| RX功能和错误处理 | NOT ACCEPTED | RX接口虽连接并防堵塞，但无协议验收 |
| Byte_FIFO确定性硬件链 | PASS（固定源） | 活动top默认<code>USE_BYTE_FIFO_PATH=1</code>；ILA/PCAP只覆盖固定payload |
| Camera-to-Ethernet | PENDING | Camera_Pipeline未实例化到活动top |
| 两次clean build | PENDING | 尚无两次独立可追溯构建记录 |

## 9. 部署检查清单

- [ ] 确认目标器件仍为<code>xc7a50ticsg324-1L</code>，top仍为<code>Camera_Ethernet_Top</code>。
- [ ] 确认活动XDC使用E3、C12、上述12个ETH管脚以及10个相机GPIO输入；没有把JA/JB误当作Ethernet管脚。
- [ ] 确认Clock Wizard reset为高有效，顶层使用<code>~CPU_RESETN</code>。
- [ ] 确认<code>rmii_ref_clk=50 MHz/0°</code>只驱动converter，<code>phy_ref_clk=50 MHz/+45°</code>驱动ETH_REFCLK。
- [ ] 确认ETH_RSTN在MMCM lock后约10.49 ms才释放。
- [ ] 确认<code>mode_speed_100=1</code>，MII为4-bit/25 MHz，RMII为2-bit/50 MHz。
- [ ] 确认Frame Adapter只生成14-byte header和128-byte payload，不重复生成FCS。
- [ ] 确认Taxi生成preamble、SFD、必要padding、CRC-32 FCS和IFG。
- [ ] 确认Wireshark使用<code>eth.type == 0x88b5</code>，不要写成<code>0xb588</code>。
- [x] 固定源已经通过Byte_FIFO；下一阶段才把写入端切为真实Camera。
- [ ] 生成并上板ODDR/IOB修改后的新bitstream，重新保存配对ILA证据和PCAP。
- [ ] 未补齐RMII RX时序、methodology/DRC处置和两次clean build前，保持“PASS WITH WARNINGS”而不是clean sign-off。

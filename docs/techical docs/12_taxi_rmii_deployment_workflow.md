# 12 Taxi/RMII 部署工作流

## 1. 目的、边界与当前状态

本文是 Nexys A7-50T 上 Taxi MII MAC 到 RMII PHY 的部署手册。它描述当前本地工程、后续分阶段接入方法、每阶段风险及回退条件，不表示尚未执行的硬件步骤已经完成。

当前基线必须保持为：

| 层级 | 状态 |
|---|---|
| Digital implementation | **PASS WITH WARNINGS** |
| Hardware Ethernet TX | **PENDING** |
| Full Camera-to-Ethernet | **PENDING** |

“Digital implementation PASS WITH WARNINGS”仅说明当前固定帧顶层已经完成布局布线，当前已分析路径无负 slack，且没有 DRC Error/Critical Warning；仍存在17条DRC Warning和不完整的外部I/O时序约束。它不等价于bitstream、PHY link或Wireshark通过。

主证据：

- [工程文件](../../prg_cam.xpr)
- [当前活动顶层](../../prg_cam.srcs/sources_1/new/Camera_Ethernet_Top.sv)
- [Taxi递归清单](../taxi_compile_manifest.txt)
- [活动编译顺序](../ethernet_bringup_compile_order.rpt)
- [post-route时序](../reports/ethernet_bringup/post_route_timing_summary.rpt)
- [final DRC](../reports/ethernet_bringup/final_drc.rpt)

## 2. 当前实际文件与活动层次

### 2.1 关键文件

| 功能 | 当前实际路径 |
|---|---|
| Camera数据链 | <code>prg_cam.srcs/sources_1/new/Camera_Pipeline.v</code>及Camera_Capture、Line_Buffer、Arbitration、Byte_Replacer、Byte_FIFO |
| 固定帧源 | <code>prg_cam.srcs/sources_1/new/Fixed_Packet_Generator.sv</code> |
| Ethernet header适配 | <code>prg_cam.srcs/sources_1/new/Ethernet_Frame_Adapter.sv</code> |
| Taxi扁平wrapper | <code>prg_cam.srcs/sources_1/new/Taxi_Ethernet_Subsystem.sv</code> |
| MII/RMII wrapper | <code>prg_cam.srcs/sources_1/new/Ethernet_Mii_Rmii_Bridge.sv</code> |
| RMII转换core | <code>prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main/RTL/rmii_phy_if.v</code> |
| Taxi根目录 | <code>prg_cam.srcs/sources_1/lib/taxi-master</code> |
| Clock Wizard | <code>prg_cam.srcs/sources_1/ip/ethernet_clk_wiz/ethernet_clk_wiz.xci</code> |
| 活动Ethernet XDC | <code>prg_cam.srcs/constrs_1/new/nexys_a7_ethernet.xdc</code> |
| Digilent master XDC | <code>prg_cam.srcs/constrs_1/Nexys-A7-50T-Master.xdc</code> |

### 2.2 当前活动层次

<code>prg_cam.xpr</code>把 <code>Camera_Ethernet_Top</code>设为综合顶层。该顶层当前实例化固定发生器，没有实例化 <code>Camera_Pipeline</code>或 <code>design_1_wrapper</code>。<code>design_1.bd</code>的当前 <code>design_tree</code>为空。

~~~mermaid
flowchart LR
    FG["Fixed_Packet_Generator\n当前活动源"] --> FA["Ethernet_Frame_Adapter"]
    FA --> TW["Taxi_Ethernet_Subsystem"]
    TW -->|"MII 4-bit @ 25 MHz"| BR["Ethernet_Mii_Rmii_Bridge"]
    BR -->|"RMII 2-bit @ 50 MHz"| PHY["Nexys A7 ETH_*"]

    CP["Camera_Pipeline\n4×Capture→4×LB→Arb→Replacer→Byte_FIFO"] -. "尚未接入活动顶层" .-> FA
~~~

部署时必须先保留这条固定帧基线，只有它通过PC侧捕获后，才允许用 Byte FIFO 或 Camera Pipeline替换数据源。

## 3. Taxi本地 .f 依赖与Vivado加载

### 3.1 入口和闭包

唯一入口为：

<code>prg_cam.srcs/sources_1/lib/taxi-master/eth/rtl/taxi_eth_mac_mii_fifo.f</code>

当前递归结果：

- 8个filelist；
- 26个唯一SystemVerilog RTL；
- 16条本地路径重映射；
- <code>MISSING_OR_AMBIGUOUS (0)</code>；
- Vivado missing instances为空。

8个filelist为：

1. <code>axis/rtl/taxi_axis_arb_mux.f</code>
2. <code>axis/rtl/taxi_axis_async_fifo.f</code>
3. <code>axis/rtl/taxi_axis_async_fifo_adapter.f</code>
4. <code>eth/rtl/taxi_eth_mac_1g.f</code>
5. <code>eth/rtl/taxi_eth_mac_mii.f</code>
6. <code>eth/rtl/taxi_eth_mac_mii_fifo.f</code>
7. <code>eth/rtl/taxi_eth_mac_stats.f</code>
8. <code>eth/rtl/taxi_mii_phy_if.f</code>

26个RTL按目录分布为：axis 8个、eth 11个、io 1个、lfsr 1个、prim 2个、stats 1个、sync 2个。完整路径以 [taxi_compile_manifest.txt](../taxi_compile_manifest.txt) 为准。

### 3.2 重映射

上游filelist中的若干 <code>../lib/taxi/src/...</code>在当前提取目录中失效。[add_taxi_sources.tcl](../../scripts/add_taxi_sources.tcl)的处理规则是：

1. 先以当前 <code>.f</code>所在目录解析相对路径；
2. 路径无效时，只在本地 <code>sources_1/lib</code>按basename搜索；
3. 唯一命中则记录remap；
4. 多命中或零命中均停止；
5. 完整闭包解析成功后才加入Vivado。

不得递归加载整个 <code>taxi-master</code>，因为example和TB中存在大量同名top/module。不得修改上游原始 <code>.f</code>来掩盖本地目录差异。

### 3.3 Vivado加载

脚本使用 <code>add_files -norecurse</code>只加入26-file闭包，并把所有 <code>.sv</code>设置为SystemVerilog。随后执行：

~~~tcl
update_compile_order -fileset sources_1
report_compile_order -used_in synthesis
report_compile_order -used_in synthesis -missing_instances
~~~

加载门槛：

- dependency missing/ambiguous = 0；
- duplicate module/interface = 0；
- missing instances报告为空；
- Taxi standalone xvlog/xelab通过。

Taxi目录没有嵌套Git元数据；指定commit的一致性目前依赖既有本地manifest校验记录，而不是目录内可直接读取的commit对象。

## 4. Taxi扁平wrapper与AXIS映射

<code>Taxi_Ethernet_Subsystem</code>对外不暴露SystemVerilog interface。四个 <code>taxi_axis_if</code>只存在于wrapper内部：

| interface | DATA_W | 用途 | 处理 |
|---|---:|---|---|
| s_axis_tx | 8 | Ethernet frame输入 | 映射frame_* |
| m_axis_tx_cpl | 96 | TX completion | tready=1 |
| m_axis_rx | 8 | RX输出 | tready=1 |
| m_axis_stat | 16 | statistics | tready=1 |

输入映射：

| Frame Adapter | Taxi AXIS |
|---|---|
| frame_data[7:0] | tdata[7:0] |
| frame_valid | tvalid |
| frame_ready | tready |
| frame_last | tlast |
| — | tkeep=1、tstrb=1、tuser=0、tid=0、tdest=0 |

Taxi实例当前参数为 <code>VENDOR="XILINX"</code>、<code>FAMILY="artix7"</code>、<code>STAT_EN=0</code>。本地 <code>taxi_eth_mac_mii_fifo</code>没有 <code>DATA_W</code>参数，部署时不得凭旧要求猜测添加。

## 5. Byte FIFO到Taxi的协议

目标连接为：

~~~mermaid
flowchart LR
    BF["Byte_FIFO\n{packet_last, packet_data}"] -->|"packet_data/valid/ready/last"| FA["Frame Adapter"]
    FA -->|"frame_data/valid/ready/last"| TX["Taxi TX AXIS"]
~~~

- Byte FIFO在同一个9-bit word中保存last和data。
- Frame Adapter的HEADER状态固定 <code>packet_ready=0</code>。
- Header 14 byte全部被Taxi接受后进入PAYLOAD。
- PAYLOAD状态 <code>packet_ready=frame_ready</code>。
- 最后一byte必须完成 <code>valid && ready && last</code>，Adapter才返回IDLE。
- 任何stall期间，source必须保持valid/data/last。

Frame Adapter生成的MAC输入为142 byte：广播DST、源地址02:00:00:00:00:02、EtherType 88B5、原128-byte payload。

## 6. Taxi TX FIFO、CDC与MAC运行

Taxi首先在100 MHz logic域把完整AXIS frame写入 <code>taxi_axis_async_fifo_adapter</code>。当前默认TX FIFO深度4096，<code>TX_FRAME_FIFO=1</code>；只有收到TLAST后才更新committed pointer。Gray pointer和同步器把完整帧从100 MHz域交给25 MHz MII TX域。

MAC发送顺序：

~~~mermaid
flowchart LR
    A["完整AXIS frame提交"] --> P["7×55 preamble"]
    P --> S["D5 SFD"]
    S --> H["14-byte Ethernet header"]
    H --> D["128-byte payload"]
    D --> PAD{"低于最小长度?"}
    PAD -- 否 --> F["CRC-32 FCS 4 byte"]
    PAD -- 是 --> Z["zero padding"]
    Z --> F
    F --> I["IFG 12 byte times"]
~~~

当前142-byte输入不需要padding。FCS使用32-bit多项式04C11DB7。<code>tx_fifo_good_frame</code>只表示完整帧在TX FIFO写侧被接受并提交；它不是MII发送完成、PHY发送完成或PC收到帧的证明。

## 7. MII到RMII连接

当前工程使用本地 <code>rmii_phy_if</code>，不是Vivado IP Catalog的 <code>mii_to_rmii</code>。

| Taxi MII | Bridge | Nexys A7 RMII |
|---|---|---|
| mii_tx_clk | bridge生成25 MHz | 内部 |
| mii_txd[3:0] | 每nibble拆成两个dibit | ETH_TXD[1:0] |
| mii_tx_en | 对齐并寄存 | ETH_TXEN |
| mii_tx_er | 转换为core错误编码 | 无独立RMII TXER pin |
| mii_rx_clk/rxd/dv/er | 由RMII输入重组 | ETH_CRSDV/RXERR/RXD |

顶层固定 <code>mode_speed_100=1</code>，对应MII 4-bit/25 MHz和RMII 2-bit/50 MHz，两侧净数据率均为100 Mbit/s。

## 8. 100 MHz到50 MHz时钟树

~~~mermaid
flowchart TD
    CLK["CLK100MHZ / E3"] --> IBUF["IBUF"]
    IBUF --> BUFG["BUFG → logic_clk 100 MHz"]
    IBUF --> CW["ethernet_clk_wiz\nPRIM_SOURCE=Global_buffer"]
    CW -->|"50 MHz, 0°"| RCLK["rmii_ref_clk → converter"]
    CW -->|"50 MHz, +45°"| PCLK["phy_ref_clk → ETH_REFCLK / D5"]
    RCLK --> DIV["rmii_phy_if toggle"]
    DIV -->|"25 MHz"| MTX["MII TX clock"]
~~~

Clock Wizard XCI的实际配置是：

- CLKOUT1：50.000 MHz、0°；
- CLKOUT2：50.000 MHz、45°；
- 45°在50 MHz下等于2.5 ns相移。

post-route clock summary确认logic 100 MHz、两个50 MHz生成时钟和25 MHz MII TX clock。

## 9. Reset与PHY释放顺序

~~~mermaid
sequenceDiagram
    participant BTN as CPU_RESETN
    participant CW as Clock Wizard
    participant TOP as 100 MHz reset counter
    participant PHY as External PHY
    participant BR as RMII bridge
    participant TX as Taxi MAC/FIFO

    BTN->>CW: reset when low
    CW-->>TOP: locked=0
    TOP->>PHY: ETH_RSTN=0
    CW-->>TOP: locked=1
    Note over TOP: 20-bit counter counts to all ones\nabout 10.49 ms at 100 MHz
    TOP->>PHY: ETH_RSTN=1
    TOP->>BR: logic_rst deassert request
    Note over BR: async assert, 4-stage sync release at 50 MHz
    BR-->>TX: MII clocks/reset
    Note over TX: Taxi synchronizes mac_rst in MII domains
~~~

部署检查顺序必须是：CLK100稳定 → MMCM locked → 等待约10.49 ms → ETH_RSTN释放 → bridge域reset同步释放 → Taxi开始接受/发送。不能仅看到 <code>clock_locked</code>就判定PHY可用。

## 10. XDC部署

活动XDC中的实际管脚：

| 信号 | pin | IOSTANDARD |
|---|---|---|
| CLK100MHZ | E3 | LVCMOS33 |
| CPU_RESETN | C12 | LVCMOS33 |
| ETH_MDC / ETH_MDIO / ETH_RSTN | C9 / A9 / B3 | LVCMOS33 |
| ETH_CRSDV / ETH_RXERR | D9 / C10 | LVCMOS33 |
| ETH_RXD[0] / [1] | C11 / D10 | LVCMOS33 |
| ETH_TXEN | B9 | LVCMOS33 |
| ETH_TXD[0] / [1] | A10 / A8 | LVCMOS33 |
| ETH_REFCLK / ETH_INTN | D5 / B8 | LVCMOS33 |

这些pin与本地Digilent master XDC对应项一致。部署时还必须处理：

- CFGBVS/CONFIG_VOLTAGE；
- CPU_RESETN和ETH_RSTN的TIMING-18；
- RMII外部输入/输出delay模型；
- Taxi内部MII寄存器经过RMII bridge后产生的IOB warning。

PACKAGE_PIN齐全只证明物理位置已指定，不证明RMII接口时序已经sign-off。

## 11. 分阶段接入、风险与回退

所有下面的“修改文件”都是后续阶段建议，不是本文生成时已经发生的修改。

### 阶段A：固定帧基线

- 当前源：<code>Fixed_Packet_Generator</code>，payload为00..7F。
- 修改文件：无；保持当前 <code>Camera_Ethernet_Top.sv</code>。
- 测试：Frame Adapter单元TB、Taxi/bridge展开、RMII scoreboard、综合/实现、板上clock/reset/link、Wireshark。
- 风险：当前端到端TB只检查RMII有活动，没有检查线上byte/FCS。
- 回退：保持当前HEAD和当前top；不引入Camera或旧BD。
- 晋级门槛：PC稳定收到88B5，payload逐byte等于00..7F，underflow/overflow为0。

### 阶段B：确定性数据经Byte_FIFO

- 目标：固定发生器先写9-bit <code>{last,data}</code> Byte FIFO，再由FIFO的packet接口驱动Frame Adapter。
- 计划修改：<code>Camera_Ethernet_Top.sv</code>；新增独立Byte FIFO→Adapter→Taxi/RMII testbench。不要修改Taxi核心。
- 测试：随机写/读stall、多帧、TLAST位置、最终FIFO level=0、RMII逐byte scoreboard。
- 风险：FIFO预取寄存器导致level判读少/多一项；last若未与data同word会错位。
- 回退：恢复固定发生器直接连接Frame Adapter的单个顶层commit；保留新增TB供回归。
- 晋级门槛：所有帧内容与阶段A一致，stall稳定，结束无积压。

### 阶段C：Camera Pipeline接入

- 目标：用 <code>Camera_Pipeline.packet_data/valid/ready/last</code>替换确定性源。Camera Pipeline内部已经包含Byte FIFO。
- 计划修改：<code>Camera_Ethernet_Top.sv</code>；新增Camera→Adapter→Taxi→RMII testbench；只有核对现有camera pin约束无冲突后才调整约束集。
- 测试：4路camera并发、round-robin、短包、drop、CRC-16、随机反压、RMII Ethernet CRC-32、PC侧序号连续性。
- 风险：camera pclk/href CDC、总输入带宽超过100M链路、Line Buffer溢出、Byte FIFO长期积压、camera和Ethernet XDC冲突。
- 回退：用参数或独立top恢复阶段B确定性源；不得删除Camera或Taxi文件。
- 晋级门槛：RTL scoreboard、实现报告、ILA和PC抓包同时通过。

### 阶段D：长期运行与旧层次处置

- 修改文件：仅在硬件成功和两次clean build后，才计划从活动层次断开旧AXI/DDR/DMA模块；先 <code>remove_files</code>但不删除磁盘文件。
- 测试：两次clean build、长时间抓包、四路序号/丢包统计、reset重连。
- 风险：误删仍被XPR、BD或checkpoint引用的旧文件。
- 回退：在删除前保留独立commit和待删清单；重新加入工程文件即可恢复。
- 晋级门槛：用户确认待删清单后，才允许独立commit删除磁盘文件。

## 12. 最终部署验收条件

部署只有在以下项目全部满足时才是完整PASS：

1. Taxi closure missing=0、重复定义=0、missing instances为空。
2. 单元和端到端RTL测试包含正常、stall、reset、边界、多帧、逐byte比较、TLAST和稳定性断言。
3. RMII scoreboard验证preamble、SFD、header、128-byte payload、CRC-32 FCS和IFG。
4. synthesis、place、route完成；WNS/WHS非负。
5. CDC无未处置问题；17条DRC Warning和外部I/O timing问题均已修复或形成获批豁免。
6. 两次clean build产生一致的设计配置和可追溯bitstream。
7. ETH_REFCLK、ETH_RSTN和PHY link在板上测量通过。
8. ILA确认 <code>tx_error_underflow=0</code>、<code>tx_fifo_overflow=0</code>。
9. Wireshark持续捕获 <code>eth.type == 0x88b5</code>，MAC地址和长度一致。
10. 固定源payload为00..7F；Camera阶段payload序号连续，所有drop均可由计数器解释。

截至本文生成时，第1项和部分第2/4项有PASS证据；硬件相关第6至10项仍为PENDING。


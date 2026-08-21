# 13 Vivado验证与验收规范

## 1. 状态口径

本规范把验证分为源码闭包、编译展开、RTL功能、数字实现、bitstream、板级PHY和PC捕获七层。任何较低层PASS都不能替代较高层证据。

当前总状态固定为：

| 层级 | 状态 | 当前证据边界 |
|---|---|---|
| Digital implementation | **PASS WITH WARNINGS** | 固定帧顶层route完成，已分析路径slack为正；仍有17条DRC Warning |
| Hardware Ethernet TX | **PENDING** | 无bitstream下载、link、ILA或pcap证据 |
| Full Camera-to-Ethernet | **PENDING** | 当前活动顶层仍使用固定发生器 |

<code>tx_fifo_good_frame</code>只能证明Taxi TX frame FIFO写侧完成一帧提交，不能作为MII/RMII线路发送完成标志。route PASS只能证明数字网表完成布线，不能作为Wireshark PASS。

## 2. Source、Dependency与Compile Gate

### 2.1 Source gate

检查：

- Taxi入口文件存在且唯一；
- 所有依赖只来自 <code>prg_cam.srcs/sources_1/lib</code>；
- 许可证和README保留；
- RMII bridge来自当前本地 <code>FPGA-RMII-SMII-main</code>；
- 当前top、XCI、XDC路径存在；
- 不把整个Taxi example/tb树加入Vivado。

PASS判据：所有路径可解析，无网络下载，无文件移动或删除。

### 2.2 Dependency gate

运行 [add_taxi_sources.tcl](../../scripts/add_taxi_sources.tcl)，核对 [taxi_compile_manifest.txt](../taxi_compile_manifest.txt)：

| 项目 | 期望 | 当前 |
|---|---:|---:|
| filelists | 8 | PASS：8 |
| unique RTL | 26 | PASS：26 |
| remaps | 16条可追踪唯一映射 | PASS：16 |
| missing/ambiguous | 0 | PASS：0 |
| duplicate module/interface | 0 | PASS |
| Vivado missing instances | 空 | PASS |

任何missing、ambiguous或duplicate均为立即FAIL，不得进入综合。

### 2.3 Compile与elaboration gate

最低命令链：

~~~powershell
xvlog.bat --incr --relax -prj .\scripts\taxi_mii_fifo_vlog.prj
xelab.bat --debug typical --relax tb_Taxi_Eth_Mac_Mii_Fifo_Elab -s tb_Taxi_Eth_Mac_Mii_Fifo_Elab_sim
xsim.bat tb_Taxi_Eth_Mac_Mii_Fifo_Elab_sim -runall
~~~

继续展开：

- <code>tb_Taxi_Rmii_Subsystem_Elab</code>；
- <code>tb_Fixed_Frame_Taxi_Rmii</code>；
- 最终Camera集成top。

当前Taxi standalone和Taxi+bridge展开均PASS，但两者不发送有效数据，只能判为elaboration PASS。

## 3. Unit Simulation规范

| DUT | 必须检查 | 当前结果 |
|---|---|---|
| Arbitration | round-robin、active grant锁定、released后清零、reset、timeout | PASS，但现有TB无timeout |
| Line_Buffer | reserve/commit/release/drop、数据、TLAST、stall stability、最终计数清零 | PARTIAL PASS；无data compare和stall |
| Byte_Replacer | offsets 4/9/126/127、CRC-16、stall不重复累计、异常last重同步 | 由Pipeline TB部分覆盖 |
| Byte_FIFO | 9-bit data/last、push/fetch/pop、wrap、full、simultaneous push/pop、最终level=0 | PENDING独立完整TB |
| Frame Adapter | header、payload、TLAST、header/payload/final stall、多帧 | PASS单帧；多帧PENDING |
| MII/RMII bridge | 4-bit/25 MHz到2-bit/50 MHz顺序、reset、速度模式 | 只有展开/活动证据 |

完整单元PASS要求每个TB：

1. 明确reset；
2. 正常路径和边界；
3. 自动scoreboard；
4. 明确handshake计数；
5. timeout；
6. 结束时没有无法解释的FIFO/slot积压；
7. 打印唯一PASS或以fatal结束。

## 4. Adapter→Taxi→RMII端到端仿真

当前 <code>tb_Fixed_Frame_Taxi_Rmii</code>产生重复00..7F payload，运行50.2 µs，检查RMII有活动、underflow/overflow未置位、TX FIFO写侧有good-frame。它没有解码RMII，因此当前只能判“活动级PASS”。

完整端到端TB必须加入：

- Frame Adapter输入scoreboard；
- Taxi AXIS握手计数；
- 随机和定向stall；
- RMII decoder；
- 线上frame scoreboard；
- FIFO写侧提交数、MAC起始数、RMII完成数分别计数；
- 仿真结束前等待所有相关FIFO排空。

~~~mermaid
flowchart LR
    GEN["00..7F / Camera source"] --> AD["Frame Adapter"]
    AD --> AXM["AXIS monitor"]
    AD --> TAXI["Taxi FIFO + MAC"]
    TAXI --> MII["MII monitor"]
    MII --> BR["RMII bridge"]
    BR --> RMON["RMII decoder"]
    AXM --> SB["Expected-frame queue"]
    RMON --> SB
    SB --> RESULT["byte/FCS/IFG PASS or FAIL"]
~~~

## 5. valid/ready/last与stall Assertion

### 5.1 通用规则

- transfer = valid && ready；
- valid拉高后，在transfer前不得撤销；
- stall = valid && !ready；
- stall期间data和last必须保持；
- last必须与最后一个data beat同拍；
-状态、byte index、CRC和FIFO read pointer只能在真实transfer时推进。

建议在testbench绑定以下等价SVA：

~~~systemverilog
assert property (@(posedge clk) disable iff (rst)
    valid && !ready |=> valid && $stable(data) && $stable(last));

assert property (@(posedge clk) disable iff (rst)
    last |-> valid);

assert property (@(posedge clk) disable iff (rst)
    state_advance |-> valid && ready);
~~~

Frame Adapter还需断言：

- HEADER状态 <code>packet_ready==0</code>；
- PAYLOAD状态 <code>packet_ready==frame_ready</code>；
- <code>frame_last</code>只在第128个payload byte；
- 最后byte stalled时 <code>frame_last</code>保持；
- 最后byte完成握手后下一帧才能进入HEADER。

## 6. RMII Dibit/Nibble/Byte Scoreboard

### 6.1 解码顺序

100M模式每个50 MHz RMII周期采样 <code>ETH_TXD[1:0]</code>：

1. <code>ETH_TXEN=1</code>时收集dibit；
2. 每2个dibit组合为1个MII nibble；
3. 每2个nibble组合为1 byte；
4. 保持本地core的低dibit/高dibit和低nibble/高nibble顺序；
5. <code>ETH_TXEN</code>下降时结束一帧；
6. 统计到下一次上升之间的IFG。

scoreboard不能仅比较TXEN脉冲或帧数；必须保存每个decoded byte并给出首个不匹配offset。

### 6.2 必查字段

| 区域 | 期望 |
|---|---|
| Preamble | 7 × 55 |
| SFD | D5 |
| Destination | FF FF FF FF FF FF |
| Source | 02 00 00 00 00 02 |
| EtherType | 88 B5 |
| Payload | 固定源00..7F；Camera阶段为对应128-byte packet |
| Padding | 当前142-byte MAC输入不应产生padding |
| FCS | 对DST至payload计算的Ethernet CRC-32 |
| IFG | 不少于12 byte times |

CRC-32必须与Camera packet内部offset 126/127的CRC-16分开计算。NIC可能在PC捕获时剥离FCS，但RTL RMII monitor必须直接验证FCS。

## 7. Synthesis、Implementation、Timing、CDC与DRC

推荐命令：

~~~powershell
vivado.bat -mode batch -nolog -nojournal -source .\scripts\check_project.tcl
vivado.bat -mode batch -nolog -nojournal -source .\scripts\synth_ethernet_bringup.tcl
vivado.bat -mode batch -nolog -nojournal -source .\scripts\implement_ethernet_bringup.tcl
~~~

必须保存：

- compile order和missing instances；
- methodology；
- CDC；
- DRC；
- utilization；
- route status；
- timing summary及unconstrained/check_timing部分；
- routed DCP；
-完整控制台日志。

当前固定源top的实现结果：

- 556/556 routable nets完成；
- routing errors=0；
- WNS=+3.202 ns；
- WHS=+0.053 ns；
- TNS=THS=0；
- CDC报告为 <code>All paths are Safely Timed</code>；
- 282 LUT、335 registers、1.5 BRAM tiles、1 MMCM、6 BUFGCTRL、0 DSP。

## 8. WNS与WHS解释

### WNS +3.202 ns

这是当前已约束setup路径中的最差正裕量。最差setup路径在100 MHz <code>sys_clk_pin</code>域，10 ns要求下仍有3.202 ns余量，因此当前corner/约束模型下没有setup failing endpoint。

它不表示所有外部RMII pin都具有3.202 ns裕量，也不覆盖缺失的input/output delay。

### WHS +0.053 ns

这是所有已分析hold路径的最小正裕量，只有53 ps。报告中该最差hold裕量位于 <code>mii_tx_clk</code>相关路径组。数值为正，所以当前实现hold PASS；但裕量很小，对约束变化、clock关系修改或布局变化敏感，clean build后必须重新确认。

结论：当前内部STA为PASS，但由于方法学和I/O约束warning，只能标记 **PASS WITH WARNINGS**。

## 9. 17条DRC Warning逐项分类

来源：[final_drc.rpt](../reports/ethernet_bringup/final_drc.rpt)。全部为OPEN，不得因为severity不是Error就忽略。

| # | Rule | 对象/原因 | 分类 | 验收处置 |
|---:|---|---|---|---|
| 1 | CFGBVS-1#1 | 未设置CFGBVS和CONFIG_VOLTAGE | 器件配置 | 修复或获得板级配置审查批准 |
| 2 | PLIO-6#1 | Taxi <code>phy_mii_tx_en_reg</code> IOB=TRUE但不直连IO | IOB拓扑 | 评审内部MII到RMII层次 |
| 3 | PLIO-6#2 | Taxi <code>phy_mii_tx_er_reg</code>同上 | IOB拓扑 | 同上 |
| 4 | PLIO-6#3 | Taxi <code>phy_mii_txd_reg[0]</code>同上 | IOB拓扑 | 同上 |
| 5 | PLIO-6#4 | Taxi <code>phy_mii_txd_reg[1]</code>同上 | IOB拓扑 | 同上 |
| 6 | PLIO-6#5 | Taxi <code>phy_mii_txd_reg[2]</code>同上 | IOB拓扑 | 同上 |
| 7 | PLIO-6#6 | Taxi <code>phy_mii_txd_reg[3]</code>同上 | IOB拓扑 | 同上 |
| 8 | REQP-1617#1 | <code>phy_mii_tx_en_reg</code>的IOB属性无直接IO连接 | IOB属性 | 移除/覆盖不适用属性或重构并复验 |
| 9 | REQP-1617#2 | <code>phy_mii_tx_er_reg</code>同上 | IOB属性 | 同上 |
| 10 | REQP-1617#3 | <code>phy_mii_txd_reg[0]</code>同上 | IOB属性 | 同上 |
| 11 | REQP-1617#4 | <code>phy_mii_txd_reg[1]</code>同上 | IOB属性 | 同上 |
| 12 | REQP-1617#5 | <code>phy_mii_txd_reg[2]</code>同上 | IOB属性 | 同上 |
| 13 | REQP-1617#6 | <code>phy_mii_txd_reg[3]</code>同上 | IOB属性 | 同上 |
| 14 | REQP-1839#1 | TX FIFO RAMB36 <code>mem_reg_0/ENARDEN</code>受异步reset寄存器影响 | BRAM reset | 评审reset释放与Taxi官方约束 |
| 15 | REQP-1839#2 | RAMB36 <code>mem_reg_0/WEA[0]</code>同类问题 | BRAM reset | 同上 |
| 16 | REQP-1840#1 | TX FIFO RAMB18 <code>mem_reg_1/ENARDEN</code>同类问题 | BRAM reset | 同上 |
| 17 | REQP-1840#2 | RAMB18 <code>mem_reg_1/WEA[0]</code>同类问题 | BRAM reset | 同上 |

另有2条methodology TIMING-18：CPU_RESETN缺input delay、ETH_RSTN缺output delay。RMII TX/RX外部时序也必须在最终sign-off中明确建模或书面豁免。

## 10. Bitstream Gate

当前状态：PENDING。

生成bitstream前必须：

1. source/dependency/compile/elaboration全部PASS；
2. 端到端RMII scoreboard PASS；
3. route/timing PASS；
4. 每条DRC/methodology warning有处置结论；
5. 顶层和XDC对应同一板卡；
6. 保存Git commit、Vivado版本、report时间和bitstream SHA-256。

要求进行两次独立clean build，并比较关键报告、top、part、约束集和bitstream可追溯信息。不能通过删除 <code>.runs</code>、<code>.cache</code>或 <code>prg_cam.gen</code>来掩盖依赖问题。

## 11. PHY Clock、Reset与Link Gate

板级检查：

| 项目 | 方法 | PASS判据 |
|---|---|---|
| CLK100MHZ | 示波器/工具时钟报告 | 100 MHz稳定 |
| ETH_REFCLK | 示波器 | 50 MHz且占空/幅度符合PHY要求 |
| Clock相位 | 设计/XCI和必要时测量 | converter 0°、PHY CLKIN +45° |
| ETH_RSTN | 示波器/ILA | MMCM锁定后约10.49 ms才释放 |
| MII TX clock | ILA/仿真 | 100M模式25 MHz |
| PHY link | LED和PC网卡状态 | 稳定link，记录协商速率 |

link LED PASS只证明PHY链路建立，不证明88B5帧内容正确。

## 12. ILA Gate

建议探针：

- Frame Adapter：frame_data、frame_valid、frame_ready、frame_last；
- Byte FIFO阶段：packet_data、packet_valid、packet_ready、packet_last、level；
- Taxi：tx_error_underflow、tx_fifo_overflow、tx_fifo_good_frame；
- MII：mii_txd、mii_tx_en、mii_tx_er、mii_tx_clk；
- RMII：ETH_TXD、ETH_TXEN、rmii_ref_clk；
- reset：clock_locked、logic_rst、ETH_RSTN。

PASS判据：

- stalled时data/valid/last稳定；
- frame最后byte只握手一次；
- underflow=0、overflow=0；
- FIFO提交pulse与输入完整帧一一对应；
- RMII activity与MAC发送时序对应。

ILA中的good-frame pulse仍不表示PC已收到。

## 13. Wireshark与Scapy Gate

Wireshark display filter：

<code>eth.type == 0x88b5</code>

固定帧阶段PASS判据：

- 持续收到帧；
- DST=ff:ff:ff:ff:ff:ff；
- SRC=02:00:00:00:00:02；
- EtherType=0x88b5；
- payload长度128；
- payload逐byte为00..7F；
- 无无法解释的丢帧或长度波动。

PC网卡可能剥离FCS，因此Wireshark帧长可能为142 byte而非146 byte；FCS应由RMII scoreboard补充验证。必须保存pcap、网卡名、驱动、协商速率、测试时长和帧统计。

## 14. Byte FIFO与Camera验收

### Byte FIFO阶段

- 输入、输出handshake计数相等；
- 每128次输出握手出现一次last；
- 随机stall期间输出稳定；
- 多帧后level回到0；
- RMII decoded payload与输入完全一致；
- Taxi underflow/overflow为0。

### Camera阶段

- 4路capture均能提交；
- request为持续电平，grant保持整包，released只来自末byte握手；
- camera包不交叉；
- offset 4 cam_id、offset 9 flags和offset 126/127 CRC-16正确；
- Line Buffer drop和Byte FIFO occupancy可解释；
- PC侧payload序号连续；
- 总输入带宽超过100M时，必须由明确的drop/backpressure策略解释，不能静默丢包。

## 15. PASS / FAIL / PENDING Gate Matrix

| Gate | PASS条件 | 当前状态 |
|---|---|---|
| Local source/dependency | 8 .f、26 RTL、16 remap、missing=0 | PASS |
| Duplicate/unresolved | 均为0 | PASS |
| Taxi compile/elaboration | xvlog/xelab/xsim无错误 | PASS |
| Unit simulations | 所有模块满足完整覆盖规范 | FAIL/PENDING |
| Frame Adapter单元 | byte、TLAST、stall stability | PASS（单帧） |
| Adapter→Taxi→RMII activity | RMII有活动、无仿真错误标志 | PASS（有限） |
| RMII line scoreboard | byte/FCS/IFG全比较 | PENDING |
| Synthesis | 无缺失/多驱动 | PASS |
| Implementation route | fully routed、0 route errors | PASS |
| Timing | WNS/WHS非负 | PASS：+3.202/+0.053 ns |
| CDC | 无未处置CDC | PASS（当前报告） |
| Clean DRC/methodology | warning已修复或批准豁免 | FAIL |
| Digital implementation总状态 | route/timing通过但warning仍开放 | **PASS WITH WARNINGS** |
| Bitstream与两次clean build | 两次可追溯构建 | PENDING |
| PHY clock/reset/link | 实测全部通过 | PENDING |
| Hardware Ethernet TX | ILA+pcap通过 | **PENDING** |
| Byte FIFO硬件链 | FIFO/线上scoreboard通过 | PENDING |
| Full Camera-to-Ethernet | 四路Camera到PC连续验证 | **PENDING** |

## 16. 故障定位矩阵

| 现象 | 优先检查 | 可能原因 | 下一步证据 |
|---|---|---|---|
| Taxi compile失败 | manifest、compile order | missing/remap歧义、重复定义、SV类型错误 | missing instances和xvlog首个error |
| xelab失败 | wrapper端口/interface参数 | 使用了不存在的DATA_W、interface宽度不符 | 本地module/interface声明 |
| frame_ready一直低 | Taxi TX FIFO/reset | logic_rst未释放、FIFO full、接口未展开正确 | ILA看reset、tready、overflow |
| Adapter header重复/跳byte | frame_ready/stall逻辑 | header index未按握手推进 | AXIS assertion和单元波形 |
| TLAST错位 | Byte FIFO 9-bit路径 | last未与data同word、非握手推进 | packet/frame两侧handshake count |
| tx_fifo_good_frame有pulse但无RMII | MII clock/reset、MAC enable | FIFO已提交但读侧或MAC未运行 | MII TX clock/en和MAC状态 |
| RMII有活动但Wireshark无帧 | dibit顺序、SFD/FCS、PHY/网卡 | bridge序列化或FCS错误、link/网卡问题 | RMII scoreboard优先于PC猜测 |
| Wireshark看到帧但type错误 | Frame Adapter header | byte序、header offset错误 | decoded byte 0..13 |
| payload错位 | Adapter/FIFO/Camera | stall stability或last边界错误 | AXIS与RMII双scoreboard |
| tx_error_underflow=1 | MAC读侧供数中断 | 未完整提交帧、CDC/reset、FIFO配置 | TX FIFO depth/commit和MII域波形 |
| tx_fifo_overflow=1 | 写速率过高 | 下游100M瓶颈或没有反压 | FIFO level、frame rate、ready占空 |
| Line Buffer drop增长 | Camera输入超过服务能力 | 4-slot满、仲裁或下游反压 | used/committed/request/grant |
| link不上 | REFCLK/reset/线缆/协商 | 50 MHz错误、reset未释放、PHY strap | 示波器、LED、PC协商状态 |
| route PASS但硬件失败 | 板级时序/约束 | I/O delay、IOB warning、PHY连接 | DRC/methodology、示波器、ILA、pcap |
| clean build结果变化 | 未固定源/IP/约束 | XCI输出、compile order或旧checkpoint影响 | 比较两次manifest、reports和hash |

故障处理顺序应从时钟/reset开始，再看AXIS、Taxi FIFO、MII、RMII、PHY link，最后看PC捕获；不要以单个状态pulse跳过中间层。


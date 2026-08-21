# 15 Ethernet 部署与调试手册

## 事实来源范围

本文汇总仓库中全部Markdown，并以当前源码、BD/XCI/XDC、仿真、Vivado报告、ILA CSV和PCAP重新核实。事实优先级为：当前源码 > 当前报告/ILA/PCAP > 当前日志 > Git状态 > 旧文档。Taxi和FPGA-RMII-SMII的README只用于理解库边界；Taxi example板卡README不作为Nexys A7参数或管脚证据。

关键入口：

- 项目与层次：<code>../../prg_cam.xpr</code>、<code>../../prg_cam.srcs/sources_1/new/Camera_Ethernet_Top.sv</code>
- Taxi依赖：<code>../../scripts/add_taxi_sources.tcl</code>、<code>../taxi_compile_manifest.txt</code>
- RTL/TB：<code>../../prg_cam.srcs/sources_1/new/</code>、<code>../../prg_cam.srcs/sim_1/new/</code>
- 时钟/约束：<code>ethernet_clk_wiz.xci</code>、<code>nexys_a7_ethernet.xdc</code>
- 基线实现：<code>../reports/ethernet_bringup/</code>
- ILA实现与硬件证据：<code>../../build/ethernet_ila/</code>
- 本页管脚伴随文档：[14_eth_pin_and_data_configuration.md](14_eth_pin_and_data_configuration.md)

## 未确认项

- 当前固定帧链已经是<code>Fixed_Packet_Generator → Byte_FIFO → Adapter</code>并有硬件捕获PASS；Camera尚未进入活动顶层。
- 没有两次独立clean build记录；当前bitstream可用不等于可重复构建门槛完成。
- RMII TX已加入ODDR、下降沿IOB寄存器和output delay，最新post-route余量为正；RX input delay、板级测量、CFGBVS/CONFIG_VOLTAGE和若干DRC/methodology warning仍未清零。
- 没有PHY寄存器读取；MDC固定0、MDIO高阻。Link速率通过LED/PC数据通道和捕获结果确认，未由MDIO读取确认。
- 没有RJ45差分线、PHY测试点或JA/JB到Ethernet的仓库映射。
- 当前ILA没有MII总线和<code>clock_locked/logic_rst/ETH_RSTN</code>探针；这些是后续推荐探针，不得描述为已经抓取。
- 当前PCAP覆盖1000个固定帧；3秒实时统计覆盖230,008帧，但尚不是长时间Camera压力测试。

## 1. 当前状态基线

| Gate | 当前状态 | 能证明的范围 |
|---|---|---|
| Taxi source/dependency | PASS | 8个.f、26个RTL、16个唯一remap、missing=0 |
| Taxi独立compile/elaboration | PASS | interface、参数和层次可展开 |
| Frame Adapter unit simulation | PASS（单帧） | header、payload、TLAST、stall stability |
| Byte_FIFO确定性源仿真 | PASS | 5帧，覆盖empty、backpressure、last stall、reset，push/pop各256 |
| Fixed→Taxi→RMII RTL smoke | PASS（活动级） | 有RMII活动、仿真无underflow/overflow |
| Fixed-frame RMII硬件解码 | PASS | preamble、SFD、header、payload、FCS、IFG |
| 最新ODDR/IOB数字实现 | PASS WITH WARNINGS | WNS +0.492 ns、WHS +0.053 ns；19条DRC warning |
| 现存ILA诊断实现（修改前） | PASS WITH WARNINGS | WNS +0.070 ns、WHS +0.058 ns；22个DRC warning实例 |
| Bitstream/program | PASS（旧诊断版本） | FPGA识别1个ILA并成功触发；文件早于ODDR/IOB源码修改 |
| Link/100M/PC固定帧 | PASS | EtherType 0x88B5、142 byte、00..7F持续收到 |
| Fixed→Byte_FIFO→Ethernet | PASS（确定性源） | 默认<code>USE_BYTE_FIFO_PATH=1</code>，仿真、ILA和PCAP证据一致 |
| Full Camera-to-Ethernet | PENDING | Camera_Pipeline未进入活动top |
| 新ODDR/IOB bitstream与硬件复验 | PENDING | 新实现DCP已生成，但新bit/ltx未生成、未上板 |
| Clean DRC/methodology | FAIL/OPEN | DRC 19条、methodology 6条，RX外部时序未闭环 |
| 两次clean build | PENDING | 无两次独立构建证据 |

<code>tx_fifo_good_frame</code>仍只表示Taxi TX frame FIFO写侧提交；本项目的硬件PASS来自独立RMII ILA解码和PCAP，不是来自该pulse。Route/timing PASS也不等于Wireshark PASS。

## 2. 模块调用链与完整数据流

### 2.1 当前固定帧链

~~~mermaid
flowchart LR
    FG["Fixed_Packet_Generator\n128 B: 00..7F"] -->|9-bit {last,data}| BF["Byte_FIFO"]
    BF -->|packet_*| AD["Ethernet_Frame_Adapter\n14 B Ethernet II header"]
    AD -->|"8-bit AXIS @100 MHz"| FW["Taxi_Ethernet_Subsystem\nflat wrapper"]
    FW --> AF["Taxi TX frame FIFO\n4096 B + CDC"]
    AF --> MAC["Taxi MAC\npreamble/SFD/FCS/IFG"]
    MAC -->|"MII 4-bit @25 MHz"| BR["Ethernet_Mii_Rmii_Bridge"]
    BR -->|"RMII 2-bit @50 MHz"| PHY["板载PHY"]
    PHY --> RJ["RJ45/PC"]
~~~

### 2.2 目标Camera链

~~~mermaid
flowchart LR
    C0[Camera0] --> L0[Line_Buffer0]
    C1[Camera1] --> L1[Line_Buffer1]
    C2[Camera2] --> L2[Line_Buffer2]
    C3[Camera3] --> L3[Line_Buffer3]
    L0 --> ARB[Arbitration + one-hot MUX]
    L1 --> ARB
    L2 --> ARB
    L3 --> ARB
    ARB --> REP[Byte_Replacer]
    REP --> BF["Byte_FIFO\n9-bit {last,data}"]
    BF --> AD[Ethernet_Frame_Adapter]
    AD --> TAXI[Taxi FIFO/MAC]
    TAXI --> RMII[MII/RMII bridge]
    RMII --> PC[PHY/RJ45/PC]
~~~

完整反压路径为：Taxi <code>tready</code> → <code>frame_ready</code> → Adapter PAYLOAD <code>packet_ready</code> → Byte_FIFO <code>out_ready</code> → FIFO <code>in_ready</code> → Byte_Replacer → 当前获grant的Line Buffer。HEADER期间Adapter强制<code>packet_ready=0</code>，先发送14-byte header，不提前消费payload。

### 2.3 Taxi内部运行

1. 100 MHz logic域按<code>frame_valid && frame_ready</code>写TX frame FIFO。
2. <code>TX_FRAME_FIFO=1</code>，收到TLAST后才提交完整帧指针。
3. async FIFO用指针同步把完整帧交给25 MHz MII TX域。
4. MAC发送7×55、D5、Adapter提供的142 byte；短帧时可padding。
5. MAC计算并发送4-byte Ethernet CRC-32 FCS。
6. MAC保持<code>cfg_tx_ifg=12</code> byte-times。
7. Taxi内部8-bit字节拆成4-bit MII，外部bridge再拆成2-bit RMII。

## 3. 分层调试原则

调试必须从上游到下游逐层建立证据，不能跳过中间层：

~~~mermaid
flowchart TD
    A["L0: clock/reset/link"] --> B["L1: packet valid/ready/last"]
    B --> C["L2: Frame Adapter 14+128 handshakes"]
    C --> D["L3: Taxi FIFO commit/error"]
    D --> E["L4: MII tx_clk/tx_en/txd"]
    E --> F["L5: RMII tx_en/txd/refclk"]
    F --> G["L6: PHY link"]
    G --> H["L7: Wireshark/PCAP"]
~~~

每一层只有三个结论：PASS、FAIL、PENDING。若L2失败，不应先调PHY；若L5已正确而L7失败，才重点检查I/O时序、PHY和PC路径。

## 4. 部署总顺序

| 阶段 | 操作 | 预期结果 | PASS标准 | 失败回退 |
|---|---|---|---|---|
| 0 | source/.f审计 | 本地闭包稳定 | missing/duplicate/unresolved均0 | 停止综合，只修本地依赖映射 |
| 1 | xvlog/xelab | Taxi和wrapper展开 | 无compile/elab error | 回到module/interface实际声明 |
| 2 | unit simulation | Adapter等握手正确 | byte/TLAST/stability自动检查PASS | 保持固定源，不进入实现 |
| 3 | end-to-end simulation | RMII有活动并可解码 | preamble到IFG全部匹配 | 定位AXIS/FIFO/MAC/bridge边界 |
| 4 | synthesis/implementation | 数字设计可路由 | route完成、WNS/WHS非负 | 保留失败DCP/报告，修首个根因 |
| 5 | bitstream/program | DONE且debug core匹配 | PROGRAM.FILE与PROBES.FILE对应 | 回退到已知bit/ltx对 |
| 6 | clock/reset/link | PHY建立100M链路 | link与PC接口Up | 先查Clock Wizard/reset/网线 |
| 7 | ILA | 帧到达RMII输出前 | AXIS、TXEN/TXD、FCS/IFG正确 | 在首个不满足层断点 |
| 8 | Wireshark | PC收到固定帧 | type/header/length/payload连续正确 | 先确认过滤器和物理接口 |
| 9 | 固定源经Byte_FIFO | 确定数据通过真实FIFO | 多帧、stall、最终level=0；当前已PASS | 切<code>USE_BYTE_FIFO_PATH=0</code>回到固定源直通 |
| 10 | Camera | 四路真实数据到PC | 序号/drop/occupancy可解释 | 恢复Byte_FIFO确定性源 |

## 5. Taxi本地依赖与Vivado加载

唯一入口：

<code>prg_cam.srcs/sources_1/lib/taxi-master/eth/rtl/taxi_eth_mac_mii_fifo.f</code>

当前闭包为8个filelist和26个SystemVerilog RTL。上游<code>../lib/taxi/src/...</code>失效时，<code>add_taxi_sources.tcl</code>只在本地<code>sources_1/lib</code>按basename搜索；唯一命中才remap，多命中或零命中立即失败。不得把Taxi example/tb整树加入Vivado。

推荐命令：

~~~powershell
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' `
  -mode batch -nolog -nojournal `
  -source .\scripts\add_taxi_sources.tcl
~~~

必要输出：

- <code>docs/taxi_compile_manifest.txt</code>
- <code>docs/taxi_compile_order.rpt</code>
- <code>docs/taxi_unresolved_references.rpt</code>

加载片段必须保持显式闭包和SystemVerilog类型：

~~~tcl
add_files -fileset sources_1 -norecurse $resolved_rtl
set_property file_type SystemVerilog [get_files $sv_files]
update_compile_order -fileset sources_1
report_compile_order -of_objects [get_filesets sources_1] \
    -used_in synthesis -missing_instances
~~~

## 6. RTL和仿真门槛

### 6.1 AXI-Stream统一规则

- transfer = <code>valid && ready</code>。
- source拉高valid后，在transfer前必须保持valid/data/last。
- last属于当前data beat；不能单独当作完成pulse。
- HEADER的14个byte和PAYLOAD的128个byte都必须分别完成握手。
- 只有第142个frame byte完成握手时才能结束帧。

可复制的stability assertion：

~~~systemverilog
assert property (@(posedge clk) disable iff (rst)
    valid && !ready |=> valid && $stable(data) && $stable(last));

assert property (@(posedge clk) disable iff (rst)
    last |-> valid);
~~~

Frame Adapter专用检查：

~~~systemverilog
assert property (@(posedge clk) disable iff (rst)
    header_state |-> !packet_ready);

assert property (@(posedge clk) disable iff (rst)
    payload_state |-> packet_ready == frame_ready);
~~~

状态名应绑定DUT实际枚举或改写成testbench可见条件，不要直接把示例中的符号复制进无法解析的环境。

### 6.2 现有仿真覆盖

| Testbench | 当前能证明 | 不能证明 |
|---|---|---|
| tb_Ethernet_Frame_Adapter | 单帧142 byte、TLAST、确定stall稳定 | 连续多帧 |
| tb_Taxi_Eth_Mac_Mii_Fifo_Elab | Taxi闭包和interface可展开 | 数据功能 |
| tb_Taxi_Rmii_Subsystem_Elab | flat wrapper+bridge可展开 | 帧内容 |
| tb_Fixed_Frame_Taxi_Rmii | RMII活动、无仿真underflow/overflow | 原TB自身不解码线上byte/FCS |
| tb_Camera_Pipeline | 4包byte compare和周期stall | 最终FIFO/slot全空、显式stability |
| tb_Line_Buffer | 4-slot、drop、TLAST和计数 | data compare和stall |

<code>capture_fixed_frame_rmii_vcd.tcl</code>对现有端到端仿真补充VCD解码，已得到12个完整142-byte AXIS帧和完整RMII frame/FCS/IFG证据；它没有改变原testbench的覆盖声明。

### 6.3 RMII scoreboard

100M模式每个50 MHz周期接收一个dibit。低位dibit先传，四个dibit组成一个byte：

~~~systemverilog
byte_value = dibit[0]
           | (dibit[1] << 2)
           | (dibit[2] << 4)
           | (dibit[3] << 6);
~~~

每个TXEN burst应依次比较：

1. 7×<code>8'h55</code>
2. <code>8'hD5</code>
3. 14-byte header
4. 128-byte payload
5. 4-byte FCS
6. TXEN低期间不少于12 byte-times IFG

当前固定帧实际FCS为<code>6F 0D 02 4D</code>，这是针对<code>DST..payload</code>计算的Ethernet CRC-32；不能与Camera packet offset 126/127的CRC-16混用。

## 7. 综合、实现与bitstream

### 7.1 基线构建

~~~powershell
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' `
  -mode batch -nolog -nojournal `
  -source .\scripts\implement_ethernet_bringup.tcl
~~~

保存compile order、methodology、CDC、DRC、utilization、route status、timing summary和routed DCP。最新ODDR/IOB实现为WNS +0.492 ns、WHS +0.053 ns；RMII TX外部路径setup +5.288 ns、hold +8.048 ns，DRC为0 Error/Critical和19条Warning。该脚本不调用<code>write_bitstream</code>。

### 7.2 ILA诊断构建

~~~powershell
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' `
  -mode batch -nolog -nojournal `
  -source .\scripts\build_ethernet_ila.tcl
~~~

输出：

- <code>build/ethernet_ila/Camera_Ethernet_Top_ila.bit</code>
- <code>build/ethernet_ila/Camera_Ethernet_Top_ila.ltx</code>
- <code>build/ethernet_ila/Camera_Ethernet_Top_ila_routed.dcp</code>
- timing、DRC和utilization报告

磁盘上现存诊断实现为WNS +0.070 ns、WHS +0.058 ns。其bit/ltx时间早于ODDR/IOB源码修改，因此只能作为旧固定帧硬件证据，不能代表最新源码。ILA改变布局布线，任何新诊断bit都必须重新实现，且不能与非ILA时序数值混为同一实现。

### 7.3 Warning处置

最新非ILA DRC的19条warning为：1×CFGBVS-1、6×PLIO-6、6×REQP-1617、2×REQP-1839、3×REQP-1840、1×RTSTAT-10。methodology另有1×SYNTH-6和5×TIMING-18；其中TXD/TXEN已有上升沿capture output delay且时序报告显示正余量，但methodology仍提示“rising and/or falling edge”，必须保留为待处置warning，不能称clean sign-off。旧ILA DRC另有3×PDCN-1569。Bitgen为0 Error不代表warning已关闭。

回退策略：任何实现失败都保留原已知可用bitstream，不删除<code>.runs/.cache/prg_cam.gen</code>来掩盖依赖问题；修复后生成新输出目录并比较报告。

## 8. Tcl脚本设计、编写与调试

### 8.1 设计规则

1. 脚本开头通过<code>[info script]</code>确定自身目录，不依赖启动工作目录。
2. 所有路径使用<code>file normalize</code>和<code>file join</code>。
3. 对<code>get_files/get_nets/get_pins/get_hw_probes</code>使用<code>-quiet</code>并检查<code>llength</code>。
4. 先完整验证依赖，再调用<code>add_files</code>，避免半闭包污染工程。
5. 不递归加入整个Taxi目录；不修改上游.f来隐藏本地remap。
6. 实现、报告、bit/ltx和硬件采样使用独立输出目录。
7. 每个脚本打印机器可检索的<code>RESULT=PASS</code>和输出路径。

基础骨架：

~~~tcl
set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set output_dir [file normalize [file join $project_root build ethernet_debug]]
file mkdir $output_dir

set project_file [file join $project_root prg_cam.xpr]
if {![file exists $project_file]} {
    error "Project not found: $project_file"
}
open_project $project_file
~~~

### 8.2 ILA核和probe连接

当前脚本使用4096深度、100 MHz <code>logic_clk</code>：

~~~tcl
create_debug_core u_ila_ethernet_bringup ila
set_property C_DATA_DEPTH 4096 \
    [get_debug_cores u_ila_ethernet_bringup]
connect_debug_port u_ila_ethernet_bringup/clk \
    [get_nets logic_clk]
~~~

连接每个probe前必须验证综合网表中唯一命中。总线要按bit顺序构造，不要假设<code>get_nets bus[*]</code>返回顺序。

<code>implement_debug_core</code>前需<code>save_constraints</code>。当前安装无法解析工程记录的旧board_part版本；诊断副本清空board_part，只依赖准确part和XDC，避免影响原工程。

### 8.3 硬件编程和捕获

~~~tcl
set_property PROGRAM.FILE $bit_file $device
set_property PROBES.FILE $ltx_file $device
set_property FULL_PROBES.FILE $ltx_file $device
program_hw_devices $device
refresh_hw_device -update_hw_probes true $device

set ila [lindex [get_hw_ilas -of_objects $device] 0]
set hs [get_hw_probes frame_handshake -of_objects $ila]
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 512 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $hs
run_hw_ila $ila
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $csv_file $data
~~~

bit与ltx必须来自同一次实现。若<code>refresh_hw_device</code>显示0个ILA，优先检查当前PROGRAM.FILE、PROBES.FILE和器件是否真的programmed，不要先修改RTL。

### 8.4 常见Tcl故障

| 报错/现象 | 原因 | 处理 |
|---|---|---|
| object list为空 | 名称层次或设计阶段错误 | 在synth后打印<code>get_nets -hier *</code>的限定结果 |
| 多个同名net | 通配符过宽 | 使用精确层次并检查<code>llength==1</code> |
| implement_debug_core要求保存 | debug constraints未持久化 | <code>save_constraints</code>后再实现 |
| board_part not found | 工程元数据版本不可用 | 仅在诊断副本清空board_part；保留准确part/XDC |
| LTX probe mismatch | bit/ltx不是同一实现 | 成对重新program/refresh |
| batch启动失败且提示user apps | 工具用户缓存不可写 | 修正Vivado运行权限；不是RTL错误 |
| wait_on_hw_ila不返回 | 触发条件从未发生 | 改用更上游trigger或立即采样定位常量状态 |

## 9. ILA探针、触发和预期波形

### 9.1 当前实际21组probe

| # | probe | 宽度 | 用途 |
|---:|---|---:|---|
| 0 | rmii_tx_en_dbg | 1 | OBUF前RMII TXEN |
| 1 | rmii_txd_dbg | 2 | OBUF前RMII dibit |
| 2 | phy_ref_clk | 1 | 输出到PHY的50 MHz clock内部网 |
| 3 | frame_data | 8 | Adapter/TAXI数据 |
| 4..7 | frame_valid/ready/last/handshake | 各1 | AXIS握手和TLAST |
| 8 | packet_data | 8 | 当前固定源/未来packet byte |
| 9..11 | packet_valid/ready/last | 各1 | packet侧反压和边界 |
| 12 | tx_error_underflow | 1 | MAC读侧断供事件 |
| 13 | tx_fifo_overflow | 1 | TX FIFO写侧溢出 |
| 14 | tx_fifo_good_frame | 1 | FIFO写侧提交参考 |
| 15 | fixed_packet_data | 8 | 发生器写侧数据 |
| 16..18 | fixed_packet_valid/ready/last | 各1 | 发生器到FIFO握手 |
| 19 | byte_fifo_level | 16 | RAM与输出holding register总占用 |
| 20 | byte_fifo_almost_full | 1 | 剩余空间不足128 words提示 |

探针位于驱动顶层输出的内部net，不抓OBUF之后的物理网络。

### 9.2 当前触发

主触发：<code>frame_handshake == 1</code>，深度4096，trigger position 512。这样保留3584个后触发100 MHz样点，足以观察Taxi FIFO/CDC/MAC延迟后的RMII发送。也可对<code>rmii_tx_en_dbg==1</code>设置基本触发；若要严格上升沿，应使用advanced trigger或比较前后样点。

### 9.3 分层断点

| 断点 | 观察 | 正常波形 | 异常含义 |
|---|---|---|---|
| packet入口 | packet_valid/ready/data/last | 128次握手，last在7F | 上游/FIFO未供数或边界错 |
| Adapter header | frame_* | 14次header握手，期间packet_ready=0 | header状态推进错误 |
| Adapter payload | frame_*与packet_* | 128次一一对应，最后7F+last | 映射或stall稳定错误 |
| Taxi FIFO | ready/good/overflow | 完整TLAST后commit，overflow=0 | FIFO满或帧未完成 |
| MII（推荐新增） | tx_clk/en/txd/er | 25 MHz，TXEN期间nibble变化 | MAC未启动或MII reset问题 |
| RMII | tx_en/txd/refclk | 50 MHz，TXEN期间dibit变化 | bridge或时钟问题 |
| PC | PCAP | 142-byte 88B5帧 | PHY/I/O/过滤器问题 |

### 9.4 当前硬件采样结果

- 4096样点，trigger在512。
- 440次frame handshake，包含2个完整142-byte帧。
- 两个完整RMII burst各1232个100 MHz样点，即616 dibit/154 byte。
- TXEN高期间TXD包含0、1、2、3四种值。
- 解码前缀为<code>55×7 D5 FF×6 02 00 00 00 00 02 88 B5</code>。
- 尾部为<code>7C 7D 7E 7F 6F 0D 02 4D</code>。
- IFG为96个100 MHz样点，即48个RMII周期。
- underflow/overflow采样期间为0。

## 10. FIFO和流控波形判断

### 10.1 AXI-Stream

| 波形 | 正常 | 故障 |
|---|---|---|
| valid=1, ready=0 | data/last保持 | data跳变或valid撤销 |
| valid=1, ready=1 | 计一次byte | 重复计数或漏计 |
| last=1 | 同时valid，且对应末byte | last独立pulse或提前 |
| Header | frame_valid连续，按ready推进 | packet_ready提前拉高 |
| Payload | packet_ready=frame_ready | 两侧ready不一致 |

### 10.2 Byte_FIFO

Byte_FIFO无独立<code>empty/full</code>端口：

- empty等价于<code>level==0</code>，其中level包含RAM外holding register。
- full写侧条件由<code>in_ready==0</code>表达。
- <code>almost_full</code>只表示RAM剩余不足128 words，不等于立即禁止当前word。
- <code>out_valid && !out_ready</code>期间<code>out_data[8:0]</code>必须保持。
- 多帧测试结束后应等待<code>level==0</code>并检查上游Line Buffer的used/committed均归零。

当前ILA已经抓取<code>level[15:0]</code>、<code>almost_full</code>、固定写侧握手和packet读侧握手。若要直接观察FIFO模块边界，建议再增加<code>in_valid/in_ready</code>、<code>out_valid/out_ready</code>与<code>out_data[8:0]</code>的层次化probe。

### 10.3 MII和RMII

- MII：100M模式4-bit/25 MHz；每个byte占两个MII周期。
- RMII：2-bit/50 MHz；每个byte占四个RMII周期。
- <code>mii_tx_en</code>高但<code>mii_txd</code>不变：检查MAC数据和采样相位。
- MII正常而RMII TXEN不动：定位bridge reset、mode_speed和rmii_ref_clk。
- RMII TXEN有规律但PC无帧：先做dibit/byte/FCS/IFG scoreboard，再查I/O时序和PHY。

## 11. Clock、reset、PHY与管脚检测

### 11.1 检查顺序

1. 确认bitstream是当前构建版本，DONE为1。
2. 确认Clock Wizard reset接<code>~CPU_RESETN</code>，而不是直接接低有效按钮。
3. 确认<code>locked</code>没有反馈到Clock Wizard自身reset形成死锁。
4. 确认XCI两个输出：50 MHz/0°给converter，50 MHz/+45°给ETH_REFCLK。
5. 确认ETH_RSTN在locked后约10.49 ms释放。
6. 确认PC链路Up/100M，再观察TXEN/TXD。

### 11.2 可测信号

| 信号 | FPGA PACKAGE_PIN | 推荐证据 |
|---|---|---|
| ETH_REFCLK | D5 | 板上PHY/原理图确认的可达测试点示波器；内部ILA只能证明逻辑网活动 |
| ETH_RSTN | B3 | 板上可达测试点示波器或内部reset状态 |
| ETH_TXEN | B9 | 内部<code>rmii_tx_en_dbg</code> ILA；物理测量需确认板上可达点 |
| ETH_TXD[0] | A10 | 内部ILA，或确认可达点后示波器 |
| ETH_TXD[1] | A8 | 内部ILA，或确认可达点后示波器 |

禁止把D5/B3等PACKAGE_PIN名称当成JA/JB排针坐标。当前仓库没有Ethernet测试点表；若无原理图确认，应优先ILA而不是随意接探头。

## 12. Wireshark与PC验证

正确display filter：

<code>eth.type == 0x88b5</code>

可叠加：

<code>eth.src == 02:00:00:00:00:02 && eth.type == 0x88b5</code>

<code>88 B5</code>是线上network byte order；Wireshark数值过滤不能写成<code>0xb588</code>。

当前固定帧PCAP结果：

| 字段 | 结果 |
|---|---|
| packet count | 1000 |
| capture duration | 0.013171 s |
| average frame size | 142.00 byte |
| average rate | 约75 kframe/s |
| DST | ff:ff:ff:ff:ff:ff |
| SRC | 02:00:00:00:00:02 |
| EtherType | 0x88b5 |
| payload | 00..7F，1000帧一致 |

3秒实时统计每秒约74,884、75,300、75,296帧，总计230,008帧。网卡剥离preamble和FCS，所以PCAP帧长142 byte；FCS由RMII ILA独立检查。

保存可复查证据：

~~~powershell
& 'C:\Program Files\Wireshark\tshark.exe' `
  -i 6 -f 'ether proto 0x88b5' -c 1000 `
  -w .\build\ethernet_ila\wireshark_fixed_1000.pcapng
~~~

接口编号必须用<code>tshark -D</code>在当前PC重新确认，不能永久假定为6。

## 13. 三阶段数据源测试

### 13.1 阶段A：固定帧直通（回退诊断模式）

设置<code>USE_BYTE_FIFO_PATH=0</code>，让固定源直通Adapter；只用于把FIFO从问题范围中排除，不修改Taxi核心。

测试：Adapter unit TB、Taxi/RMII仿真、实现、bitstream、ILA、Wireshark。

PASS：header/payload/FCS/IFG正确，PC持续收到00..7F，underflow/overflow为0。历史直接固定源证据已PASS，但每次切换参数都要重新构建，不能复用另一模式的bitstream结论。

回退：重新program已知配对的ILA bit/ltx；不接Camera、不动BD。

### 13.2 阶段B：确定性源经过Byte_FIFO（当前默认）

当前顶层默认<code>USE_BYTE_FIFO_PATH=1</code>：确定性发生器写入Byte_FIFO，再由FIFO的<code>out_data[7:0]/out_valid/out_ready/out_data[8]</code>驱动Adapter；Taxi和converter核心未改。

必须测试：

- 连续多帧和随机stall。
- 9-bit last/data不分离。
- input/output handshake count相等。
- 每128个payload byte一个last。
- 最终FIFO level=0。
- RMII和PC payload仍为00..7F。

独立TB已覆盖五帧、empty、backpressure、末字节stall和reset并PASS；固定payload硬件ILA/PCAP也PASS。它证明确定性写入端的FIFO链可工作，不证明Camera写入端正确。Camera失败时恢复本阶段，而不是删除FIFO。

### 13.3 阶段C：真实Camera_Pipeline

用<code>Camera_Pipeline.packet_*</code>替换确定性源。必须同时观察：四路request/grant/released、drop count、used/committed、Byte FIFO level、AXIS、RMII和PC序号。

PASS标准：

- 四路数据均出现且包不交叉。
- released只来自末byte真实握手。
- 每帧128-byte payload和TLAST正确。
- offset 4/9/126/127符合Camera协议。
- PC payload序号连续；若输入超过100M容量，所有drop均能由计数器解释。
- underflow/overflow为0，或任何例外有明确复现和处置。

失败时恢复阶段B确定性源，不删除Camera或Taxi文件。

## 14. 常见故障定位矩阵

| 现象 | 首要证据 | 可能原因 | 下一步 |
|---|---|---|---|
| FPGA未programmed | DONE、PROGRAM.FILE | bit路径错误/JTAG状态 | 使用明确bit路径重新program |
| ILA数量为0 | PROBES.FILE、refresh结果 | bit/ltx不配对或旧bit | 成对加载同次实现产物 |
| link不亮 | REFCLK/reset/PC接口 | Clock Wizard极性、locked死锁、reset延时、网线/PHY | 先测clock/reset，不看Taxi |
| frame_valid=0 | packet侧波形 | 数据源reset或未启动 | 上移trigger到packet_valid |
| frame_valid=1、ready=0 | Taxi reset/FIFO | logic_rst未释放或FIFO满 | 看reset、overflow、FIFO深度 |
| 14-byte header不完整 | frame handshake计数 | header index未按握手推进 | Adapter unit TB/ILA逐byte |
| packet_last正确但frame_last错 | Adapter映射 | last未与valid绑定或提前 | 检查最后payload握手 |
| good_frame有pulse、TXEN不动 | MII clock/reset | FIFO提交但MAC读侧未运行 | 抓mii_tx_clk/en/txd |
| MII正常、RMII TXEN不动 | bridge | rmii_ref_clk/reset/mode错误 | 抓bridge两侧 |
| TXEN高、TXD不变 | MAC/采样 | 数据未变化或probe相位错误 | 比较MII、RMII和refclk |
| RMII内容正确、PC无帧 | I/O/PHY/PC | output timing、过滤器、接口选择 | 先用0x88b5正确过滤，再查物理层 |
| Wireshark type为0xb588 | 观察方式 | 过滤器字节序写反 | 使用<code>eth.type==0x88b5</code> |
| 帧长142而非146 | NIC行为 | FCS被网卡剥离 | 用RMII scoreboard验FCS |
| underflow=1 | MAC读侧断供 | 非完整帧、FIFO/CDC/reset问题 | 对齐TLAST、commit和MII读侧 |
| overflow=1 | 输入超过服务能力 | 反压失效或FIFO容量耗尽 | 看ready、level和帧率 |
| Camera丢包 | LB/drop/occupancy | 总输入超过约77.1 Mbit/s payload能力 | 用drop计数解释并降载 |
| clean build结果变化 | 工程可追溯性 | 源、IP输出或约束不固定 | 比较manifest、XCI、reports和hash |

## 15. 失败回退策略

1. 保留已知可用的固定帧bit/ltx/pcap，不覆盖。
2. 每次只跨越一个边界：源、FIFO、Adapter、Taxi、bridge、PHY。
3. 新阶段失败时恢复上一阶段top连接；不要修改Taxi核心来绕过项目侧问题。
4. 不删除<code>prg_cam.gen</code>、<code>.runs</code>或<code>.cache</code>来“修复”依赖。
5. 不在硬件成功和两次clean build前remove旧AXI/DDR/DMA文件。
6. 保存首个error、完整命令、Vivado版本、part、top、XDC集和输出hash。

## 16. 最终预期效益与风险

### 预期效益

- 用明确的14-byte Ethernet II header把现有128-byte packet直接映射为原始二层帧。
- Taxi frame FIFO隔离100 MHz逻辑域和25 MHz MII域，防止MAC读侧断供。
- RMII桥复用Nexys A7板载PHY，不引入UDP/ARP/DDR完整栈。
- 固定帧实测约75 kframe/s，符合166 byte-times/帧的100M理论上限。
- 分层ILA和PCAP证据能区分FIFO提交、RMII发送和PC实际接收。

### 仍存在的风险

- Camera有效payload理论上限约77.1 Mbit/s；四路总输入超过该值时必须丢包或降采样。
- RMII TX外部时序已约束并在最新post-route为正；RX input delay、板级走线偏差、温压、多次clean build和新bitstream实测仍未完成。
- 全局WHS余量较小，最新非ILA为+0.053 ns；约束、debug core或布局变化后必须重查。旧ILA的+0.058 ns不得作为新ODDR/IOB诊断版本结论。
- 本地RMII core替代了早期要求的Vivado mii_to_rmii IP，架构偏差需持续记录。
- Taxi目录无嵌套Git元数据；指定commit来源目前依赖既有manifest校验记录。
- RX、MDIO、Camera长期运行、reset重连和两次clean build仍未完成。

## 17. 部署检查清单

### Source和compile

- [ ] Taxi入口唯一，8个.f、26个RTL、16个remap、missing=0。
- [ ] 没有递归加入Taxi example/tb；所有Taxi .sv为SystemVerilog。
- [ ] duplicate module/interface=0，missing instances为空。
- [ ] Taxi standalone、flat wrapper和bridge均可xvlog/xelab。

### RTL和仿真

- [ ] Adapter检查14-byte header、128-byte payload、TLAST和stall stability。
- [ ] 多帧、reset、边界、timeout和最终FIFO无积压均有自动判据。
- [ ] RMII scoreboard检查preamble、SFD、header、payload、FCS和IFG。
- [ ] 不把good_frame pulse当作线上完成。

### Vivado和bitstream

- [ ] top、part、XDC、XCI和compile order记录完整。
- [ ] synthesis/place/route完成，WNS/WHS非负。
- [ ] CDC、DRC、methodology逐条审阅；warning有处置或书面豁免。
- [ ] bitstream与ltx成对保存并记录SHA-256。
- [ ] 完成两次独立clean build并比较关键报告。

### Board和ILA

- [ ] Clock Wizard reset极性正确，无locked自复位死锁。
- [ ] converter 50 MHz/0°，PHY CLKIN 50 MHz/+45°。
- [ ] ETH_RSTN在locked后约10.49 ms释放，link/100M正常。
- [ ] ILA触发frame handshake或TXEN，探针位于OBUF之前。
- [ ] 14个header byte全部握手，最后payload byte伴随frame_last。
- [ ] TXEN拉高且TXD在TXEN期间变化。
- [ ] underflow=0、overflow=0。

### PC、Byte_FIFO和Camera

- [ ] Wireshark接口正确，过滤器为<code>eth.type == 0x88b5</code>。
- [ ] 固定帧DST/SRC/type/142-byte/payload全部正确并保存PCAP。
- [x] Byte_FIFO确定性源阶段多帧/stall/level归零仿真PASS，固定payload硬件链PASS。
- [ ] ODDR/IOB修改后重新生成配对bit/ltx并重复ILA、link和PCAP验收。
- [ ] Camera阶段四路grant、drop、occupancy和payload序号均可解释。
- [ ] 只有固定源、Byte_FIFO、Camera三个gate依次通过后，才宣布Full Camera-to-Ethernet PASS。

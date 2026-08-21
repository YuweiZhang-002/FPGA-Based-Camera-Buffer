# 07 仿真与验证

## 证据规则

只有同时存在 testbench源码和当前日志 PASS 的项目才记为 RTL PASS。PASS 文本本身不能扩大 testbench实际检查范围。日志中的仿真时间是“足够完成该 TB 自身场景”，不是硬件长期稳定性证明。

## Testbench 逐项说明

### tb_Arbitration

- 输入：<code>request=1111</code>，随后改变为 <code>1000</code>再恢复。
- reset：3 个100 MHz周期。
- 自动检查：期望 grant按 0001→0010→0100→1000轮转；活动 grant在 request变化时保持；released后清零。
- PASS：根目录 <code>xsim_52896.backup.log</code>和 <code>xsim_35492.backup.log</code>。
- 缺口：没有 timeout、数据、TLAST、stream stall或多帧 byte检查。

### tb_Line_Buffer

- 输入：连续写满4个128-byte slot；第5包触发drop；释放一包后写入带 LAST_ROW 的第6包。
- reset：4 个周期。
- 自动检查：满时 used=committed=4、request=1；drop count=1；末 byte TLAST位置；cam_id；sticky overflow与LAST_ROW合并为06；最终 used=committed=0、request=0。
- 多包：实际输出5包。
- timeout：100 µs。
- PASS：<code>xsim_9664.backup.log</code>、<code>xsim_22280.backup.log</code>。
- 缺口：<code>tx_ready</code>始终为1；没有逐 byte比较 <code>tx_data</code>；没有显式 stability assertion。

### tb_Camera_Pipeline

- 输入：cam0/cam1并行各一包、cam0第二行一包、cam2一个126-byte短包；源 byte为确定函数。
- reset：8 个周期。
- stall：<code>packet_ready</code>每7周期中的1周期拉低。
- 自动 byte compare：独立构建512-byte expected数组，含 cam_id覆盖、row flags OR、短包 LENGTH_ERROR和CRC-16。
- handshake count：<code>output_index</code>仅在 <code>packet_valid && packet_ready</code>时递增，并等待512。
- TLAST：检查每个 offset 127。
- 多包：4包。
- 边界：并行请求、行0/行1、126-byte短包。
- timeout：300 µs。
- PASS：根目录当前 <code>xsim.log</code>和 <code>xsim_38524.backup.log</code>。
- 缺口：没有显式断言 stall期间 valid/data/last稳定；结束时没有检查 <code>fifo_level==0</code>和4路 used/committed全清。

### tb_Ethernet_Frame_Adapter

- 输入：单个00..7F、128-byte payload。
- reset：5 个周期。
- stall：周期7/11模式覆盖header和payload，并刻意stall最后byte。
- 自动 byte compare：检查14-byte header和128-byte payload，共142次握手。
- handshake count：<code>frame_index</code>仅在 frame握手时递增。
- TLAST：只允许 index 141。
- stability assertion：若前一周期 <code>frame_valid && !frame_ready</code>，下一周期必须保持 valid/data/last。
- timeout：2000个100 MHz周期。
- PASS：<code>build/ethernet_frame_adapter_sim/.../xsim.log</code>，1895 ns。
- 缺口：只有单帧，没有连续多帧边界。

### tb_Taxi_Eth_Mac_Mii_Fifo_Elab

- 输入：TX valid恒0，RX空闲。
- reset：释放后运行到300 ns。
- 检查：Taxi interface、端口、参数和26-file依赖可完整编译/展开。
- PASS：<code>build/taxi_mii_fifo_elab/xsim_11512.backup.log</code>。
- 缺口：没有发送帧，不是数据功能测试。

### tb_Taxi_Rmii_Subsystem_Elab

- 输入：frame valid恒0，RMII RX空闲。
- reset：释放后运行到1200 ns。
- 检查：扁平 Taxi wrapper与本地 MII/RMII bridge可共同展开。
- PASS：<code>xsim_3476.backup.log</code>、<code>xsim_41120.backup.log</code>。
- 缺口：没有数据、stall、序列化检查。

### tb_Fixed_Frame_Taxi_Rmii

- 输入：<code>Fixed_Packet_Generator</code>重复产生00..7F，每包后有256个100 MHz周期间隙。
- reset：200 ns。
- 运行：到50.2 µs。
- 自动检查：任意 RMII TX enable置位；仿真中 underflow/overflow不得置位；Taxi写侧 good-frame计数非零。
- 多包：日志 <code>good_frames=12</code>，这是TX FIFO提交计数。
- PASS：<code>build/taxi_mii_fifo_elab/xsim.log</code>。
- 缺口：未主动施加 AXIS stall；未解码 RMII dibit；未比较线上 DST/SRC/EtherType/payload；未检查线上 TLAST、preamble、SFD、FCS、IFG；未检查 Taxi FIFO最终积压。50.2 µs内的12次good-frame不能解释为12帧都已上线。

## 覆盖矩阵

符号：Y=明确覆盖；P=部分/间接；N=未覆盖；N/A=该TB无此对象。

| TB | 正常 | stall | reset | 边界 | byte compare | handshake count | TLAST | stability | 多帧 | 长时/timeout | FIFO无积压 | 明确结果 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Arbitration | Y | N/A | Y | Y | N/A | P | N/A | N/A | P | N | N/A | PASS |
| Line_Buffer | Y | N | Y | Y | N | Y | Y | N | Y | Y | Y | PASS |
| Camera_Pipeline | Y | Y | Y | Y | Y | Y | Y | N | Y | Y | N | PASS（有限） |
| Frame Adapter | Y | Y | Y | Y | Y | Y | Y | Y | N | Y | N/A | PASS |
| Taxi standalone elaboration | N | N | Y | N | N | N | N | N | N | N | N | PASS（仅展开） |
| Taxi+bridge elaboration | N | N | Y | N | N | N | N | N | N | N | N | PASS（仅展开） |
| Fixed→Taxi→RMII | P | N | Y | P | N | P | N | N | Y | P | N | PASS（活动级） |

按用户给出的“有效仿真必须全部包含”标准，没有任何一个单独的端到端 Camera→RMII testbench满足全部项目。因此“完整系统仿真验收”状态是 FAIL/PENDING，而不是 PASS。

## 需要补充的验证

1. Frame Adapter连续多帧 test。
2. Line Buffer独立随机 stall、逐 byte compare、stability assertion。
3. Camera Pipeline结束时检查 Byte FIFO level、used/committed均为0。
4. Camera Pipeline→Adapter连接后的多帧随机反压回归。
5. RMII monitor：还原 dibit→nibble→byte，检查7×55、D5、142-byte frame、CRC-32、IFG。
6. 端到端 scoreboard把每个 camera packet与RMII MAC payload对应，并区分FIFO已提交和线上已完成计数。

## 可复现命令

现有脚本/命令入口：

~~~powershell
vivado.bat -mode batch -nolog -nojournal -source .\scripts\sim_ethernet_frame_adapter.tcl
xvlog.bat --incr --relax -prj .\scripts\taxi_mii_fifo_vlog.prj
xelab.bat --debug typical --relax tb_Taxi_Eth_Mac_Mii_Fifo_Elab -s tb_Taxi_Eth_Mac_Mii_Fifo_Elab_sim
xsim.bat tb_Taxi_Eth_Mac_Mii_Fifo_Elab_sim -runall
~~~

另外两个 Taxi/RMII top的 xelab/xsim命令需按其 testbench top替换。执行新回归会更新日志；本文仅记录审阅时已有结果。


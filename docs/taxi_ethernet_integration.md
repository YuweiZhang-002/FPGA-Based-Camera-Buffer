# Taxi Ethernet 集成记录

更新日期：2026-07-23  
工程：Vivado 2025.2.1，`xc7a50ticsg324-1L`，Nexys A7-50T  
分支：`feat/taxi-ethernet-bringup`

## 当前结论

第一阶段目标已达到：本地 `taxi_eth_mac_mii_fifo` 及 26 个递归依赖能够独立通过 `xvlog/xelab/xsim`，缺失依赖为 0。第二阶段的固定帧顶层、Clock Wizard、本地 MII→RMII bridge、官方引脚 XDC、综合与完整 place/route 也已通过。

尚未完成的是物理板卡验证：本轮没有生成/下载 bitstream、没有操作板卡，也没有实际 link LED 或 Wireshark 抓包。因此“能稳定在 PC 上看到帧”仍是硬件待验收项，不能用仿真结果代替。

## 2026-07-23 Camera 实时源接入

`Camera_Ethernet_Top` 当前默认参数 `USE_CAMERA_PIPELINE=1`，活动链路已经改为：

```text
GPIO[7:0]/GPIO[8]/GPIO[9]
  -> Camera_Pipeline
     -> 4 x Camera_Capture
     -> 4 x Line_Buffer
     -> Arbitration
     -> Byte_Replacer
     -> Camera_Pipeline 内部 Byte_FIFO
  -> Ethernet_Frame_Adapter
  -> Taxi_Ethernet_Subsystem
  -> MII/RMII bridge
  -> PHY
```

camera0 使用 `GPIO[7:0]`、`GPIO[8]=PCLK`、`GPIO[9]=HREF`；camera1~3 在当前顶层绑为无效。Camera 路径不再经过顶层诊断用的第二个 Byte_FIFO，因此不会形成双重缓存。原有 `Fixed_Packet_Generator -> Byte_FIFO` 保留为编译期回退路径：把 `USE_CAMERA_PIPELINE` 设为 0 后重新实现即可恢复固定帧诊断。

新增 `tb_Camera_Pipeline_Ethernet_Source.sv` 已用 XSim 验证 3 个连续 128-byte packet，覆盖周期性反压、最后一字节 stall、自动 header/payload/TLAST 比较、握手计数、stall 稳定性、FIFO 最终无积压、drop/overflow 为 0。结果：

```text
PASS: Camera_Pipeline -> Byte_FIFO -> Frame Adapter
PASS: frames=3 packet_hs=384 frame_hs=426 stalls_and_last_stall=covered
```

当前非 ILA 实现完成且全部网络已路由，WNS `+0.025 ns`、WHS `+0.035 ns`，DRC Error/Critical 为 0；这是 **Digital implementation PASS WITH WARNINGS**。当前 ILA 实现 WNS `+1.323 ns`、WHS `+0.053 ns`，生成了匹配的 `Camera_Ethernet_Top_ila.bit/.ltx`，包含 Camera PCLK/HREF/data、Camera packet、仲裁、Line Buffer、Byte FIFO、frame 和 RMII 探针。

2026-07-23 的烧录尝试在 `open_hw_target` 阶段失败，Vivado 报告 `There is no current hw_target`。因此没有下载本次 bitstream，也没有取得实时 Camera 波形；**Hardware Ethernet TX 与 Full Camera-to-Ethernet 均保持 PENDING**。

实时接口仍有一个需要板上验证的风险：`Camera_Capture` 把 PCLK 先同步到 100 MHz 域，再在延迟后的采样脉冲上读取并行 data；GPIO PCLK/data/HREF 尚无基于 RP2350A 实测时序的 input-delay 约束。理想 12.5 MHz 仿真通过不能证明任意实际 PCLK 频率、脉宽和 data 保持时间都安全。如果 ILA 显示原始 PCLK/HREF 有活动但 Camera packet 丢失或数据错序，应优先核对 RP2350A 源同步时序；无法满足现有采样契约时，后续应改为 PCLK 写侧的异步 FIFO，而不能用单周期脉冲直接跨域。

## 本地源与版本

Taxi 编译源唯一来自：

```text
D:/prg/prg_cam/prg_cam.srcs/sources_1/lib/taxi-master
```

实际树与分类见 `docs/taxi_local_file_manifest.md`。入口递归得到 8 个 filelist、26 个 RTL、16 条本地重映射、0 缺失。26/26 个闭包 RTL 与本机既有 commit `bc4a6d3f2aa30156267ad279682e66d99558a633` 参考树逐行一致；参考树没有加入 Vivado。

本轮未执行 `git clone`、`git submodule`、`git pull`、`curl`、`wget` 或其他在线下载，也未移动、重命名、删除 `lib` 文件。上游 Taxi `.f` 保持原样。

正式处理前已撤回旧的 `.gitignore` 移除流程：根 `.gitignore` 与本地备份逐行一致，Taxi 自带 `.gitignore` 保持存在。

## 使用的 Taxi 模块

入口为 `eth/rtl/taxi_eth_mac_mii_fifo.f` / `taxi_eth_mac_mii_fifo.sv`。直接职责如下：

| 模块 | 职责 |
|---|---|
| `taxi_eth_mac_mii_fifo` | 8-bit AXI-Stream 帧与 MII MAC 之间的异步 FIFO、TX/RX 状态 |
| `taxi_eth_mac_mii` / `taxi_eth_mac_1g` | MII MAC、preamble/FCS/IFG、帧收发控制 |
| `taxi_axis_async_fifo_adapter` / `taxi_axis_async_fifo` | 100 MHz logic 域与 25 MHz MII 域跨时钟 FIFO |
| `taxi_axis_if` | Taxi 内部 SystemVerilog AXI-Stream interface |
| `taxi_mii_phy_if` / `taxi_ssio_sdr_in` | Taxi 的 MII PHY 侧时钟/寄存器适配 |
| `taxi_lfsr` | Ethernet CRC/FCS 相关 LFSR |
| `taxi_eth_mac_stats` / `taxi_stats_collect` | 统计路径；首版 `STAT_EN=0`，接口仍防堵塞 |
| `taxi_arbiter` / `taxi_penc` | AXIS 仲裁依赖 |
| `taxi_sync_reset` / `taxi_sync_signal` | 复位与状态同步 |

逐项 26-file 清单见 `docs/taxi_compile_manifest.txt`。

## 集成层次与职责

当前活动顶层为 `Camera_Ethernet_Top`，严格按首测顺序使用固定帧源：

```text
Fixed_Packet_Generator (00..7F, 128 B)
  -> Ethernet_Frame_Adapter (14 B Ethernet II header)
  -> Taxi_Ethernet_Subsystem (flat wrapper + Taxi MII MAC/FIFO)
  -> Ethernet_Mii_Rmii_Bridge
  -> local rmii_phy_if
  -> ETH_* RMII pins
```

- `Fixed_Packet_Generator.sv`：循环产生 128-byte `00..7F`，包间保留 256 个 100 MHz 周期，便于首抓包观察。
- `Ethernet_Frame_Adapter.sv`：添加 DST/SRC/EtherType，不缓存 payload。
- `Taxi_Ethernet_Subsystem.sv`：对外端口全部扁平；`taxi_axis_if` 只存在于 wrapper 内，未暴露给 BD。
- `Ethernet_Mii_Rmii_Bridge.sv`：按本地 `rmii_phy_if.v` 的实际端口包装，并加入 50 MHz 域异步置位/同步释放复位器。
- `Camera_Ethernet_Top.sv`：连接固定源、时钟、PHY reset、Taxi 与 RMII 引脚；保留三个 TX 状态为 `MARK_DEBUG`。

Camera/Byte_FIFO 尚未接回该顶层，这是测试顺序要求，而不是缺失：只有固定帧实际抓包通过后才切到 Byte_FIFO，再切 Camera pipeline。

## 帧格式与 ready/valid

发送给 Taxi 的 Ethernet II frame 共 142 byte（不含 Taxi 添加的 preamble/FCS）：

| Offset | 长度 | 内容 |
|---:|---:|---|
| 0 | 6 | DST `FF:FF:FF:FF:FF:FF` |
| 6 | 6 | SRC `02:00:00:00:00:02` |
| 12 | 2 | EtherType `88 B5`（network byte order） |
| 14 | 128 | 原 packet payload；首测为 `00..7F` |

Byte_FIFO 到 Taxi 的映射：

| Byte_FIFO / Adapter | Taxi AXIS |
|---|---|
| `frame_data[7:0]` | `s_axis_tx.tdata[7:0]` |
| `frame_valid` | `s_axis_tx.tvalid` |
| `frame_ready` | `s_axis_tx.tready` |
| `frame_last` | `s_axis_tx.tlast` |
| 常量 | `tkeep=1`, `tstrb=1`, `tuser=0`, `tid=0`, `tdest=0` |

Adapter 的 HEADER 阶段 `packet_ready=0`；PAYLOAD 阶段 `packet_ready=frame_ready`。只有最后一个 payload byte 上的 `valid && ready` 才结束帧，`frame_last` 与该 byte 一起在 stall 中保持。

Taxi 参数为 `VENDOR="XILINX"`、`FAMILY="artix7"`、`STAT_EN=0`；本地模块没有需要传入的 `DATA_W`，wrapper 和测试均未向 MAC 传该参数。未使用的 RX、TX completion、statistics AXIS 输出 `tready=1`。

## MII ↔ RMII

Vivado 2025.2.1 本机 Catalog 没有 `mii_to_rmii` IP。用户提供的本地 `FPGA-RMII-SMII-main/RTL/rmii_phy_if.v` 已按真实源码端口接入；没有猜测端口，也没有修改该 converter 核心。

使用的实际信号包括：

- MII：独立 `mac_mii_rxc/mac_mii_txc`、`mac_mii_rxd[3:0]`、`mac_mii_rxdv/rxer`、`mac_mii_txd[3:0]`、`mac_mii_txen/txer`。
- RMII：50 MHz `phy_rmii_ref_clk`、`crsdv/rxer/rxd[1:0]`、`txen/txd[1:0]`。
- `mode_speed=1`，固定 100 Mbit/s。
- `smii_phy_if.v` 未实例化，因为 Nexys A7 板载 PHY 使用 RMII。

本地 bridge 在 50 MHz reference clock 上生成 25 MHz MII TX/RX clocks。XDC 对综合后实际 `mac_mii_txc_reg/Q` 和 `mac_mii_rxc_reg/Q` 添加了 `/2` generated clock；完整实现证明这些网络在 Artix-7 上可放置、可路由，0 failed nets。

## 时钟与复位

- `CLK100MHZ`：E3，10 ns period。
- 顶层显式 IBUF，并用 BUFG 生成 Taxi/Adapter 的 `logic_clk=100 MHz`。
- Clock Wizard 的输入语义为 `PRIM_SOURCE=Global_buffer`；生成 stub 的真实端口为 `sys_clk/reset/locked/rmii_ref_clk/phy_ref_clk`。
- `rmii_ref_clk`：50 MHz、0°，用于 converter。
- `phy_ref_clk`：50 MHz、相对 converter reference +45°，连接 `ETH_REFCLK`。
- MMCM lock 后，20-bit counter 保持 PHY reset 约 10.5 ms；`ETH_RSTN=phy_ready`，正确 active-low 释放。
- Taxi `logic_rst` 和 `mac_rst` 使用注册后的 reset；Taxi 自己分别同步到 MII TX/RX 域。
- bridge wrapper 再将 reset 异步置位、同步释放到 50 MHz 域。

## XDC

活动约束：`prg_cam.srcs/constrs_1/new/nexys_a7_ethernet.xdc`。100 MHz、CPU reset 和以下 Ethernet 管脚从本地 `Nexys-A7-50T-Master.xdc` 去除注释后复制，端口名未猜测：

| Port | Pin | I/O standard |
|---|---|---|
| `ETH_MDC` | C9 | LVCMOS33 |
| `ETH_MDIO` | A9 | LVCMOS33 |
| `ETH_RSTN` | B3 | LVCMOS33 |
| `ETH_CRSDV` | D9 | LVCMOS33 |
| `ETH_RXERR` | C10 | LVCMOS33 |
| `ETH_RXD[0]` | C11 | LVCMOS33 |
| `ETH_RXD[1]` | D10 | LVCMOS33 |
| `ETH_TXEN` | B9 | LVCMOS33 |
| `ETH_TXD[0]` | A10 | LVCMOS33 |
| `ETH_TXD[1]` | A8 | LVCMOS33 |
| `ETH_REFCLK` | D5 | LVCMOS33 |
| `ETH_INTN` | B8 | LVCMOS33 |

TX-only 首版令 `ETH_MDC=0`、`ETH_MDIO=Z`；PHY 依靠板级 strap/autonegotiation。综合脚本检查 14/14 个顶层端口均有 `PACKAGE_PIN` 和非默认 `IOSTANDARD`。

## 仿真与编译结果

| 检查 | 结果 | 证据 |
|---|---|---|
| `.f` 递归 | PASS | 8 filelists、26 RTL、16 remaps、missing=0 |
| Vivado missing instances | PASS | `< empty >` |
| 闭包固定 commit 对比 | PASS | 26/26 逐行一致 |
| Taxi 独立 `xvlog` | PASS | 26 RTL + standalone harness |
| Taxi 独立 `xelab/xsim` | PASS | `PASS: taxi_eth_mac_mii_fifo standalone elaboration harness`，300 ns |
| Frame Adapter 内容与 stall | PASS | 14+128 byte；`valid/data/last` stall 稳定 |
| Taxi flat wrapper + bridge | PASS | `xvlog/xelab/xsim`，1200 ns |
| 固定帧端到端 RTL smoke | PASS | 50.2 µs，12 个 good frame，观察到 RMII TX，无 underflow/overflow |

Taxi 上游 RTL仍产生非致命 warning：若干关闭的 PTP/LFC/PFC 端口用未定宽常量连接，`xelab` 报 actual 32-bit 与 formal width 不同；还存在 timescale 与 LFSR 仿真敏感列表 warning。没有编译或展开 error，未为消除 warning 修改 Taxi 核心。

## 综合、实现、时序、CDC、DRC

顶层 `Camera_Ethernet_Top` 已执行 `synth_design -> opt_design -> place_design -> phys_opt_design -> route_design`。

| 项目 | post-route 结果 |
|---|---|
| Routing | PASS，556/556 routable nets fully routed，0 routing errors |
| Setup | PASS，WNS `+3.202 ns`，TNS `0` |
| Hold | PASS，WHS `+0.053 ns`，THS `0` |
| Pulse width | PASS，WPWS `+3.000 ns` |
| CDC | PASS，`All paths are Safely Timed.` |
| DRC Error/Critical | PASS，0 |
| Methodology Critical | PASS，0 |
| Unclocked registers | PASS，0 |
| Unconstrained internal endpoints | PASS，0 |
| Top port pin/I/O standard | PASS，14/14 |

post-route 资源：282 LUT（0.87%）、335 registers（0.51%）、1.5 BRAM tiles（2.00%）、1 MMCM、6 BUFGCTRL、0 DSP。报告位于 `docs/reports/ethernet_bringup/`，routed checkpoint 位于 `build/ethernet_bringup/Camera_Ethernet_Top_routed.dcp`。

尚有 DRC Warning，但没有 Error/Critical：

- `CFGBVS-1` 1 项：本地 Digilent Master XDC 未给 `CFGBVS/CONFIG_VOLTAGE`，本轮未猜值。
- `PLIO-6/REQP-1617` 各 6 项：Taxi MII PHY wrapper 的 `IOB=TRUE` 寄存器现在连接的是内部 RMII converter，而非物理 IOB；实现仍成功路由。
- Taxi async FIFO BRAM reset-control warning 4 项；来自未改动的上游 FIFO reset 结构。
- Methodology 只剩 `TIMING-18` 两项：异步按钮 `CPU_RESETN` 和复位输出 `ETH_RSTN` 没有外部 I/O delay。`check_timing` 也提示 RMII TX 输出没有板级 output-delay；Master XDC 没提供 PHY 时序值，所以没有编造约束。post-route 内部时序通过，但这不是完整的 PHY 外部时序 sign-off。

Vivado 启动时还报告工程记录的 `digilentinc.com:nexys-a7-50t:part0:1.2` board-part 元数据在当前安装中不可用；器件属性仍正确使用 `xc7a50ticsg324-1L`。这不影响本次综合/实现，但应在生成最终 bitstream 前安装/指向正确的本地 board files 或清理陈旧 board-part 元数据。

## PC Wireshark / Scapy

上板后先保持当前固定源顶层：

1. FPGA 与 PC 网卡直连，或通过 100-Mbit switch 连接，先确认 link LED。
2. Wireshark 选择物理有线网卡，display filter：

   ```text
   eth.type == 0x88b5
   ```

3. 预期 DST `ff:ff:ff:ff:ff:ff`、SRC `02:00:00:00:00:02`、EtherType `0x88b5`、payload `00..7f`。
4. 常见 PC NIC 会剥离 FCS，因此 Wireshark 通常显示 142 byte；线上 DST 到 FCS 为 146 byte。

Scapy 示例：

```python
from scapy.all import Ether, sniff

def check(pkt):
    payload = bytes(pkt[Ether].payload)
    assert pkt.type == 0x88B5
    assert payload == bytes(range(128))
    print(pkt.src, pkt.dst, len(pkt), "PASS")

sniff(iface="<PC Ethernet interface>",
      filter="ether proto 0x88b5",
      prn=check,
      store=False)
```

固定源抓包通过后，再把源替换为 Byte_FIFO；此时应按实际 payload 序号规则检查连续性。

## 带宽上限

100 Mbit/s、128-byte payload 的每帧线速占用：preamble+SFD 8 B、header+payload 142 B、FCS 4 B、IFG 12 B，共 166 byte-times。

- 理论最大帧率：`100e6 / (166*8) = 75,301 frame/s`。
- 有效 payload：约 `77.1 Mbit/s`，即 `9.64 MB/s`，效率约 77.1%。
- 当前固定发生器额外插入 256 个 100 MHz 周期，只用于易观察首测，不代表最终 Byte_FIFO 吞吐。

## 构建命令

```powershell
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -source .\scripts\add_taxi_sources.tcl
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -source .\scripts\create_ethernet_clock_ip.tcl
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -source .\scripts\add_ethernet_bringup_sources.tcl
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -source .\scripts\synth_ethernet_bringup.tcl
& 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -source .\scripts\implement_ethernet_bringup.tcl
```

独立仿真源顺序见 `scripts/taxi_mii_fifo_vlog.prj`；验收 top 为 `tb_Taxi_Eth_Mac_Mii_Fifo_Elab`、`tb_Taxi_Rmii_Subsystem_Elab`、`tb_Fixed_Frame_Taxi_Rmii`。

## 保留与删除

本轮删除数为 0，`remove_files` 调用数为 0。保留：完整 `lib`、Byte_FIFO、Camera pipeline、现有 AXI4_Compiler/MIG/SmartConnect/DMA/Send_Control/System_RefControl、BD/XCI 和生成目录。

旧链路只有在实际硬件抓包成功且两次 clean build 通过后，才可先断开活动层次、`remove_files`（不删磁盘）、clean build、生成待删清单并等待用户确认。本轮没有满足该门槛。

## PASS / FAIL 清单

| 验收项 | 状态 | 说明 |
|---|---|---|
| 全程无网络下载 | PASS | 只使用本地工作区与 Vivado 安装 |
| Taxi 只从本地 `lib` 编译 | PASS | 26-file 明确闭包 |
| 固定 commit 闭包 | PASS | 26/26 对照 commit 一致 |
| Missing dependency | PASS | 0 |
| 重复定义 / unresolved reference | PASS | 0 / `< empty >` |
| `taxi_eth_mac_mii_fifo` 独立 xvlog/xelab | PASS | standalone harness 通过 |
| Frame Adapter 帧内容 | PASS | 仿真 142 byte，payload `00..7F` |
| stall 稳定 | PASS | `valid/data/last` 断言通过 |
| MII→RMII RTL 集成 | PASS（SIM/实现） | 端到端 xsim 与 route 通过 |
| 无缺失模块/多驱动 | PASS | synth/implementation 0 error |
| Ethernet 顶层端口有 pin/IOSTANDARD | PASS | 14/14；12 个 ETH_* 全部约束 |
| synthesis / implementation | PASS | route 0 failed nets |
| timing | PASS（内部） | WNS +3.202 ns，WHS +0.053 ns；外部 RMII delay 待规格约束 |
| CDC | PASS | All paths safely timed |
| DRC | PASS with warnings | 0 Error/Critical，17 个已列明 Warning |
| 仿真 underflow/overflow | PASS | 端到端 smoke 未触发 |
| link LED | NOT TESTED | 需要 bitstream 与板卡 |
| Wireshark 持续看到 0x88B5 | NOT TESTED | 需要板上抓包 |
| 硬件 payload 长度/连续性 | NOT TESTED | 仿真 payload PASS，硬件待测 |
| 硬件 `tx_error_underflow=0` | NOT TESTED | 仿真 PASS，硬件待 ILA/LED |
| 硬件 `tx_fifo_overflow=0` | NOT TESTED | 仿真 PASS，硬件待 ILA/LED |
| Byte_FIFO 接回 | NOT RUN | 必须在固定帧抓包后执行 |
| Camera pipeline 接回 | NOT RUN | 必须在 Byte_FIFO 验证后执行 |
| 两次 clean build | NOT RUN | 硬件抓包前不触发删除门槛 |

## 2026-07-26 当前 Camera/Receiver 验证更新

本节优先于上面的历史首轮 bring-up 状态。完整证据、哈希、ILA 逐拍分析和
GUI/ILA A/B 构建结果见：

`prg_cam.srcs/sources_1/tx/taxi_receiver_advanced/p7_live_ila_session_audit_and_ab_build_report.md`

- 47-probe ILA 版本已构建并烧录；正式时序 WNS `+0.953 ns`、
  WHS `+0.046 ns`。
- Camera packet → Frame Adapter 捕获到严格的 128 + 14 = 142 次握手；
  payload 最后一字节同拍 `frame_last=1`，捕获窗口内 Taxi
  underflow/overflow 均为 0。
- 当前 Camera 输入 payload 前四字节为 `95 90 6A 60`。该值已在
  Camera_Capture 的 `data_sync` 边界出现，且严格等价于预期
  `A5 A0 5A 50` 的 bit4/bit5 互换；Taxi/RMII/PC 不是该异常来源。
- 残余 LENGTH_ERROR 现场值为 127 byte。完整 ILA 行显示同步 PCLK
  一拍毛刺打断低电平过滤窗口并合并相邻脉冲；最终方案应为 PCLK 域采样
  加异步 FIFO，不应仅增大 `PCLK_FILTER_LEN`。
- Python receiver/session audit 回归为 `59 passed`；旧 data4 PCAP 的
  78,467 个包均写入 audit CSV。
- 同源普通/ILA A/B build 均通过：普通 WNS/WHS
  `+0.793/+0.071 ns`，ILA `+0.953/+0.046 ns`；源码约束清单构建前后
  SHA-256 相同。

当前状态：

| 项目 | 状态 |
|---|---|
| Digital implementation | PASS WITH WARNINGS |
| Camera → Ethernet AXIS 活动 | PASS（ILA） |
| 当前 Camera sync/位序 | FAIL（bit4/bit5 互换） |
| 残余 Camera 行长度 | FAIL（已抓到 127 byte） |
| Hardware Ethernet TX / Wireshark 当前版复验 | PENDING |
| Full Camera-to-image reconstruction | PENDING |

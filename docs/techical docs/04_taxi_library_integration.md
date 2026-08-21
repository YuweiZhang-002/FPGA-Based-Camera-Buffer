# 04 Taxi 库集成

## 本地来源与可验证性

Vivado 只从 <code>prg_cam.srcs/sources_1/lib/taxi-master</code>加载 Taxi。该目录没有嵌套 <code>.git</code>元数据，因此仅凭当前源码树不能独立读取上游 commit ID。旧清单记录 26/26 闭包文件曾与本机 commit <code>bc4a6d3f2aa30156267ad279682e66d99558a633</code>参考树逐行一致；这是“旧文档/既有校验结果”，不是当前目录自身携带的 commit 证明。

当前可直接证明：

- 入口存在：<code>eth/rtl/taxi_eth_mac_mii_fifo.f</code>。
- 递归闭包为 8 个 filelist、26 个唯一 RTL。
- 16 个失效的 <code>../lib/taxi/src/...</code>相对路径被脚本按 basename 唯一重映射到当前 lib。
- <code>MISSING_OR_AMBIGUOUS (0)</code>。
- Vivado missing instances 报告为空。

证据：<code>../taxi_compile_manifest.txt</code>、<code>../taxi_unresolved_references.rpt</code>、<code>../ethernet_bringup_missing_instances.rpt</code>。

## .f 递归方式

<code>scripts/add_taxi_sources.tcl</code>从每个当前 .f 所在目录解析相对路径；直接路径失效时，在整个本地 lib 按 basename 搜索：

- 唯一命中：记录 remap 并继续。
- 多个命中：标 ambiguous 并停止。
- 无命中：标 missing 并停止。
- 先完成整个闭包解析，missing 非零时不会部分加入工程。

脚本去重 RTL/.f、检查 module/interface 重复定义、仅用 <code>add_files -norecurse</code>加入闭包、把所有 .sv 标为 SystemVerilog、更新 compile order 并检查 unresolved reference。它不遍历加入整个 Taxi 仓库，不访问网络，也不删除文件。

## filelist 闭包

1. <code>axis/rtl/taxi_axis_arb_mux.f</code>
2. <code>axis/rtl/taxi_axis_async_fifo.f</code>
3. <code>axis/rtl/taxi_axis_async_fifo_adapter.f</code>
4. <code>eth/rtl/taxi_eth_mac_1g.f</code>
5. <code>eth/rtl/taxi_eth_mac_mii.f</code>
6. <code>eth/rtl/taxi_eth_mac_mii_fifo.f</code>
7. <code>eth/rtl/taxi_eth_mac_stats.f</code>
8. <code>eth/rtl/taxi_mii_phy_if.f</code>

## 26 个 RTL

| 目录 | 文件 |
|---|---|
| axis/rtl | taxi_axis_adapter, taxi_axis_arb_mux, taxi_axis_async_fifo, taxi_axis_async_fifo_adapter, taxi_axis_if, taxi_axis_null_src, taxi_axis_pad, taxi_axis_tie |
| eth/rtl | taxi_axis_gmii_rx, taxi_axis_gmii_tx, taxi_eth_mac_1g, taxi_eth_mac_mii, taxi_eth_mac_mii_fifo, taxi_eth_mac_stats, taxi_mac_ctrl_rx, taxi_mac_ctrl_tx, taxi_mac_pause_ctrl_rx, taxi_mac_pause_ctrl_tx, taxi_mii_phy_if |
| io/rtl | taxi_ssio_sdr_in |
| lfsr/rtl | taxi_lfsr |
| prim/rtl | taxi_arbiter, taxi_penc |
| stats/rtl | taxi_stats_collect |
| sync/rtl | taxi_sync_reset, taxi_sync_signal |

完整路径和 16 条 remap 见 <code>../taxi_compile_manifest.txt</code>。

## SystemVerilog interface 与扁平 wrapper

Taxi 核心的 AXI Stream端口使用 <code>taxi_axis_if</code> modport。<code>Taxi_Ethernet_Subsystem</code>对外只暴露普通信号，在 wrapper 内创建四个 interface：

| interface | DATA_W | 用途 | 未消费处理 |
|---|---:|---|---|
| s_axis_tx | 8 | 发送帧输入 | 与 frame_* 映射 |
| m_axis_tx_cpl | 96 | TX completion | tready=1 |
| m_axis_rx | 8 | RX 数据 | tready=1 |
| m_axis_stat | 16 | statistics | tready=1 |

发送映射：

| Taxi signal | wrapper signal/value |
|---|---|
| tdata | frame_data |
| tvalid | frame_valid |
| tready | frame_ready |
| tlast | frame_last |
| tkeep | 1 |
| tstrb | 1 |
| tuser | 0 |
| tid | 0 |
| tdest | 0 |

证据：<code>Taxi_Ethernet_Subsystem.sv:28-85</code>。

## 实例参数

wrapper传给 <code>taxi_eth_mac_mii_fifo</code>：

- <code>VENDOR="XILINX"</code>
- <code>FAMILY="artix7"</code>
- <code>STAT_EN=0</code>

本地 <code>taxi_eth_mac_mii_fifo</code>没有 <code>DATA_W</code>参数；因此 wrapper没有传入该参数。其内部 MII MAC 数据路径固定由 8-bit AXIS/GMII 逻辑和 MII nibble选择实现。证据：<code>Taxi_Ethernet_Subsystem.sv:87-93</code>；<code>taxi_eth_mac_mii_fifo.sv:18-44</code>。

## Vivado 引用方式

- 原始 Taxi interface 模块作为普通 SystemVerilog source加入 <code>sources_1</code>。
- 活动顶层直接实例化扁平 <code>Taxi_Ethernet_Subsystem</code>。
- 不把 Taxi interface直接暴露到 BD；当前 BD 为空，也没有 Taxi Module Reference。
- <code>ethernet_bringup_compile_order.rpt</code>列出 32 个 active compile-order项，顶层为第 32 项，且 missing instances为空。

## 编译状态

<code>tb_Taxi_Eth_Mac_Mii_Fifo_Elab</code>不发送流量，只验证接口类型、参数、端口和层次可完整 xvlog/xelab/xsim。<code>xsim_11512.backup.log</code>打印 PASS。因此状态是“独立编译/展开 PASS”，不是 MAC 数据功能 PASS。


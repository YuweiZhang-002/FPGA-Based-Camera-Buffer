# 08 Vivado 构建与报告

## Camera Pipeline 独立 OOC 综合

<code>scripts/synth_fifo_pipeline.tcl</code>在内存工程中读取7个相机链 RTL，以 <code>Camera_Pipeline</code>为top并创建100 MHz <code>sys_clk</code>。

| 指标 | 结果 |
|---|---:|
| WNS | +3.875 ns |
| WHS | +0.164 ns |
| failing endpoints | 0 |
| Slice LUT | 566 |
| Slice Registers | 538 |
| Block RAM Tile | 2.5（5×RAMB18） |
| DSP | 0 |

核心内部时序为 PASS。但该 OOC工程没有板级I/O delay：<code>check_timing</code>报告42个 input ports和182个 output ports没有delay；因此不能把该结果视为相机物理接口时序 sign-off。

证据：<code>../../fifo_pipeline_timing.rpt</code>、<code>../../fifo_pipeline_utilization.rpt</code>、<code>../../fifo_pipeline_check_timing.rpt</code>。

## 固定源 Ethernet 活动顶层

<code>scripts/implement_ethernet_bringup.tcl</code>执行：

1. open project、设置 <code>Camera_Ethernet_Top</code>；
2. generate/synth Clock Wizard；
3. synth_design；
4. opt_design；
5. place_design；
6. phys_opt_design；
7. route_design；
8. methodology、CDC、DRC、utilization、route status、timing报告；
9. 写 routed DCP。

### Route

| 指标 | 结果 |
|---|---:|
| routable nets | 556 |
| fully routed | 556 |
| routing errors | 0 |

判定：implementation route PASS。证据：<code>../reports/ethernet_bringup/post_route_status.rpt</code>。

### Post-route timing

| 指标 | 结果 |
|---|---:|
| WNS | +3.202 ns |
| TNS | 0 |
| setup failing endpoints | 0 / 886 |
| WHS | +0.053 ns |
| THS | 0 |
| hold failing endpoints | 0 / 886 |
| WPWS | +3.000 ns |

时钟摘要：

| clock | period | frequency |
|---|---:|---:|
| sys_clk_pin | 10 ns | 100 MHz |
| rmii_ref_clk | 20 ns | 50 MHz |
| phy_ref_clk | 20 ns，+2.5 ns相位 | 50 MHz |
| mii_tx_clk | 40 ns | 25 MHz |

判定：当前已分析路径 timing PASS。证据：<code>post_route_timing_summary.rpt:146-195</code>。

### CDC

post-route CDC报告为 <code>All paths are Safely Timed.</code>。判定：Vivado CDC report PASS。该结果不替代功能CDC仿真。证据：<code>post_route_cdc.rpt</code>。

### 资源

| 资源 | 使用 |
|---|---:|
| Slice LUT | 282 |
| Slice Registers | 335 |
| Block RAM Tile | 1.5（1×RAMB36 + 1×RAMB18） |
| DSP | 0 |
| BUFGCTRL | 6 |
| MMCME2_ADV | 1 |

这是固定发生器活动顶层的资源，不含4-camera pipeline。证据：<code>post_route_utilization.rpt</code>。

## DRC 与 methodology

2026-07-21生成的 final报告对应 Fully Routed <code>Camera_Ethernet_Top</code>。

### DRC

共有17个 warning，0个 Error/Critical：

| 规则 | 数量 | 含义 |
|---|---:|---|
| CFGBVS-1 | 1 | 未设置 CFGBVS/CONFIG_VOLTAGE |
| PLIO-6 | 6 | Taxi MII内部 IOB=TRUE寄存器并未直接连接顶层IO，因为中间还有RMII bridge |
| REQP-1617 | 6 | 同一组内部 IOB属性不适用 |
| REQP-1839 | 2 | TX FIFO RAMB36控制受异步reset寄存器影响 |
| REQP-1840 | 2 | TX FIFO RAMB18控制受异步reset寄存器影响 |

判定：工具脚本的“无 Error/Critical”门槛 PASS；clean DRC sign-off FAIL。证据：<code>final_drc.rpt</code>。

### Methodology

2个 TIMING-18：

- CPU_RESETN相对 sys_clk缺 input delay。
- ETH_RSTN相对 sys_clk缺 output delay。

此外 timing summary的 check-timing部分可见 ETH_TXD/ETH_TXEN 等外部端口缺少明确output delay分析。物理 PACKAGE_PIN/IOSTANDARD均已设置，但接口时序约束仍不完整。

判定：methodology clean sign-off FAIL。证据：<code>final_methodology.rpt</code>；<code>post_route_timing_summary.rpt</code>。

## 综合/实现与硬件状态不可混淆

~~~mermaid
flowchart LR
    S["RTL compile/sim"] --> I["synthesis/place/route"]
    I --> T["timing/CDC/DRC sign-off"]
    T --> B["bitstream + program"]
    B --> L["PHY link"]
    L --> W["Wireshark/Scapy"]

    S:::pass
    I:::pass
    T:::fail
    B:::pending
    L:::pending
    W:::pending

    classDef pass fill:#d8f3dc,stroke:#2d6a4f
    classDef fail fill:#ffe5d9,stroke:#9d0208
    classDef pending fill:#fff3bf,stroke:#9c6b00
~~~

route PASS只到布局布线层。当前没有bitstream、program、link或capture证据。

## 构建命令

~~~powershell
vivado.bat -mode batch -nolog -nojournal -source .\scripts\check_project.tcl
vivado.bat -mode batch -nolog -nojournal -source .\scripts\synth_fifo_pipeline.tcl
vivado.bat -mode batch -nolog -nojournal -source .\scripts\synth_ethernet_bringup.tcl
vivado.bat -mode batch -nolog -nojournal -source .\scripts\implement_ethernet_bringup.tcl
~~~

旧根目录 <code>vivado.log</code>包含早期失败尝试（无open design、非法旧XDC文件名、一次synthesis failed）。这些早于当前成功报告，不能覆盖当前post-route结果，但应保留为历史排错记录。


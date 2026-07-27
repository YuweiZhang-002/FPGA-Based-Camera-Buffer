# P6 Reset CDC 时序修复与 Camera 复测报告

> 日期：2026-07-24  
> 器件：xc7a50ticsg324-1L  
> 工具：Vivado 2025.2.1  
> 结论：复位 CDC/高扇出问题已修复；Camera `LENGTH_ERROR` 未随之消失，
> 当前证据指向独立的 PCLK/HREF 采样边界问题。

## 1. 事实来源

本报告只使用以下本地证据：

- `prg_cam.srcs/sources_1/new/Camera_Ethernet_Top.sv`
- `prg_cam.srcs/sources_1/new/Camera_Capture.v`
- `prg_cam.srcs/sources_1/new/Alarmer.v`
- `prg_cam.srcs/sources_1/lib/taxi-master/sync/rtl/taxi_sync_reset.sv`
- `prg_cam.srcs/sources_1/lib/taxi-master/eth/rtl/taxi_mii_phy_if.sv`
- `prg_cam.srcs/sources_1/lib/taxi-master/axis/rtl/taxi_axis_async_fifo.sv`
- `prg_cam.srcs/constrs_1/new/nexys_a7_ethernet.xdc`
- `build/gui_ethernet_rebuild/`
- `build/ethernet_bringup/`
- `build/ethernet_ila/`
- `build/receiver_output/camera_after_reset_cdc_fix_20260724/`

修复前的 WNS `-1.050 ns`、`phy_ready_reg/C` 56 次和 8 个
`sys_clk_pin -> mii_tx_clk` recovery 失败端点来自修复前报告的现场审阅记录。
主工程 GUI run 在本次任务中被完整重建，因此
`prg_cam.runs/impl_1/Camera_Ethernet_Top_timing_summary_routed.rpt`
现已是修复后的报告，不能再作为修复前文件引用。

## 2. RTL 定位结论

### 2.1 `mac_rst` 的真实来源

修复前，顶层由 `phy_ready` 取反形成统一内部复位，并同时送往 Camera、
Frame Adapter、RMII bridge 以及 Taxi 的 `mac_rst/logic_rst`。综合后靠近
`Fixed_Packet_Generator` 的 LUT 名称只是 flatten/optimization 后的网表命名；
`Fixed_Packet_Generator.sv` 本身没有生成 `mac_rst`。

修复后，`Camera_Ethernet_Top.sv:68-94` 生成六个独立注册分支：

```text
source_rst_reg
camera_rst_reg
frame_rst_reg
bridge_rst_reg
taxi_logic_rst_reg
taxi_mac_rst_reg
```

连接位置：

| 复位分支 | 当前负载 |
|---|---|
| `source_rst_reg` | 固定发生器、诊断 Byte FIFO |
| `camera_rst_reg` | Camera_Pipeline |
| `frame_rst_reg` | Ethernet_Frame_Adapter |
| `bridge_rst_reg` | Ethernet_Mii_Rmii_Bridge |
| `taxi_logic_rst_reg` | Taxi logic reset |
| `taxi_mac_rst_reg` | Taxi MAC reset |

`ETH_RSTN` 仍由 `phy_ready` 直接驱动，保持原有 PHY 延时释放语义。

### 2.2 Taxi reset synchronizer

`taxi_sync_reset.sv:22-40` 的实现为：

```systemverilog
logic [N-1:0] sync_reg = '1;
always_ff @(posedge clk or posedge rst) begin
    if (rst)
        sync_reg <= '1;
    else
        sync_reg <= {sync_reg[N-2:0], 1'b0};
end
```

因此它是标准的：

- 高有效异步置位；
- 在目的时钟域逐拍同步释放；
- `ASYNC_REG` 标注的同步器。

模块默认参数是 `N=2`，但本工程相关实例不是 `N=10`：

- `taxi_mii_phy_if.sv` 的 `tx_reset_sync_inst` 使用 `N=4`；
- `taxi_axis_async_fifo.sv` 的 `m_reset_sync_inst` 使用 `N=4`。

两组各有 4 个 FDPE/PRE，合计正好 8 个 endpoint。

## 3. 实施的修复

### 3.1 降低复位扇出

顶层不再让一根 `phy_ready -> mac_rst` 复位树驱动全部层次，而是用独立
寄存器分支隔离 Camera、数据通路、bridge 和 Taxi。修复后路由报告中的
Taxi `mac_rst` net fanout 为 4，Taxi `logic_rst` net fanout 为 37。

Camera 独立复位分支仍有约 365 个直接负载，但它已经不再与 Taxi 异步复位
释放路径共用驱动，且当前 setup/hold 均通过。若以后 Camera 分支再次成为
关键路径，可在 Camera 层次内部继续做局部复制；本次不为追求数字而改变
Camera 功能结构。

### 3.2 精确 CDC 例外

`nexys_a7_ethernet.xdc:66-74` 只对 Taxi 两组异步复位同步器的 PRE pins
增加 `set_false_path`：

```text
*/u_taxi_eth_mac_mii_fifo/*/tx_reset_sync_inst/sync_reg_reg*/PRE
*/u_taxi_eth_mac_mii_fifo/tx_fifo/fifo_inst/m_reset_sync_inst/sync_reg_reg*/PRE
```

没有对整个 `sys_clk -> mii_tx_clk` 时钟关系做全局 false path，正常的 FIFO
指针同步和其它跨域检查仍然保留。`report_exceptions -coverage` 显示：

| 例外 | pins/endpoints | To coverage |
|---|---:|---:|
| MII TX reset PRE | 4/4 | 100% |
| TX FIFO M reset PRE | 4/4 | 100% |

## 4. Vivado 构建结果

### 4.1 非 ILA 独立实现

`scripts/implement_ethernet_bringup.tcl`：

- WNS：`+1.941 ns`
- WHS：`+0.052 ns`
- setup failing endpoints：0
- hold failing endpoints：0
- DRC Error/Critical：0

### 4.2 GUI 主工程 run

`scripts/rebuild_gui_ethernet.tcl` 走与 GUI Generate Bitstream 相同的：

```text
synth_1 -> impl_1 -> write_bitstream
```

Vivado 明确报告增量条件不匹配并退回完整综合；实现使用：

```text
srcset    = sources_1
constrset = constrs_1
top       = Camera_Ethernet_Top
```

`build/gui_ethernet_rebuild/timing_summary.rpt`：

- WNS：`+1.941 ns`
- WHS：`+0.052 ns`
- setup/hold failing endpoints：`0/0`
- `async_default sys_clk_pin -> mii_tx_clk` 旧失败行不再出现在活动
  Other Path Groups 表中；
- User Ignored Paths 表中两组目标均明确显示 `Timing Exception: False Path`。

该 GUI run 是 **PASS WITH WARNINGS**，不是无条件 sign-off：

- bitgen/DRC 为 0 Error；
- fully-routed DRC 共 37 个 Warning checks；
- 其中 6 个 `REQP-1617/use_IOB_register` 在 place 阶段也表现为 6 条
  `Place 30-73` Critical Warning：Taxi MII 内部寄存器带 `IOB=TRUE`，但它们
  先连接项目的 MII-to-RMII bridge，并不直接连接外部 IO，所以该属性被忽略；
- 其余类别包括 CFGBVS、PLIO-6、RAMB18/RAMB36 async control 和无可路由
  load。它们不是本次 8 个 reset PRE recovery 端点的复发。

普通 bitstream：

```text
prg_cam.runs/impl_1/Camera_Ethernet_Top.bit
SHA256 A9AFCECFE350026C8130EAADAA649986B8B111559A5E0EB8FA93B3609F29E829
```

该普通 `.bit` 已构建但本阶段没有覆盖下载；板上 Camera 采集使用下述 ILA
版本，避免失去探针。

### 4.3 ILA 实现

- WNS：`+1.948 ns`
- WHS：`+0.022 ns`
- setup/hold failing endpoints：0
- 42 个 probes，1 个 ILA；
- bit/ltx 为同次实现产物并已成功 program。

```text
Camera_Ethernet_Top_ila.bit
SHA256 D7FDCA68991E12F24F0856F997D02B647967DF24CE58B16B15597483CA021EFC

Camera_Ethernet_Top_ila.ltx
SHA256 807EA17323EE4D854B5AFB4AA5ECE166D0816FB41446CCBB02DBF3BA271B763B
```

## 5. ILA `LENGTH_ERROR` 触发结果

触发条件直接使用：

```text
camera_length_error_pulse_dbg == 1
```

证据文件：

```text
build/ethernet_ila/camera_length_error_pulse_dbg_capture.csv
```

4096 个 100 MHz 样本的统计：

| 信号/事件 | 观测 |
|---|---|
| trigger sample | 512 |
| HREF transition | 1 次，高到低 |
| trigger 时 HREF | 0 |
| trigger 时 line_end | 1 |
| raw PCLK 的 ILA 采样值 | 全程 1，0 次可见翻转 |
| `camera_capture_byte_valid_dbg` | 全程 0 |
| current byte count | 全程 0 |
| last line byte count | 0 |
| row flags | 全程 `0x08` |
| RMII TXEN active samples | 1232 |
| Taxi underflow/overflow | 0/0 |

结论：

1. ILA 抓到了 HREF 下降沿对应的行结束判定；
2. 在该窗口中 `Camera_Capture` 没有观察到任何 PCLK 上升沿，所以实际
   byte count 是 0，`LENGTH_ERROR` 的置位符合当前 RTL；
3. `row_flags[3]` 并没有因复位修复而清零，当前验收为 FAIL；
4. 同一窗口仍有 RMII TX 活动，且 Taxi underflow/overflow 为 0，因此不能
   把本次 Camera 空行解释为 Ethernet TX 停止。

特别注意：ILA 由 100 MHz `logic_clk` 采样 raw PCLK。PCLK 显示恒 1 既可能
代表物理信号停在高电平，也可能代表 PCLK 与 100 MHz 同频/近同频造成相干
欠采样或混叠。它不能单独证明 RP2350A 没有输出。

当前 `Alarmer.v` 用两级同步器把 PCLK 电平采入 100 MHz，再做边沿检测；
这种“脉冲采样”只在 PCLK 足够慢、每个高低电平都能被 sys_clk 可靠观察时
成立。若 RP2350A PCLK 接近或高于 50 MHz，或与 100 MHz 相干，就可能漏掉
大部分乃至全部边沿。这是下一轮必须独立验证的 Camera CDC 假说。

## 6. Camera PCAP 复测

复位修复后的 15 秒抓包：

```text
build/ethernet_ila/camera_after_reset_cdc_fix_20260724.pcapng
SHA256 AE8FAED71BB6F7A82D6CBAB592CAA7281E13F8EB6547CB80029C936C1BCF8227
```

接收器结果：

| 项目 | 结果 |
|---|---:|
| 匹配 EtherType 0x88B5 | 749 |
| valid camera packets | 0 |
| `LENGTH_ERROR` | 749/749 |
| CRC error | 0 |
| overflow | 0 |
| image status | CORRUPT |

修复前基线为 `541/1000 = 54.1%`；修复后为 `749/749 = 100%`。错误率没有
下降，因此“Taxi 复位 recovery 违例”和“Camera LENGTH_ERROR”没有得到
共享根因的证据，应按两条问题线分别推进。

这不是证明复位修复导致 Camera 退化：本次 ILA 同时表明现场 PCLK 在
100 MHz 采样域内不可见，而两次 PCAP 的输入状态并不相同。能够确认的是：

- Reset CDC/timing：已修复；
- Ethernet TX：仍能发出 0x88B5 帧；
- Camera 输入边界：仍失败，并且当前失败样本是 0-byte HREF interval。

## 7. RP2350A 字段语义

以下语义由用户/固件侧确认，不是从当前 FPGA 仓库中的 RP2350A C 源码推导：

| 字段/信号 | 已确认语义 |
|---|---|
| HREF rising | 一行开始 |
| HREF falling | 一行结束 |
| `frame_id` | 图像帧编号，用于图片排序 |
| `row_idx` | 当前图像帧内的行号 |
| `payload_len` | 有效 image bytes 数量 |
| `row_seq` | 全局行序号，从 0 开始，仅 reset 后复原 |

仍缺少固件源码级证据的项目包括：字段 byte offset、字节序、PCLK 频率和
占空比、数据相对 PCLK 的建立/保持、HREF 与首末字节的精确边沿关系。

## 8. Gate 汇总

| Gate | 状态 | 证据 |
|---|---|---|
| Taxi reset synchronizer 类型确认 | PASS | `taxi_sync_reset.sv` |
| 实例级 N 值确认 | PASS | 两处均为 N=4 |
| 精确 PRE false path 覆盖 | PASS | 4+4 pins，均 100% |
| `mac_rst` 扇出降低 | PASS | routed net fanout 4 |
| 非 ILA implementation timing | PASS | WNS +1.941、WHS +0.052 |
| GUI Generate Bitstream 等价 run | PASS WITH WARNINGS | `write_bitstream Complete`，37 个 DRC Warning checks |
| ILA implementation timing | PASS | WNS +1.948、WHS +0.022 |
| Taxi underflow/overflow | PASS | 0/0 |
| `row_flags[3]` 不再固定置位 | FAIL | 当前 capture 恒为 0x08 |
| Camera byte count = 128 | FAIL | 当前 capture 为 0 |
| Reset 修复降低 LENGTH_ERROR | FAIL | 54.1% -> 100%，未下降 |
| 真实 Camera 图像重建 | PENDING | 无有效 Camera packet |

## 9. 下一步优先级

1. 用示波器/外部逻辑分析仪在 FPGA 输入脚测 PCLK 的真实频率、占空比，
   并同时测 HREF；不要仅依赖 100 MHz ILA 对 raw PCLK 的采样。
2. 若 PCLK 接近或高于 50 MHz，不再使用 `Alarmer` 的电平同步边沿检测：
   应在 PCLK 域采样 `camera_data/HREF`，再通过异步 FIFO 或可靠事件计数 CDC
   进入 100 MHz 域。
3. 若 PCLK 物理上确实静止，优先检查 RP2350A 输出使能、GPIO 复用、PCLK
   引脚连接和 FPGA XDC，而不是继续修改 Taxi。
4. PCLK 可可靠观察后，再以 `length_error_pulse` 触发，要求
   `last_line_byte_count == 128`、`row_flags[3] == 0`。
5. 只有第 4 项通过后再抓 1000-frame Camera PCAP，并按
   `frame_id/row_idx/row_seq/payload_len` 复核连续性。

## 10. 修改边界

- 未修改 Taxi core；
- 未修改 RMII bridge 数据路径；
- 未修改 Frame Adapter 或 Ethernet frame 内容；
- 本次功能修改只涉及顶层复位分支和精确 XDC CDC 例外；
- 新增/更新 Tcl 仅用于构建、endpoint 数量校验和报告生成。

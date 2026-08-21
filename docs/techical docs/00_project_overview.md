# 00 项目总览

## 工程边界

- 工程：<code>D:/prg/prg_cam/prg_cam.xpr</code>
- Vivado 报告版本：2025.2.1，Build 6403652
- 器件：<code>xc7a50ticsg324-1L</code>
- 板卡：Nexys A7-50T
- 当前综合顶层：<code>Camera_Ethernet_Top</code>
- 当前 BD：<code>design_1.bd</code> 的 <code>design_tree</code> 为空；活动以太网顶层不依赖 BD wrapper。

证据：<code>prg_cam.xpr</code> 的 TopModule；<code>design_1.bd</code>；所有 post-route 报告的 Design/Device 字段。

## 目标架构与当前活动架构

~~~mermaid
flowchart LR
    subgraph TARGET["目标完整链（Camera 部分尚未接入活动顶层）"]
      C0["Camera_Capture 0"] --> L0["Line_Buffer 0"]
      C1["Camera_Capture 1"] --> L1["Line_Buffer 1"]
      C2["Camera_Capture 2"] --> L2["Line_Buffer 2"]
      C3["Camera_Capture 3"] --> L3["Line_Buffer 3"]
      L0 --> A["Arbitration + one-hot MUX"]
      L1 --> A
      L2 --> A
      L3 --> A
      A --> BR["Byte_Replacer"]
      BR --> BF["Byte_FIFO"]
    end

    FG["Fixed_Packet_Generator\n当前活动数据源"] --> FA["Ethernet_Frame_Adapter"]
    BF -. "计划替换固定发生器" .-> FA
    FA --> TW["Taxi_Ethernet_Subsystem"]
    TW -->|"MII 4 bit @ 25 MHz"| MR["Ethernet_Mii_Rmii_Bridge"]
    MR -->|"RMII 2 bit @ 50 MHz"| PHY["Nexys A7 PHY / ETH_*"]
    PHY -. "PENDING: link / capture" .-> PC["PC Wireshark / Scapy"]

    classDef pending stroke-dasharray: 5 5
    class BF,PC pending
~~~

源码证据：

- 目标相机链：<code>Camera_Pipeline.v:18-297</code>。
- 当前固定源：<code>Camera_Ethernet_Top.sv:64-79</code>。
- Frame Adapter、Taxi、bridge：<code>Camera_Ethernet_Top.sv:81-160</code>。
- PHY 管脚输出与 reset：<code>Camera_Ethernet_Top.sv:188-199</code>。

## 数据格式

Camera Pipeline 输出每包固定 128 byte，<code>packet_last</code>与 offset 127 同拍。Frame Adapter 增加 14 byte Ethernet II header：

| 字节 | 内容 |
|---|---|
| 0..5 | DST = FF:FF:FF:FF:FF:FF |
| 6..11 | SRC = 02:00:00:00:00:02 |
| 12..13 | EtherType = 88 B5 |
| 14..141 | 原 128-byte packet |

Taxi 随后在 MAC 层增加 7-byte preamble、1-byte SFD、必要 padding、4-byte CRC-32 FCS 和 IFG。当前 142-byte MAC 输入已超过最小帧要求，不触发 padding。证据：<code>Ethernet_Frame_Adapter.sv:26-45</code>；<code>taxi_axis_gmii_tx.sv</code> 的 PREAMBLE/PAYLOAD/PAD/FCS/IFG FSM。

## 时钟与复位

| 域 | 频率/相位 | 来源 | 用途 |
|---|---:|---|---|
| logic/sys | 100 MHz | CLK100MHZ 经 IBUF+BUFG | 固定源、Adapter、Taxi TX FIFO 写侧；目标 Camera Pipeline |
| RMII converter | 50 MHz, 0° | <code>ethernet_clk_wiz.rmii_ref_clk</code> | 本地 MII/RMII converter |
| PHY CLKIN | 50 MHz, +45° | <code>ethernet_clk_wiz.phy_ref_clk</code> | ETH_REFCLK |
| MII TX/RX | 25 MHz（100M 模式） | bridge 从 50 MHz 生成 | Taxi MAC MII 域 |

<code>CPU_RESETN</code>低或 MMCM 未锁定时，100 MHz 域计数器清零；锁定后计满 20 bit，即约 10.49 ms，<code>phy_ready</code>置位并释放 <code>ETH_RSTN</code>。Bridge 对进入 50 MHz 域的 reset 使用异步置位、四级同步释放。证据：<code>Camera_Ethernet_Top.sv:39-62</code>；<code>Ethernet_Mii_Rmii_Bridge.sv:35-48</code>；XCI 的 50 MHz/0° 与 50 MHz/45° 配置。

## 吞吐上限

100BASE-TX/RMII 原始线速为 100 Mbit/s。每个 128-byte camera packet 对应：

- 142 byte MAC 输入（14 header + 128 payload）
- 4 byte FCS
- 8 byte preamble/SFD
- 12 byte IFG
- 合计 166 byte time

理想上限约为 <code>100e6 / (166×8) = 75,301 frame/s</code>，camera payload 有效带宽约 <code>128/166×100 = 77.1 Mbit/s</code>。这是协议理论上限，不包含发生器间隙、PHY 协商、主机丢包或 Camera Pipeline 的供数约束。

## 层级状态定义

- RTL PASS：testbench 明确比较其声明的行为并打印 PASS。
- implementation PASS：综合、布局布线完成，当前已约束路径无负 slack，route 无错误。
- hardware PASS：必须有板上 link、PC capture、EtherType、长度、payload 连续性和错误标志的实测记录。

三者不可互相替代。当前状态是“RTL 有多项 PASS、固定源 implementation route PASS、hardware 全 PENDING”。


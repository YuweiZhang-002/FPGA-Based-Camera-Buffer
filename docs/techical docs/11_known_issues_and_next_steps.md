# 11 已知问题与后续步骤

## 冲突与偏差

### 1. 目标完整链与活动顶层不同

目标是 Camera→Byte FIFO→Ethernet；当前 <code>Camera_Ethernet_Top</code>实例化固定发生器。Camera Pipeline虽存在于sources_1并有独立仿真/综合，但不在当前活动top层次。

状态：PENDING。证据：<code>Camera_Ethernet_Top.sv:64-79</code>与 <code>ethernet_bringup_compile_order.rpt</code>。

### 2. MII/RMII方案与早期要求不同

早期要求优先使用 Vivado IP Catalog <code>mii_to_rmii</code>并读取stub；当前实现使用本地 <code>FPGA-RMII-SMII-main/RTL/rmii_phy_if.v</code>。它已经编译、展开、仿真活动并实现，但没有板级捕获证明。

状态：需用户确认的架构偏差；hardware PENDING。

### 3. Taxi commit不能由当前目录独立证明

<code>taxi-master</code>没有嵌套Git元数据。旧manifest声明26/26文件与指定commit参考树一致，但当前审阅只能把该声明作为旧文档证据。若验收必须具备可审计commit provenance，应保存本地哈希清单或vendor metadata，不需要联网。

状态：UNKNOWN / provenance待增强。

### 4. DATA_W参数

本地 <code>taxi_eth_mac_mii_fifo</code>没有 <code>DATA_W</code>参数。wrapper正确地没有猜测或传入它；8-bit宽度由interface和MII MAC结构决定。

状态：已解释，不是缺失。

### 5. 仿真PASS文字过强

<code>tb_Fixed_Frame_Taxi_Rmii</code>打印“00..7F frame traversed”，但实际没有RMII byte decoder。可证明的是RMII有活动、Taxi写侧提交过帧、仿真中无underflow/overflow；不能证明线上payload为00..7F。

状态：文档已降级为活动级 PASS；线级内容 PENDING。

### 6. route PASS不等于硬件PASS

当前route为556/556且内部时序为正，但没有bitstream下载、link或pcap。

状态：implementation PASS；hardware PENDING。

## 约束与DRC问题

| 问题 | 状态 | 风险 |
|---|---|---|
| CFGBVS/CONFIG_VOLTAGE未设置 | FAIL | 配置bank电压属性不完整 |
| 6×PLIO-6 + 6×REQP-1617 | FAIL | Taxi内部MII IOB属性经过bridge后不再直连顶层IO |
| 4×BRAM async reset control warning | FAIL | reset附近可能有RAM控制完整性风险，默认STA不覆盖 |
| CPU_RESETN input delay缺失 | FAIL | methodology不clean |
| ETH_RSTN output delay缺失 | FAIL | methodology不clean |
| ETH TX/RX接口外部delay模型不足 | PENDING/FAIL | 引脚已约束，但板级接口时序sign-off不足 |

这些问题不能通过文档更改修复；本轮按要求不修改XDC、RTL或工程。

## 验证缺口

1. 没有完整 Camera→RMII testbench。
2. 没有RMII protocol monitor和CRC-32 checker。
3. Line Buffer单元TB无data compare、无stall。
4. Camera Pipeline TB无显式stall stability assertion、无最终FIFO/slot全空检查。
5. Frame Adapter TB只有单帧。
6. Taxi standalone TB只展开，不发流量。
7. 端到端TB未检查最终Taxi FIFO积压。
8. 无两次clean build证据。
9. 无硬件 ILA、link、pcap或Scapy日志。

## Legacy与保留项

- <code>design_1.bd</code>当前为空，不参与活动顶层。
- <code>new/deprecated</code>中的 AXI4_Compiler、Send_Control、System_RefControl等仍存在于工程文件记录，但不在当前以太网活动compile order。
- XPR仍记录旧增量综合checkpoint <code>AXI4_Compiler.dcp</code>。
- 本轮没有remove_files或删除磁盘文件。
- Taxi完整目录、许可证、README、本地RMII/SMII库、Byte FIFO和旧模块均保留。

证据：<code>design_1.bd</code>；<code>prg_cam.xpr</code>；<code>ethernet_bringup_compile_order.rpt</code>；当前Git状态。

## 后续优先级

### P0：补齐可判断线上正确性的仿真

1. 为RMII TX写monitor，重组2-bit→4-bit→8-bit。
2. 检查preamble、SFD、DST/SRC/EtherType、128-byte payload、FCS和IFG。
3. 把“FIFO提交计数”和“线上完成帧计数”分开。
4. 加随机stall、多帧、reset during idle/frame、最终所有FIFO为空的assertion。

### P1：清理实现sign-off

1. 评审并处理CFGBVS/CONFIG_VOLTAGE。
2. 处理经过RMII bridge后失效的Taxi内部IOB属性。
3. 评审Taxi async FIFO的BRAM reset warning。
4. 补齐或合理豁免CPU_RESETN、ETH_RSTN及RMII I/O timing约束。
5. 重跑synthesis、implementation、timing、CDC、DRC，要求warnings有书面处置。

### P2：固定源硬件bring-up

1. 两次clean build并保存独立日志、bitstream hash。
2. 下载bitstream，测ETH_REFCLK/reset，确认link LED。
3. Wireshark抓取 <code>eth.type == 0x88b5</code>。
4. Scapy自动检查00..7F、长度和连续帧。
5. ILA确认underflow/overflow为0；good-frame只作FIFO提交参考。

### P3：接入Camera Pipeline

固定源hardware PASS后，用 <code>Camera_Pipeline.packet_*</code>替换发生器，先跑完整RTL回归，再构建和硬件捕获。记录每路drop、buffer occupancy、Byte FIFO level和payload序号。

### P4：旧模块处置

仅在硬件捕获成功且两次clean build通过后：

1. 从活动层次断开旧模块；
2. <code>remove_files</code>但保留磁盘文件；
3. clean build并确认无引用；
4. 生成待删清单；
5. 等用户确认后再删除。

## 最终判定

| 目标 | 状态 |
|---|---|
| Taxi依赖缺失为0、可独立展开 | PASS |
| Frame Adapter握手/stall单元验证 | PASS |
| Camera Pipeline基本功能仿真 | PASS（有限） |
| 固定源Ethernet route | PASS |
| clean methodology/DRC | FAIL |
| 完整Camera→Ethernet活动层次 | PENDING |
| 线级RMII内容验证 | PENDING |
| PHY link/Wireshark/连续payload | PENDING |
| 两次clean build | PENDING |


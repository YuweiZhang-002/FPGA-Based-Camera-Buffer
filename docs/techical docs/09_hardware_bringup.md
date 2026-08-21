# 09 硬件 Bring-up

## 当前状态

没有本地证据显示已生成/下载 bitstream、PHY link LED亮、PC捕获到88B5帧，或硬件上读取过 underflow/overflow。因此本页所有实测结果均为 PENDING；以下是可执行验收流程，不是已完成记录。

## 阶段1：固定帧

当前活动顶层已经是：

<code>Fixed_Packet_Generator → Frame Adapter → Taxi → MII/RMII bridge → ETH_*</code>

固定 payload为00..7F。完成 DRC/约束清理后：

1. 生成 bitstream并下载到 Nexys A7-50T。
2. 用直连网线或100M兼容交换机连接PC。
3. 确认 <code>ETH_REFCLK</code>为50 MHz，<code>ETH_RSTN</code>在约10.5 ms后释放。
4. 观察 PHY link LED；记录板卡、PHY LED状态、PC网卡协商速度。
5. 开始抓包，再复位FPGA。

## Wireshark

选择与板卡连接的有线网卡，capture filter可留空；display filter：

<code>eth.type == 0x88b5</code>

每个正确帧应显示：

- Destination：ff:ff:ff:ff:ff:ff
- Source：02:00:00:00:00:02
- Type：0x88b5
- Payload：128 byte，00 01 ... 7f
- 捕获长度通常为142 byte（网卡剥离FCS）或146 byte（驱动保留4-byte FCS）

不得把是否显示FCS的差异误判为帧长不一致；先确认PC网卡/驱动的FCS捕获行为。

## Scapy 检查

示例只用于PC侧验证，不会向工程写入内容：

~~~python
from scapy.all import Ether, Raw, sniff

expected = bytes(range(128))
count = 0

def check(pkt):
    global count
    if Ether not in pkt or pkt[Ether].type != 0x88B5:
        return
    payload = bytes(pkt[Ether].payload)
    ok = payload == expected
    count += 1
    print(f"frame={count} len={len(payload)} payload_ok={ok} "
          f"src={pkt[Ether].src} dst={pkt[Ether].dst}")
    if not ok:
        print(payload.hex(" "))

sniff(iface="Ethernet", filter="ether proto 0x88b5", prn=check, store=False)
~~~

把 <code>iface</code>替换为本机实际网卡名。原始Ethernet不依赖IP地址；关闭防火墙通常不是抓取二层帧的必要条件，但网卡的节能、EEE、VLAN/offload可能影响观察，应记录配置。

## 阶段2：接 Byte_FIFO

只有固定帧在PC端稳定通过后，才把顶层packet源替换为 <code>Camera_Pipeline.packet_*</code>。此变更尚未发生。

验收：

1. 对camera packet设置可识别序号。
2. Wireshark/Scapy检查每帧128-byte payload长度。
3. 检查序号连续；若不连续，同步记录各Line Buffer drop计数、Byte FIFO level、Taxi overflow。
4. 使用ILA同时采样 Frame Adapter AXIS和 <code>tx_error_underflow</code>、<code>tx_fifo_overflow</code>、<code>tx_fifo_good_frame</code>。

## 阶段3：反压

硬件或增强RTL仿真中制造 <code>frame_ready=0</code>窗口，检查：

- stalled周期 <code>frame_valid</code>保持1；
- <code>frame_data</code>不变；
- <code>frame_last</code>不变；
- 只有最后byte真实握手才结束帧；
- Byte FIFO最终无无法解释的积压。

当前只有 Frame Adapter单元TB满足上述stability assertion；完整链仍 PENDING。

## 硬件验收记录模板

| 项目 | 状态 | 记录/附件 |
|---|---|---|
| bitstream生成 | PENDING | bit文件hash、构建日志 |
| FPGA下载 | PENDING | 时间、工具输出 |
| ETH_REFCLK 50 MHz | PENDING | 示波器截图 |
| ETH_RSTN正确释放 | PENDING | 示波器/ILA |
| link LED正常 | PENDING | 照片、协商速率 |
| 0x88B5持续捕获 | PENDING | pcap |
| DST/SRC正确 | PENDING | pcap解析 |
| payload 00..7F | PENDING | Scapy输出 |
| 长度一致 | PENDING | 抓包统计 |
| payload序号连续 | PENDING | 接Camera后统计 |
| tx_error_underflow=0 | PENDING | ILA/寄存器记录 |
| tx_fifo_overflow=0 | PENDING | ILA/寄存器记录 |
| 两次 clean build | PENDING | 两份独立日志/hash |

## 安全判读

- <code>tx_fifo_good_frame</code>跳变：只说明完整帧在Taxi TX FIFO写侧提交。
- route PASS：只说明网表完成布线。
- link LED：只说明物理链路协商，不能证明帧内容正确。
- Wireshark捕获并通过payload/FCS相关检查：才是本阶段目标的硬件数据证据。


# 第三方通知与许可边界

仓库根目录的 BSD 3-Clause License 仅适用于
FPGA-Based-Camera-Buffer 中由项目作者原创的内容；如果文件或目录另有
声明，则以该声明为准。该许可证不会重新授权外部 HDL、厂商 IP、开发
工具，或包含这些组件的生成产物。

当前 Ethernet 构建会把下列 HDL 项目作为独立的本地 Git 仓库获取。
第三方源码目录已被 `.gitignore` 排除，不会被内嵌进本仓库。

| 组件 | 上游与固定版本 | 许可证 | 与本项目直接相关的条件 |
|---|---|---|---|
| FPGA Ninja TAXI | `https://github.com/fpganinja/taxi.git`，提交 `bc4a6d3f2aa30156267ad279682e66d99558a633` | CERN-OHL-S-2.0，另有独立商业许可 | 必须保留上游通知。传递受许可约束的源码或产品时，强互惠条款可能要求提供完整的对应设计源码；修改或扩展的受覆盖设计也必须遵守上游条件。如无法接受，应向 FPGA Ninja 咨询商业许可。 |
| FPGA-RMII-SMII | `https://github.com/WangXuan95/FPGA-RMII-SMII.git`，提交 `5fef5b5641029777655c5fc34228c3a8b13e4ac9` | GPL-3.0 | 必须保留版权与许可通知。重新分发受覆盖源码、修改版本或受覆盖的组合工作时，必须履行 GPL-3.0 对源码和许可的要求。 |

复刻流程把它们分别克隆到 `third_party/taxi/` 和
`third_party/FPGA-RMII-SMII/`。重新分发前必须读取固定提交中的完整
许可证；本文件的表格不能替代原始许可文本。

## Xilinx/Vivado 材料

Vivado、Xilinx/AMD 器件库、调试核与生成 IP 属于外部厂商材料，遵循
相应厂商条款。历史目录 `project_camera.srcs/` 含 Xilinx FIFO Generator
的 `.xci` 描述。BSD 3-Clause License 不会授予对 Xilinx IP、Vivado、
器件模型、DCP 或其他厂商生成内容的权利。

本仓库 Tcl 脚本在没有其他声明时属于原创自动化代码，但脚本生成的结果
可能同时包含 TAXI、RMII 与 Xilinx 的独立许可组件。

## Bitstream 与其他组合产物

本仓库有意排除 `.bit`、`.ltx`、DCP、Vivado run 和 cache。不得将整合
bitstream 描述为仅受 BSD-3-Clause 许可。分发 bitstream 或其他组合硬件
产物前，必须重新核对 TAXI、RMII 与 Xilinx 条款，并提供要求的对应材料
与通知。特定产品中强互惠硬件与软件许可是否兼容，需要单独审查。

## 外部分析工具

MATLAB、Python、PowerShell、Git 和 Vivado 均由使用者自行获取，本仓库
不分发这些工具。Host 接收与标定系统位于独立仓库，其原创内容采用 BSD
3-Clause，并具有独立的第三方通知。

## 重新分发检查表

1. 确认 `third_party/` 下只有 `third_party/README.md` 被 FPGA 仓库跟踪。
2. 记录实际构建使用的 TAXI 与 FPGA-RMII-SMII 精确提交。
3. 保留全部上游版权、许可和修改通知。
4. 未获得许可时，不打包 Vivado、Npcap 或第三方 Git 源码树。
5. 分发整合 bitstream 或商业产品前，再次执行许可审查。

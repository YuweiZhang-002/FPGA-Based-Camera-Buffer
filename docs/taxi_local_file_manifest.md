# Taxi 本地文件与依赖清单

审阅日期：2026-07-20  
允许加入工程的 Taxi 根目录：`D:/prg/prg_cam/prg_cam.srcs/sources_1/lib/taxi-master`

## 结论

- 首选入口：`eth/rtl/taxi_eth_mac_mii_fifo.f`。
- 递归结果：8 个 `.f`、26 个唯一 RTL、16 个本地路径重映射。
- `Missing dependency = 0`，`Missing instances = <empty>`。
- 26/26 个闭包 RTL 与本机既有、位于 commit `bc4a6d3f2aa30156267ad279682e66d99558a633` 的参考树逐行一致（忽略 CRLF/LF）。工程编译只使用 `lib/taxi-master`，参考树未加入工程。
- 原始 `.f` 未批量修改；失效的 `../lib/taxi/src/...` 路径由 `scripts/add_taxi_sources.tcl` 按本地唯一文件名重映射。
- 没有联网下载，没有移动、重命名或删除 `lib` 文件。
- 根 `.gitignore` 已与本地备份 `.github-sync/FPGA-Based-Camera-Buffer/.gitignore` 逐行恢复一致；`taxi-master/.gitignore` 和既有参考树 `.gitignore` 均保留。

## 实际目录树

`taxi-master` 共 1140 个文件：245 个 `.sv`、48 个 `.f`、1 个 `LICENSE*`、28 个 `README*`；没有 `.v/.vh/.svh`。

```text
taxi-master/
├── .github/   1 file
├── axis/     81 files, 38 SV,  7 F
├── docs/      7 files
├── eth/     995 files, 179 SV, 41 F
├── io/       12 files, 12 SV
├── lfsr/     18 files,  6 SV
├── prim/      2 files,  2 SV
├── stats/    13 files,  6 SV
├── sync/      4 files,  2 SV
├── LICENSE
└── README.md
```

本地 Ethernet bridge 位于同一 `lib` 下，但不是 Taxi 闭包：

```text
FPGA-RMII-SMII-main/
└── RTL/
    ├── rmii_phy_if.v   # 本工程使用
    └── smii_phy_if.v   # Nexys A7 首版不使用
```

## 分类

### Entry

- `eth/rtl/taxi_eth_mac_mii_fifo.f`
- `eth/rtl/taxi_eth_mac_mii_fifo.sv`

### Transitive dependency

Filelist：

- `axis/rtl/taxi_axis_arb_mux.f`
- `axis/rtl/taxi_axis_async_fifo.f`
- `axis/rtl/taxi_axis_async_fifo_adapter.f`
- `eth/rtl/taxi_eth_mac_1g.f`
- `eth/rtl/taxi_eth_mac_mii.f`
- `eth/rtl/taxi_eth_mac_stats.f`
- `eth/rtl/taxi_mii_phy_if.f`

RTL：

- `axis/rtl/`: `taxi_axis_adapter.sv`, `taxi_axis_arb_mux.sv`, `taxi_axis_async_fifo.sv`, `taxi_axis_async_fifo_adapter.sv`, `taxi_axis_if.sv`, `taxi_axis_null_src.sv`, `taxi_axis_pad.sv`, `taxi_axis_tie.sv`
- `eth/rtl/`: `taxi_axis_gmii_rx.sv`, `taxi_axis_gmii_tx.sv`, `taxi_eth_mac_1g.sv`, `taxi_eth_mac_mii.sv`, `taxi_eth_mac_mii_fifo.sv`, `taxi_eth_mac_stats.sv`, `taxi_mac_ctrl_rx.sv`, `taxi_mac_ctrl_tx.sv`, `taxi_mac_pause_ctrl_rx.sv`, `taxi_mac_pause_ctrl_tx.sv`, `taxi_mii_phy_if.sv`
- `io/rtl/`: `taxi_ssio_sdr_in.sv`
- `lfsr/rtl/`: `taxi_lfsr.sv`
- `prim/rtl/`: `taxi_arbiter.sv`, `taxi_penc.sv`
- `stats/rtl/`: `taxi_stats_collect.sv`
- `sync/rtl/`: `taxi_sync_reset.sv`, `taxi_sync_signal.sv`

其中 `prim/rtl/taxi_arbiter.sv` 与 `taxi_penc.sv` 是首次完整递归后仅余的两个缺口；它们从本机已有的固定 commit 参考树恢复到 `lib/taxi-master/prim/rtl`，并逐行校验一致。未使用网络。

### Optional

- `taxi-master/eth/tb/**`、`example/**` 和文档。
- 未被入口闭包引用的 GMII/RGMII/Base-X/10G/25G RTL。
- `FPGA-RMII-SMII-main/RTL/smii_phy_if.v`；Nexys A7 使用 RMII。

### Duplicate

- 26-file 闭包内：0 个重复 module/interface 定义。
- 整个 `lib` 若无选择递归加入，会包含大量不同板卡的 `fpga`、`fpga_core`、testbench 等同名定义，因此禁止这样做。

### Missing dependency

- 无。机器生成依据见 `docs/taxi_compile_manifest.txt` 的 `MISSING_OR_AMBIGUOUS (0)`。
- Vivado 依据见 `docs/taxi_unresolved_references.rpt` 与 `docs/ethernet_bringup_missing_instances.rpt` 的 `< empty >`。

### Legacy candidate

- `eth/example/**`、`eth/tb/**`。
- 与 Artix-7 MII 首测无关、且不在 26-file 闭包内的 Taxi RTL。
- 这些仅为未来候选；本轮没有删除或 `remove_files`。

### Do not delete

- 整个 `prg_cam.srcs/sources_1/lib`，包括许可证、README、Taxi 与 FPGA-RMII-SMII。
- 26 个 Entry/Transitive dependency RTL 和 8 个 filelist。
- `Byte_FIFO.v` 与现有 Camera pipeline。
- 现有 AXI4_Compiler、MIG、SmartConnect、DMA、Send_Control、System_RefControl 及其生成物。

完整逐项路径和 16 条重映射见 `docs/taxi_compile_manifest.txt`。

# Third-Party Notices

This repository contains third-party HDL components. They are not original
PRG_CAM work and remain under their respective upstream licenses.

## fpganinja/taxi

- Upstream: https://github.com/fpganinja/taxi
- Local copy used by the Vivado project: `prg_cam.srcs/sources_1/lib/taxi-master`
- License: CERN Open Hardware Licence Version 2 - Strongly Reciprocal
  (CERN-OHL-S-2.0)
- License text: `prg_cam.srcs/sources_1/lib/taxi-master/LICENSE`
- Build entry point: `scripts/add_taxi_sources.tcl`
- Current closure: 26 RTL files, recorded in `docs/taxi_compile_manifest.txt`
- Local snapshot commit: `e93a639186366d4fe67df509588892ff8a1d4b2d`
  (`imported-snapshot`; local import commit, not an upstream commit)
- Local modifications: not yet independently audited against a pinned upstream
  commit.

Taxi's upstream README states that some components may use less restrictive
licenses. The SPDX/header and license information of each file in the actual
closure must therefore be preserved and reviewed individually.

## WangXuan95/FPGA-RMII-SMII

- Upstream: https://github.com/WangXuan95/FPGA-RMII-SMII
- Local copy: `prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main`
- Used file: `RTL/rmii_phy_if.v`
- License: GNU General Public License, Version 3 (GPL-3.0)
- License text: `prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main/LICENSE`
- Build reference: `scripts/add_ethernet_bringup_sources.tcl`
- Local snapshot commit: `bbe49034cbe590d1dc6fd3b2bb48defdd8b6891f`
  (`imported-snapshot`; local import commit, not an upstream commit)
- Local modifications to `rmii_phy_if.v`: none identified; the project adds
  reset-domain glue in `Ethernet_Mii_Rmii_Bridge.sv`.
- The sibling `RTL/smii_phy_if.v` is not instantiated by the current design.

## Distribution status

The project-level license for original PRG_CAM material is intentionally not
declared yet. CERN-OHL-S and GPL-3.0 obligations and their interaction in the
combined FPGA design require a separate legal review before commercial
distribution, bitstream distribution, or a single repository-wide license is
chosen.
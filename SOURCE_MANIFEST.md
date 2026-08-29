# Source Manifest

This file records the local identity of the third-party sources used by the
current Vivado design. It is an audit record, not a replacement for either
upstream license.

## Current integration

| Component | Used path | Build reference | License |
|---|---|---|---|
| fpganinja/taxi | `prg_cam.srcs/sources_1/lib/taxi-master` | `scripts/add_taxi_sources.tcl` | CERN-OHL-S-2.0, with per-file exceptions possible |
| FPGA-RMII-SMII | `prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main/RTL/rmii_phy_if.v` | `scripts/add_ethernet_bringup_sources.tcl` | GPL-3.0 |

## Recorded SHA256 values

These values describe the current working-tree files and must be regenerated
after any source update:

| File | SHA256 |
|---|---|
| `prg_cam.srcs/sources_1/lib/taxi-master/LICENSE` | `253AD3F89603E728ABFA60C36FBCAF8225CF55C1EAB12725F19FB3D74D647F3A` |
| `prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main/LICENSE` | `81CBAE84A29CE7E770BF2BC7B178E50BDA0CE8DE6067ABA661B0BC7B05B562F8` |
| `prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main/RTL/rmii_phy_if.v` | `3E2309A546E691894D099D7A00564A5F7A3CEF4584F613CD7264A2DFD32EB8B4` |
| `prg_cam.srcs/sources_1/new/Ethernet_Mii_Rmii_Bridge.sv` | `40513D98343F69EE12A3D63BD5CE66ECC492B4115B06C6C08A200EAAA8C3BA5A` |
| `scripts/add_taxi_sources.tcl` | `39CF6775598B1BC32EF26901F6E952DC9A937FC682D1068AD63E3A6E987D8C33` |
| `scripts/add_ethernet_bringup_sources.tcl` | `20476C4E0AAC1E50768620302B867FB84A9B7B8FA33BD0993150C0D5062CCF32` |
| `docs/taxi_compile_manifest.txt` | `99B74652EA83D39DDE55B9C12C5BEE1C68571F7708339675FC9F33B27C983A94` |

## Version status

The active copied trees now contain nested Git repositories on the local
`imported-snapshot` branch. These are local import commits, not claims about
the upstream history:

- Taxi import snapshot: `e93a639186366d4fe67df509588892ff8a1d4b2d`
- FPGA-RMII-SMII import snapshot: `bbe49034cbe590d1dc6fd3b2bb48defdd8b6891f`

The exact upstream commit/tag is still **not verified**. Before a release,
fetch or recreate the copies from pinned upstream commits, record those
upstream IDs here, and compare the complete build closure with the recreated
copies.

An additional `third_party/taxi` tree exists locally but is not referenced by
the current Vivado project. It must not be treated as an active dependency
without an explicit build-file change and a separate audit.
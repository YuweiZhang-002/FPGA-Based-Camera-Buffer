# PRG_CAM

This repository is the public-facing project boundary for the original PRG_CAM design and documentation work.

## Repository scope

The public repository intentionally excludes vendor and third-party source trees that are imported into the local Vivado workflow. Those sources remain outside the public publishable tree and are tracked only in local development copies.

Excluded from public publication:

- `third_party/`
- `prg_cam.srcs/sources_1/lib/`
- `project_camera.srcs/`

The project keeps licensing records in:

- `THIRD_PARTY_NOTICES.md`
- `SOURCE_MANIFEST.md`

## Licensing status

This repository does not currently declare a single project-wide public license for all content.

The public repository contains original PRG_CAM material, but the local design also incorporates third-party HDL and IP sources that are subject to their own upstream licenses, including at minimum:

- CERN-OHL-S-2.0 (for `fpganinja/taxi`)
- GPL-3.0 (for `WangXuan95/FPGA-RMII-SMII`)

Because these dependencies are not yet fully reconciled to a single repository-level release model, distribution of the complete local design, complete third-party closure, or bitstream artifacts should be treated as a separate legal review item before public or commercial release.

## Public release policy

This repository is intended to publish:

- original project documentation
- original design notes and reports
- public-facing architecture summaries
- audit records and third-party notice files

This repository is not intended to publish:

- imported third-party source trees
- vendored IP libraries
- generated Vivado build artifacts
- local simulation and implementation outputs

## Contact / review note

Before any commercial distribution, full upstream redistribution, or combined public release of the complete FPGA design closure, the project should undergo a formal license review and a pinning audit of all imported upstream sources.

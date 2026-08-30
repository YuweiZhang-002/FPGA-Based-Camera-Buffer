# Third-party notices and licence boundary

The repository-root BSD 3-Clause License applies only to original material
authored for FPGA-Based-Camera-Buffer, unless a file or directory carries a
different notice. It does not relicense external HDL, vendor IP, development
tools, Python packages, or generated products that include those components.

The active Ethernet build deliberately obtains the following HDL projects as
separate local Git repositories. Their source trees are ignored and are not
vendored into this repository.

| Component | Upstream and pinned revision | Licence | Conditions relevant to this project |
|---|---|---|---|
| FPGA Ninja TAXI | `https://github.com/fpganinja/taxi.git` at `bc4a6d3f2aa30156267ad279682e66d99558a633` | CERN-OHL-S-2.0, with a separately available commercial licence | Preserve upstream notices. The strongly reciprocal licence can require complete corresponding design source when covered source or products are conveyed. Modified or extended covered design material must follow the upstream terms. Contact FPGA Ninja for commercial licensing if those terms are unsuitable. |
| FPGA-RMII-SMII | `https://github.com/WangXuan95/FPGA-RMII-SMII.git` at `5fef5b5641029777655c5fc34228c3a8b13e4ac9` | GPL-3.0 | Preserve copyright and licence notices. Redistribution of covered source or modified/combined covered works must satisfy GPL-3.0 source and licensing obligations. |

The repositories are cloned into `third_party/taxi/` and
`third_party/FPGA-RMII-SMII/` by the documented reproduction flow. Consult
their licence files at the pinned revisions before redistribution; this
summary is not a substitute for the licence texts.

## Xilinx/Vivado material

Vivado, the Xilinx/AMD device libraries, debug cores, and generated IP are
external vendor material governed by their applicable vendor terms. The
historical `project_camera.srcs/` tree contains Xilinx FIFO Generator `.xci`
descriptions. The BSD 3-Clause License does not grant rights in Xilinx IP,
Vivado, device models, DCPs, or other vendor-generated content.

Tcl scripts in this repository are original automation unless marked
otherwise, but executing them can produce outputs that incorporate separately
licensed TAXI, RMII, and Xilinx components.

## Bitstreams and other combined products

The repository intentionally excludes generated `.bit`, `.ltx`, DCP, Vivado
run, and cache artifacts. Do not describe an integrated bitstream as being
licensed solely under BSD-3-Clause. Before distributing a bitstream or another
combined hardware product, review all applicable TAXI, RMII, and Xilinx terms
and provide the required corresponding material and notices. Compatibility of
the strong reciprocal hardware and software licences for a particular product
is a distribution decision that requires separate review.

## External analysis tools

MATLAB, Python, PowerShell, Git, and Vivado are user-supplied tools and are not
distributed by this repository. The Host receiver and calibration system is a
separate repository with its own BSD 3-Clause License and third-party notices.

## Redistribution checklist

Before publishing a source archive or release:

1. Confirm that only `third_party/README.md` is tracked under `third_party/`.
2. Record the exact TAXI and FPGA-RMII-SMII revisions used by the build.
3. Retain every upstream copyright, licence, and modification notice.
4. Do not bundle Vivado, Npcap, or third-party Git trees without permission.
5. Review the licences again before distributing an integrated bitstream or a
   commercial product.

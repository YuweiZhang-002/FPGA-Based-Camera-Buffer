# Current FIFO/BRAM Vivado Sources

This directory contains the current four-camera FPGA packet-buffer implementation.

```text
prg_cam.srcs/
├── sources_1/new/
│   ├── Camera_Pipeline.v       synthesis top
│   ├── Alarmer.v               pclk edge synchronizer
│   ├── Camera_Capture.v        8-bit camera packet capture
│   ├── Line_Buffer.v           4 x 128-byte packet ring per camera
│   ├── Arbitration.v           four-way packet round robin
│   ├── Byte_Replacer.v         cam_id/flags patch and CRC-16
│   ├── Byte_FIFO.v             final 9-bit output FIFO
│   ├── System_ClkControl.v     optional board reset utility
│   └── deprecated/             archived, macro-disabled legacy RTL
└── sim_1/new/
    ├── tb_Camera_Pipeline.sv
    ├── tb_Arbitration.sv
    └── tb_Line_Buffer.sv
```

The active data path is:

```text
4 x (Camera_Capture -> Line_Buffer)
    -> Arbitration -> Byte_Replacer -> Byte_FIFO
```

Run the standalone Vivado out-of-context synthesis from the repository root:

```tcl
vivado -mode batch -nolog -nojournal -source scripts/synth_fifo_pipeline.tcl
```

See [`../docs/fpga_module_structure.md`](../docs/fpga_module_structure.md) for the complete port, state-machine, packet-layout and verification description.

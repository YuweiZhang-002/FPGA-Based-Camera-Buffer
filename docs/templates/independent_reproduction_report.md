# PRG_CAM independent reproduction report

> Copy this template into the tester's immutable run directory. Do not edit the
> repository copy to record a result.

## Tester and environment

| Field | Value |
|---|---|
| Tester | `<name>` |
| UTC start/end | `<timestamps>` |
| Prior PRG_CAM implementation involvement | `none / describe` |
| Undocumented help received | `none / describe exact help and time>` |
| Machine/OS | `<identity>` |
| FPGA board / serial | `<identity>` |
| MCU/camera hardware IDs | `<identity>` |
| Vivado / Python / Npcap versions | `<versions>` |

## Frozen identity

| Evidence | Path | SHA-256 / commit | Result |
|---|---|---|---|
| bootstrap manifest | `<path>` | `<sha256>` | `VERIFIED / MISMATCH` |
| run manifest | `<path>` | `<sha256>` | `VERIFIED / MISMATCH` |
| MCU UF2 | `<path>` | `<sha256>` | `VERIFIED / NOT RUN` |
| FPGA bit | `<path>` | `<sha256>` | `VERIFIED / NOT RUN` |
| FPGA LTX | `<path>` | `<sha256>` | `VERIFIED / NOT RUN` |
| Host HEAD | `<repo>` | `<commit>` | `VERIFIED / MISMATCH` |

## Gate results

| Gate | Expected | Observed | Evidence path | Result |
|---|---|---|---|---|
| source closure | five pinned clean repositories | | | `PASS/FAIL/NOT RUN` |
| Host golden positive | valid=960, CRC=0, two complete frames | | | `PASS/FAIL/NOT RUN` |
| Host golden negative | valid=0, CRC=1 | | | `PASS/FAIL/NOT RUN` |
| MCU build/program | documented completion marker and UF2 hash | | | `PASS/FAIL/NOT RUN` |
| FPGA synthesis | no unresolved/black-box source | | | `PASS/FAIL/NOT RUN` |
| FPGA implementation | timing/DRC disposition recorded | | | `PASS/FAIL/NOT RUN` |
| bit/LTX pairing | matching programmed artifacts | | | `PASS/FAIL/NOT RUN` |
| MCU packet source | packet counter greater than zero | | | `PASS/FAIL/NOT RUN` |
| FPGA capture | per-camera capture/commit greater than zero | | | `PASS/FAIL/NOT RUN` |
| FIFO/MAC/RMII | accepted handshakes and TX_EN greater than zero | | | `PASS/FAIL/NOT RUN` |
| Host wire ingress | Wireshark/Npcap EtherType 0x88B5 greater than zero | | | `PASS/FAIL/NOT RUN` |
| packet parser | parsed_ok greater than zero, protocol fields correct | | | `PASS/FAIL/NOT RUN` |
| dual-camera frames | cam0 and cam1 complete frames greater than zero | | | `PASS/FAIL/NOT RUN` |
| publication | PGM and rows CSV correspond to the same run | | | `PASS/FAIL/NOT RUN` |
| calibration, if claimed | independent holdout gates | | | `PASS/FAIL/NOT RUN` |

## First failed boundary

- Boundary: `<exact first zero/invalid gate>`
- Symptom: `<verbatim output>`
- Upstream last-known-good evidence: `<path and value>`
- Downstream checks deliberately not promoted: `<list>`
- Reproduction command: `<exact command>`

## Final decision

Choose exactly one:

- `SYSTEM_REPRODUCTION_PASS` — all claimed layers passed with current-run evidence.
- `PARTIAL_REPRODUCTION` — source/offline domains passed; physical or calibration evidence is incomplete.
- `REPRODUCTION_FAIL` — a required gate failed.

Decision: `<one value>`

Limitations and next action: `<text>`

Tester signature/date: `<text>`

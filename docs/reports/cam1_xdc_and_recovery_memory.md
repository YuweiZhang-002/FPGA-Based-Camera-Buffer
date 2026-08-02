# CAM1 XDC and receiver-recovery memory

Date: 2026-08-02

This note records the authoritative CAM1 hardware mapping and the corresponding
Python receiver diagnosis for future summaries.  It is evidence/status memory,
not a request to change RTL.

## Authoritative CAM1 data-pin mapping

The deployed cable is most convenient in the reverse direction.  The verified
FPGA compensation is a reversal within each physical four-bit group:

| Logical port | Package pin | Physical connector/data line |
|---|---|---|
| `GPIO_CAM1[0]` | `G6` | `JC4`, physical D3 |
| `GPIO_CAM1[1]` | `J2` | `JC3`, physical D2 |
| `GPIO_CAM1[2]` | `F6` | `JC2`, physical D1 |
| `GPIO_CAM1[3]` | `K1` | `JC1`, physical D0 |
| `GPIO_CAM1[4]` | `E6` | `JC10`, physical D7 |
| `GPIO_CAM1[5]` | `J4` | `JC9`, physical D6 |
| `GPIO_CAM1[6]` | `J3` | `JC8`, physical D5 |
| `GPIO_CAM1[7]` | `E7` | `JC7`, physical D4 |

In compact form:

```text
logical [3:0] <- physical [0:3]
logical [7:4] <- physical [4:7]
```

Do not revert this to the earlier adjacent-pair swap
`D0<->D1, D2<->D3, D4<->D5, D6<->D7`.  Both permutations happen to transform
the sync sample `5A 50 A5 A0` into `A5 A0 5A 50`, so the sync words alone are
not sufficient to identify the correct bus permutation.  The payload is the
discriminator.

Hardware evidence:

- `images/temp/archive/new_attempt/attempt1/cam1`: the earlier adjacent-pair
  mapping produced approximately 45% errors with a strong periodic pattern.
- `images/temp/archive/new_attempt/attempt2/cam1`: the current full-nibble
  reversal produces normal data and is the verified mapping to retain.

PCLK remains `GPIO_CAM1[8] = H4/JD1`; HREF remains
`GPIO_CAM1[9] = H2/JD7`.

## Python recovery diagnosis

The receiver does not have a CAM0-only recovery switch.  `FrameReassembler`
keys sessions by `(cam_id, frame_id)`, and `CameraImagePipeline.archive_frame`
applies one global `ImagePolicy` and the same recovery thresholds to every
camera.  Output routing is derived from `frame.camera_id`, so an eligible CAM1
frame would be written under `cam1/recovered/frame_<id>/`.

The launch template defaults to `ImagePolicy=strict`; recovery must be enabled
with `recover-zero-fill`.  The presence of `attempt2/cam1/rejected.csv` proves
that recovery mode was enabled for that run, because strict mode does not write
recovery rejection records.

Observed `attempt2/cam1` evidence:

- 405,208 packet records.
- 405,089 `parse_ok` packets (approximately 99.971%).
- 591 COMPLETE images.
- 440 non-complete frames assessed and rejected by the recovery gate.
- 0 RECOVERED images, because no non-complete frame satisfied all recovery
  conditions.
- 407 rejected frames had too many and consecutive missing rows.
- 31 near-candidates missed only row 255, but were CORRUPT because of
  `undefined_flag_bits`; recovery intentionally rejects Layer-3 semantic
  corruption rather than zero-filling it.

Therefore the absence of CAM1 RECOVERED output is not evidence that CAM1
recovery is disabled.  It is the result of the current strict eligibility gate
and the observed failure shapes.  Package success rate and recoverable-frame
rate are different metrics.

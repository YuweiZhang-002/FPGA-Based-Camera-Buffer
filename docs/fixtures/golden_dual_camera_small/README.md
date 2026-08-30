# Public dual-camera Host golden fixture

This directory contains synthetic, privacy-safe regression evidence. It is not
a captured laboratory trace. `golden_dual_camera_480rows.pcap` contains 960
Ethernet frames: 480 rows for cam0/frame100 and 480 rows for cam1/frame101.
Each Ethernet frame has EtherType `0x88B5`, a 128-byte camera payload, current
`A5 A0 5A 50` sync, big-endian metadata, MSB-first image bits and a valid
CRC-16/CCITT-FALSE. `golden_crc_error_single_packet.pcap` changes only the CRC
of one otherwise valid row.

The authoritative expected fields and SHA-256 values are in
`expected_results.json`. Regenerate the files only from the pinned public Host
implementation:

```powershell
$fpga = 'D:\prg\blank_project\FPGA'
$host = 'D:\prg\blank_project\Host'
$python = 'C:\Path\To\python.exe' # replace after Get-Command python
$fixtureOut = Join-Path $fpga 'docs\fixtures\golden_dual_camera_small_regenerated'

& $python (Join-Path $fpga 'scripts_py\generate_golden_host_fixture.py') `
  --host-repo $host `
  --output-root $fixtureOut
if ($LASTEXITCODE -ne 0) { throw 'fixture regeneration failed' }
```

Do not overwrite the tracked fixture. Compare the regenerated hashes first.
Run the public validator into a new, empty output directory:

```powershell
$validator = Join-Path $fpga 'scripts_ps\validate_golden_host_fixture.ps1'
$runRoot = Join-Path 'D:\prg\blank_project\runs' `
  ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_host_golden')

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator `
  -HostRepository $host `
  -PythonExe $python `
  -OutputRoot $runRoot `
  -PreflightOnly
if ($LASTEXITCODE -ne 0) { throw 'golden preflight failed' }

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator `
  -HostRepository $host `
  -PythonExe $python `
  -OutputRoot $runRoot
if ($LASTEXITCODE -ne 0) { throw 'golden validation failed' }
```

PASS is machine-readable in `golden_validation_summary.json`. It requires the
positive replay to report 960 ingress/matching/valid packets, zero CRC errors,
one complete PGM and 480 CSV rows per camera. The negative replay must report
one ingress packet, zero valid packets and one CRC error.

This proves the Host parser, CRC decision, camera split, reassembler, CSV and
PGM publication against a known input. It proves nothing about MCU GPIO, FPGA
capture, RMII, PHY, NIC, Npcap or physical dual-camera timing. Promoting this
PASS to a hardware PASS violates the project evidence rule.

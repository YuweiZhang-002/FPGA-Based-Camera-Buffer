# External Ethernet dependency closure

This directory is the fixed local landing zone for dependencies that are not
vendored into this repository.  Only this manifest is tracked.  The cloned
subdirectories remain ignored Git repositories.

| Directory | Upstream | Reproduction commit | License reported upstream |
|---|---|---|---|
| `taxi/` | `https://github.com/fpganinja/taxi.git` | `bc4a6d3f2aa30156267ad279682e66d99558a633` | CERN-OHL-S-2.0 |
| `FPGA-RMII-SMII/` | `https://github.com/WangXuan95/FPGA-RMII-SMII.git` | `5fef5b5641029777655c5fc34228c3a8b13e4ac9` | GPL-3.0 |

Install from the FPGA repository root:

```powershell
git clone https://github.com/fpganinja/taxi.git third_party/taxi
git -C third_party/taxi checkout bc4a6d3f2aa30156267ad279682e66d99558a633

git clone https://github.com/WangXuan95/FPGA-RMII-SMII.git third_party/FPGA-RMII-SMII
git -C third_party/FPGA-RMII-SMII checkout 5fef5b5641029777655c5fc34228c3a8b13e4ac9
```

The active first-party wrapper uses `taxi/src/...` and
`FPGA-RMII-SMII/RTL/rmii_phy_if.v`.  Do not copy old `taxi-master/eth/...`
paths from archived documents: current TAXI places synthesizable sources under
`src/`.

Verify both identity and files before Vivado:

```powershell
$dependencyRows = @(
  [pscustomobject]@{
    Name = 'taxi'
    Expected = 'bc4a6d3f2aa30156267ad279682e66d99558a633'
    Actual = git -C third_party/taxi rev-parse HEAD
    Required = Test-Path third_party/taxi/src/eth/rtl/taxi_eth_mac_mii_fifo.f
  }
  [pscustomobject]@{
    Name = 'FPGA-RMII-SMII'
    Expected = '5fef5b5641029777655c5fc34228c3a8b13e4ac9'
    Actual = git -C third_party/FPGA-RMII-SMII rev-parse HEAD
    Required = Test-Path third_party/FPGA-RMII-SMII/RTL/rmii_phy_if.v
  }
)
$dependencyRows | Format-Table -AutoSize
if (@($dependencyRows | Where-Object {
  $_.Actual -ne $_.Expected -or -not $_.Required
}).Count -ne 0) {
  throw 'Third-party dependency identity check failed'
}
```

Cloning does not relicense these projects as part of PRG_CAM.  Review each
upstream license before redistribution, and never use `git add -f` on a cloned
dependency directory.

The repository-root BSD 3-Clause License applies only to first-party authored
material. TAXI remains CERN-OHL-S-2.0 (or its separately available commercial
licence), while FPGA-RMII-SMII remains GPL-3.0. See
`../THIRD_PARTY_NOTICES.md` for the redistribution boundary, including the
warning that an integrated bitstream must not be described as BSD-only.

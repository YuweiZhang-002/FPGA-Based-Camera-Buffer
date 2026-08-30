# External build dependencies

The FPGA repository does not vendor TAXI or the RMII bridge. A clone becomes
buildable only after the two upstream repositories are installed at the fixed
paths below. Exact commits are frozen so a future upstream directory change
cannot silently alter the synthesis closure.

## Required layout and identities

```text
FPGA-Based-Camera-Buffer/
└── third_party/
    ├── README.md                         tracked pin manifest
    ├── taxi/                             ignored upstream clone
    │   └── src/eth/rtl/taxi_eth_mac_mii_fifo.f
    └── FPGA-RMII-SMII/                   ignored upstream clone
        └── RTL/rmii_phy_if.v
```

| Dependency | Commit |
|---|---|
| TAXI | `bc4a6d3f2aa30156267ad279682e66d99558a633` |
| FPGA-RMII-SMII | `5fef5b5641029777655c5fc34228c3a8b13e4ac9` |

## Install from a cold clone

```powershell
$fpgaRoot = 'D:\prg\blank_project\FPGA-Based-Camera-Buffer'
Set-Location $fpgaRoot

git clone https://github.com/fpganinja/taxi.git third_party/taxi
git -C third_party/taxi checkout bc4a6d3f2aa30156267ad279682e66d99558a633

git clone https://github.com/WangXuan95/FPGA-RMII-SMII.git third_party/FPGA-RMII-SMII
git -C third_party/FPGA-RMII-SMII checkout 5fef5b5641029777655c5fc34228c3a8b13e4ac9
```

Do not copy the historical `prg_cam.srcs/sources_1/lib/taxi-master/eth`
layout. The pinned TAXI checkout uses `third_party/taxi/src`.

## Empty-pipeline-safe precheck

```powershell
$requiredFiles = @(
  'third_party\taxi\src\eth\rtl\taxi_eth_mac_mii_fifo.f',
  'third_party\FPGA-RMII-SMII\RTL\rmii_phy_if.v'
)

$missingFiles = @(
  foreach ($relativePath in $requiredFiles) {
    $candidate = Join-Path $fpgaRoot $relativePath
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) {
      $candidate
    }
  }
)

if ($missingFiles.Count -gt 0) {
  $missingFiles | ForEach-Object {
    Write-Host "Missing: $_" -ForegroundColor Red
  }
  throw 'External Ethernet dependency precheck failed'
}
Write-Host 'External Ethernet dependency precheck: PASS' -ForegroundColor Green
```

The `@(...)` assignments make both `.Count` values well-defined even when the
loop emits no object; this is the project convention for avoiding an
empty-pipeline failure.

## Consumers

- `scripts/add_taxi_sources.tcl` resolves the TAXI file-list closure.
- `scripts/add_ethernet_bringup_sources.tcl` adds the first-party wrappers and
  `third_party/FPGA-RMII-SMII/RTL/rmii_phy_if.v`.
- `scripts/taxi_mii_fifo_vlog.prj` uses repository-relative paths and must be
  invoked with the FPGA repository as the current directory.
- `scripts_ps/run_ethernet_ila.ps1` checks both dependency files before Build
  and PlainBit actions.

## Publication boundary

Only `third_party/README.md` is tracked. Before publishing:

```powershell
git status --short
$trackedThirdParty = @(git ls-files third_party)
$trackedThirdParty
if (@($trackedThirdParty | Where-Object {
  $_ -ne 'third_party/README.md'
}).Count -ne 0) {
  throw 'Third-party source was accidentally staged'
}
```

Each upstream project retains its own copyright and license. The FPGA
repository currently has no top-level license; that governance decision is
not inferred or filled in by the build scripts.

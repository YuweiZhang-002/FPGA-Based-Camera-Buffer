# External build dependencies

This FPGA repository intentionally does not vendor third-party source code. The Vivado Tcl scripts resolve two local dependency trees by fixed repository-relative paths.

## Required layout

```text
prg_cam.srcs/
└── sources_1/
    └── lib/
        ├── taxi-master/
        │   └── eth/rtl/taxi_eth_mac_mii_fifo.f
        └── FPGA-RMII-SMII-main/
            └── RTL/rmii_phy_if.v
```

The corresponding consumers are:

- `scripts/add_taxi_sources.tcl` → `prg_cam.srcs/sources_1/lib/taxi-master`
- `scripts/add_ethernet_bringup_sources.tcl` → `prg_cam.srcs/sources_1/lib/FPGA-RMII-SMII-main`

## PowerShell setup

Run from the FPGA repository root. The explicit destination names are important because the Tcl scripts use them literally.

```powershell
$repo = (Get-Location).Path
$libRoot = Join-Path $repo 'prg_cam.srcs\sources_1\lib'
New-Item -ItemType Directory -Force -Path $libRoot | Out-Null

git clone https://github.com/fpganinja/taxi.git `
  (Join-Path $libRoot 'taxi-master')

git clone https://github.com/WangXuan95/FPGA-RMII-SMII.git `
  (Join-Path $libRoot 'FPGA-RMII-SMII-main')
```

If the directories were downloaded as ZIP archives instead, extract and rename them to those exact directory names.

## Precheck

```powershell
$required = @(
  'prg_cam.srcs\sources_1\lib\taxi-master\eth\rtl\taxi_eth_mac_mii_fifo.f',
  'prg_cam.srcs\sources_1\lib\FPGA-RMII-SMII-main\RTL\rmii_phy_if.v'
)

$missing = @(
  foreach ($relative in $required) {
    $path = Join-Path $PWD $relative
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
      $path
    }
  }
)

if ($missing.Count -gt 0) {
  $missing | ForEach-Object { Write-Host "Missing: $_" -ForegroundColor Red }
  throw 'External Ethernet dependency precheck failed'
}

Write-Host 'External Ethernet dependency precheck: PASS' -ForegroundColor Green
```

This array assignment avoids PowerShell's empty-pipeline parsing problem and gives `$missing.Count` a stable meaning for zero, one, or multiple missing files.

## Publication boundary

`prg_cam.srcs/sources_1/lib/` and `third_party/` are ignored. Do not use `git add -f` on either path. Before a public commit, verify:

```powershell
git status --short
git ls-files prg_cam.srcs/sources_1/lib third_party
```

The second command must print nothing. The dependency projects retain their own upstream licenses and histories; cloning them locally does not make them part of this repository's public source or license.

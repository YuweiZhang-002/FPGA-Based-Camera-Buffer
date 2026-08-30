# Software requirements and validated environment

This file is the cross-repository software configuration authority for the
public MCU → FPGA → Host reproduction flow. It distinguishes a declared
requirement from a version observed on the original workstation. An observed
version is evidence that one run used that version; it is not an invented
minimum compatibility guarantee.

Read the repository-specific `README`, `THIRD_PARTY_NOTICES.md`, and execution
chapter before installing or redistributing a dependency.

## Requirement labels

| Label | Meaning |
|---|---|
| Required | The referenced build or run cannot execute without this component. |
| Stage-specific | Needed only for the named stage, such as live capture, ILA, calibration, or MATLAB plotting. |
| Observed | Version found on the original validation workstation on 2026-08-30. |
| Unverified minimum | The repository does not contain enough evidence to claim the oldest compatible version. |

## Validated workstation snapshot

| Component | Declared requirement | Observed version | Scope and evidence |
|---|---|---|---|
| Windows | Windows is the authoritative live-capture/Vivado workflow | NT `10.0.26200.0`, 64-bit process | Npcap, Vivado batch files, and project PowerShell are Windows paths. The exact minimum Windows release is unverified. |
| Windows PowerShell | 5.1 or PowerShell 7 | Windows PowerShell `5.1.26100.9168` | `docs/08_independent_cold_start_acceptance.md`; scripts avoid PowerShell-7-only syntax. |
| Git | Required; no minimum version is declared | `2.54.0.windows.1` | Clone, pinned checkout, identity, dirty-state, and hash evidence. |
| Xilinx Vivado | Must support `xc7a50ticsg324-1L`; use 2025.2.1 for the reproduced baseline | `2025.2.1` 64-bit | `prg_cam.xpr`, Xsim metadata, and `docs/04_fpga_vivado_tcl_ila_build_and_debug.md`. |
| CMake | Project declares `3.13...3.27` policy compatibility | `3.31.5` | MCU `CMakeLists.txt`; newer-version compatibility beyond the observed run is not guaranteed. |
| Ninja | Required by the documented MCU command | `1.12.1` | MCU build uses `-G Ninja`. Another CMake generator is possible but is not the documented reproduction baseline. |
| Arm GNU toolchain | Pico-compatible Arm embedded compiler; project requests `14_2_Rel1` | GCC `14.2.1` (`14_2_Rel1`) | MCU `CMakeLists.txt`. |
| Raspberry Pi Pico SDK | `2.2.0`-compatible external SDK | `2.2.0` | MCU `CMakeLists.txt`; resolved through `PICO_SDK_PATH`, not vendored. |
| picotool | Stage-specific for tool-assisted programming/inspection | `2.2.0-a4` | Requested by MCU `CMakeLists.txt`; UF2 drag-and-drop does not require it. |
| Python | Host source syntax requires Python 3.10 or later | `3.14.6`, 64-bit | The package uses PEP 604 `X | None` annotations; the release evidence used 3.14.6. |
| Scapy | Required for live NIC capture and optional Scapy PCAP functions; version currently unpinned | `2.7.0` | Host `requirements-live.txt`. |
| pytest | Required for the public regression suite; version currently unpinned | `9.1.1` | Host `requirements-live.txt`. |
| NumPy | `>=1.24` | `2.5.1` | Host `requirements-calibration.txt`. |
| OpenCV headless | `opencv-python-headless>=4.8,<5` | `4.14.0.94` (`cv2 4.14.0`) | OpenCV 5.0.0.93 is excluded by the project's recorded fisheye multi-view regression. |
| Npcap | Required only for Windows live capture | Exact installed version not recorded | Install separately; an elevated shell may be required. Validate by listing interfaces, not by assuming installation success. |
| Wireshark | Optional but recommended for raw EtherType `0x88B5` diagnosis | Unverified | Used to separate PHY/NIC visibility from Python parsing. |
| MATLAB | Optional for `scripts_matlab/*.m` evidence figures | R2026a Update 4 installation detected | Minimum release/toolbox set is unverified. The current batch startup preflight returned `System Error: File system inconsistency`, so MATLAB is not marked validated in this snapshot. |

## Reproduction directory contract

The cold-start scripts expect three sibling first-party repositories and local
FPGA dependencies:

```text
<WORKSPACE>/
├─ MCU/
├─ FPGA/
│  └─ third_party/
│     ├─ taxi/
│     └─ FPGA-RMII-SMII/
└─ Host/
```

Do not copy `.venv`, Vivado runs, MCU `build/`, images, captures, or an existing
third-party checkout from the original workstation. Use
`scripts_ps/initialize_reproduction_workspace.ps1` and inspect its
`bootstrap_manifest.json`.

## MCU configuration

Required inputs:

- CMake, Ninja, Arm GNU toolchain, and Pico SDK 2.2.0;
- `PICO_SDK_PATH` pointing to an external SDK checkout;
- `PICO_BOARD=pico2` and `PICO_PLATFORM=rp2350` (also defaulted by the project);
- USB access for UF2 programming or picotool when that programming path is used.

PowerShell configuration:

```powershell
$mcu = '<WORKSPACE>\MCU'                 # replace with the cloned MCU root
$cmake = '<CMAKE_EXE>'                   # e.g. ...\cmake.exe
$ninja = '<NINJA_EXE>'                   # directory must be on PATH
$env:PICO_SDK_PATH = '<PICO_SDK_ROOT>'   # SDK 2.2.0-compatible checkout
$env:Path = "$(Split-Path $ninja);$env:Path"

& $cmake --version
& $ninja --version
& '<ARM_NONE_EABI_GCC_EXE>' --version

& $cmake -S $mcu -B (Join-Path $mcu 'build') -G Ninja `
  -DPICO_BOARD=pico2 -DPICO_PLATFORM=rp2350
& $cmake --build (Join-Path $mcu 'build') --config Release
```

The Raspberry Pi Pico VS Code extension is optional. Its generated local
configuration is not a repository input and must not replace the explicit SDK,
toolchain, board, and platform record.

## FPGA and Vivado configuration

Required inputs:

- Vivado with synthesis, implementation, Xsim, Hardware Manager, and support
  for `xc7a50ticsg324-1L`;
- cable/JTAG drivers and `hw_server` for Program/Observe/Capture actions;
- TAXI and FPGA-RMII-SMII at the revisions in `third_party/README.md`;
- enough local writable space for isolated Vivado runs and reports. No numeric
  disk/RAM minimum is claimed because the repository has no measured limit.

Preflight without building or programming:

```powershell
$fpga = '<WORKSPACE>\FPGA'
$vivado = '<VIVADO_INSTALL>\Vivado\bin\vivado.bat'
$runner = Join-Path $fpga 'scripts_ps\run_ethernet_ila.ps1'

& $runner -Action Build -VivadoBin $vivado -PreflightOnly
if ($LASTEXITCODE -ne 0) {
  throw "Vivado preflight failed: $LASTEXITCODE"
}
```

`Program`, `Observe`, `Capture`, and `DiagnoseDrops` additionally require a
connected `xc7a50t` target. ILA actions require a `.bit` and `.ltx` generated by
the same build; a successful program operation with mismatched probes is not a
valid debug run.

## Host receiver configuration

Create an isolated environment and install both declared dependency groups:

```powershell
$host = '<WORKSPACE>\Host'
$basePython = '<PYTHON_3_10_OR_LATER_EXE>'

& $basePython -m venv (Join-Path $host '.venv')
$python = Join-Path $host '.venv\Scripts\python.exe'

& $python -m pip install --upgrade pip
& $python -m pip install -r (Join-Path $host 'requirements-live.txt')
& $python -m pip install -r (Join-Path $host 'requirements-calibration.txt')
& $python -m pytest -q $host
```

Stage-specific requirements:

| Host operation | Required software |
|---|---|
| Standard-library offline PCAP replay | Python only; the public golden fixture does not require a NIC or Npcap. |
| Full regression suite | Python and pytest; calibration tests also need NumPy/OpenCV. |
| Live capture | Python, Scapy, separately installed Npcap, a matching Ethernet NIC, exact Npcap GUID, and usually an elevated shell. |
| PGM/CSV publication | Python; adequate writable output storage. |
| Intrinsic/extrinsic calibration | Python, NumPy, OpenCV headless, PGM inputs, and fresh output directories. |
| Tk viewer | A Python distribution containing Tk/Tcl support; not needed by headless receive/calibration commands. |

Verify the live boundary before acquisition:

```powershell
Set-Location $host
& $python -m taxi_receiver.cli --list
if ($LASTEXITCODE -ne 0) {
  throw "Npcap/interface enumeration failed: $LASTEXITCODE"
}
```

Copy the exact `\Device\NPF_{...}` result. A placeholder interface string is
not a configuration and normally produces Windows error 123.

## Optional MATLAB figure generation

The local `scripts_matlab/` programs use `readtable`, `imread`, `tiledlayout`,
`yyaxis`, and `exportgraphics`. No separate toolbox dependency has been proven,
and no minimum MATLAB release is claimed. Before relying on the scripts:

```powershell
$matlab = '<MATLAB_ROOT>\bin\matlab.exe'
& $matlab -batch "disp(version); ver"
if ($LASTEXITCODE -ne 0) {
  throw "MATLAB preflight failed: $LASTEXITCODE"
}
```

Treat a MATLAB startup failure as an environment failure, not as experimental
evidence. The MATLAB scripts are analysis helpers and are not required for MCU
build, FPGA build, packet capture, or OpenCV calibration.

## One-command-style software inventory

Materialize arrays before piping so Windows PowerShell does not encounter an
empty-pipeline syntax problem:

```powershell
$toolChecks = @(
  foreach ($name in 'git', 'powershell') {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Tool = $name
      Found = $null -ne $command
      Path = if ($command) { $command.Source } else { '' }
    }
  }
)

$toolChecks | Format-Table -AutoSize
if (@($toolChecks | Where-Object { -not $_.Found }).Count -ne 0) {
  throw 'Required base software is missing'
}
```

Record all resolved versions, repository commits, dirty states, bit/LTX/UF2
hashes, Npcap GUID, Python package versions, and output roots in the run
manifest. A tool being installed is not proof that its build, programming, or
capture stage passed.

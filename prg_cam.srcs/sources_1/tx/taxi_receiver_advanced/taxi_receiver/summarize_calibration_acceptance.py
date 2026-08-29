"""Summarise the 20-21 August intrinsic/stereo acceptance rerun."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


INTRINSIC_LABELS = {
    "run20_cam0_k1k4": "Run20 CAM0 k1-k4",
    "run20_cam1_k1k4": "Run20 CAM1 k1-k4",
    "run20_cam0_k1k2": "Run20 CAM0 k1-k2",
    "run20_cam1_k1k2": "Run20 CAM1 k1-k2",
    "run20_cam0_k1k3": "Run20 CAM0 k1-k3",
    "run20_cam1_k1k3": "Run20 CAM1 k1-k3",
}

EXTRINSIC_LABELS = {
    "run01_k1k4": "Run01 k1-k4",
    "run01_k1k2": "Run01 k1-k2",
    "run01_k1k3": "Run01 k1-k3",
    "first_final_capture": "First final capture",
    "controlled_retry": "Controlled retry",
}


def read_json(path: Path) -> dict[str, Any]:
    # Windows PowerShell 5.1 writes a UTF-8 BOM for -Encoding UTF8.
    with path.open("r", encoding="utf-8-sig") as stream:
        return json.load(stream)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rotation_degrees(matrix: list[list[float]]) -> float:
    trace = float(matrix[0][0]) + float(matrix[1][1]) + float(matrix[2][2])
    cosine = max(-1.0, min(1.0, (trace - 1.0) / 2.0))
    return math.degrees(math.acos(cosine))


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def intrinsic_rows(output_root: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    base = output_root / "01_intrinsics"
    for slug, label in INTRINSIC_LABELS.items():
        summary_path = base / slug / "holdout_summary.json"
        summary = read_json(summary_path)
        intrinsic_path = Path(summary["calibration"]["path"])
        intrinsic = read_json(intrinsic_path)
        quality = summary["quality"]
        counts = summary["counts"]
        calibration_hash_ok = sha256(intrinsic_path).lower() == str(
            summary["calibration"]["sha256"]
        ).lower()
        coefficients = [float(value) for value in intrinsic["dist_coeffs"]]
        rows.append(
            {
                "experiment": label,
                "camera_id": int(intrinsic["camera_id"]),
                "fx": float(intrinsic["K"][0][0]),
                "fy": float(intrinsic["K"][1][1]),
                "cx": float(intrinsic["K"][0][2]),
                "cy": float(intrinsic["K"][1][2]),
                "k1": coefficients[0],
                "k2": coefficients[1],
                "k3": coefficients[2],
                "k4": coefficients[3],
                "training_rms_px": float(intrinsic["quality"]["rms_px"]),
                "training_views": int(intrinsic["quality"]["accepted_images"]),
                "holdout_views": int(counts["sampled_holdout_views"]),
                "holdout_median_rmse_px": float(quality["median_rmse_px"]),
                "holdout_p95_rmse_px": float(quality["p95_rmse_px"]),
                "holdout_maximum_rmse_px": float(quality["maximum_rmse_px"]),
                "holdout_pass_fraction": float(
                    quality["fraction_at_or_below_p95_limit"]
                ),
                "hash_binding": "pass" if calibration_hash_ok else "fail",
                "status": "Pass"
                if summary["status"] == "pass" and calibration_hash_ok
                else "Reject",
                "summary_path": str(summary_path),
            }
        )
    return rows


def find_extrinsic(case_root: Path) -> Path:
    solve_root = case_root / "solve"
    accepted = solve_root / "cam0_to_cam1_extrinsics.json"
    rejected = solve_root / "cam0_to_cam1_extrinsics.rejected.json"
    if accepted.is_file():
        return accepted
    if rejected.is_file():
        return rejected
    raise FileNotFoundError(f"No extrinsic result under {solve_root}")


def extrinsic_rows(output_root: Path, nominal: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    nominal_baseline = float(nominal["nominal_optical_center_baseline_mm"])
    nominal_rotation = float(nominal["nominal_relative_rotation_deg"])
    baseline_tolerance = float(
        nominal["acceptance_reference"]["baseline_tolerance_mm"]
    )
    rotation_tolerance = float(
        nominal["acceptance_reference"]["relative_rotation_tolerance_deg"]
    )
    base = output_root / "02_extrinsics"
    for slug, label in EXTRINSIC_LABELS.items():
        result_path = find_extrinsic(base / slug)
        result = read_json(result_path)
        replay_status_path = base / slug / "solve" / "replay_status.json"
        evidence_mode = (
            read_json(replay_status_path)["status"]
            if replay_status_path.is_file()
            else "recomputed_from_existing_frames"
        )
        quality = result["quality"]
        rotation = rotation_degrees(result["R_cam1_from_cam0"])
        baseline = float(quality["baseline_mm"])
        baseline_error = baseline - nominal_baseline
        rotation_error = rotation - nominal_rotation
        mechanical_pass = (
            abs(baseline_error) <= baseline_tolerance
            and abs(rotation_error) <= rotation_tolerance
        )
        numerical_pass = quality["status"] == "acceptable"
        status = "Accept" if mechanical_pass and numerical_pass else "Reject"
        failure_reasons = list(quality.get("failures", []))
        if quality["status"] == "limited":
            failure_reasons.append("solver status is limited, not acceptable")
        if not mechanical_pass:
            failure_reasons.append(
                "nominal geometry mismatch: "
                f"baseline error {baseline_error:+.3f} mm, "
                f"rotation error {rotation_error:+.3f} deg"
            )
        rows.append(
            {
                "experiment": label,
                "accepted_pairs": int(quality["accepted_pairs"]),
                "stereo_rms_px": float(quality["stereo_rms_px"]),
                "baseline_mm": baseline,
                "relative_rotation_deg": rotation,
                "rotation_dispersion_deg": float(
                    quality["rotation_dispersion_median_deg"]
                ),
                "translation_dispersion_mm": float(
                    quality["translation_dispersion_median_mm"]
                ),
                "depth_independence": quality["depth_independence"]["status"],
                "baseline_error_from_25mm": baseline_error,
                "rotation_error_from_5deg": rotation_error,
                "mechanical_sanity": "Pass" if mechanical_pass else "Fail",
                "solver_quality": quality["status"],
                "status": status,
                "evidence_mode": evidence_mode,
                "failure_reasons": " | ".join(failure_reasons),
                "result_path": str(result_path),
            }
        )
    return rows


def count_pgms(path: Path) -> int:
    return sum(1 for _ in path.glob("*.pgm")) if path.is_dir() else 0


def dataset_rows(repo_root: Path) -> list[dict[str, Any]]:
    new_temp = repo_root / "images" / "new_Temp"
    datasets = [
        (
            "Run20 intrinsic train",
            new_temp / "cam1_replacement_20260820_run01" / "01_cam1_intrinsic_train",
        ),
        (
            "Run20 intrinsic holdout",
            new_temp / "cam1_replacement_20260820_run01" / "02_cam1_intrinsic_holdout",
        ),
        (
            "Run20 stereo static",
            new_temp / "cam1_replacement_20260820_run01" / "03_stereo_static",
        ),
        (
            "Run20 stereo train",
            new_temp / "cam1_replacement_20260820_run01" / "04_stereo_train",
        ),
        ("Run21 first train", new_temp / "stereo_final_20260821" / "01_train"),
        (
            "Run21 controlled retry",
            new_temp / "stereo_final_20260821" / "01_train_retry01",
        ),
    ]
    return [
        {
            "dataset": label,
            "cam0_pgm_frames": count_pgms(path / "cam0"),
            "cam1_pgm_frames": count_pgms(path / "cam1"),
            "path": str(path),
        }
        for label, path in datasets
    ]


def markdown_report(
    nominal: dict[str, Any],
    intrinsics: list[dict[str, Any]],
    extrinsics: list[dict[str, Any]],
    datasets: list[dict[str, Any]],
) -> str:
    lines = [
        "# Calibration Acceptance Rerun - 2026-08-24",
        "",
        "Existing 20-21 August images only; no new calibration frames were acquired.",
        "The 25 mm / 5 deg rig geometry is a post-solve sanity reference, not an optimiser prior.",
        "",
        "## Dataset inventory",
        "",
        "| Dataset | CAM0 PGM | CAM1 PGM |",
        "| --- | ---: | ---: |",
    ]
    lines.extend(
        f"| {row['dataset']} | {row['cam0_pgm_frames']} | {row['cam1_pgm_frames']} |"
        for row in datasets
    )
    lines.extend(
        [
            "",
            "## Intrinsic holdout rerun",
            "",
            "| Experiment | Train RMS | Holdout median | Holdout P95 | Holdout max | Pass fraction | Status |",
            "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
        ]
    )
    lines.extend(
        "| {experiment} | {training_rms_px:.3f} px | "
        "{holdout_median_rmse_px:.3f} px | {holdout_p95_rmse_px:.3f} px | "
        "{holdout_maximum_rmse_px:.3f} px | {fraction:.1f}% | {status} |".format(
            fraction=100.0 * row["holdout_pass_fraction"], **row
        )
        for row in intrinsics
    )
    lines.extend(
        [
            "",
            "## Stereo acceptance rerun",
            "",
            "| Experiment | Stereo RMS | Baseline | Relative rotation | Rotation dispersion | Translation dispersion | Status |",
            "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
        ]
    )
    lines.extend(
        "| {experiment} | {stereo_rms_px:.3f} px | {baseline_mm:.3f} mm | "
        "{relative_rotation_deg:.3f} deg | {rotation_dispersion_deg:.3f} deg | "
        "{translation_dispersion_mm:.3f} mm | {status} |".format(**row)
        for row in extrinsics
    )
    lines.extend(
        [
            "",
            "## 25 mm / 5 deg mechanical comparison",
            "",
            "| Experiment | Baseline error | Rotation error | Mechanical sanity | Solver quality | Depth independence |",
            "| --- | ---: | ---: | --- | --- | --- |",
        ]
    )
    lines.extend(
        "| {experiment} | {baseline_error_from_25mm:+.3f} mm | "
        "{rotation_error_from_5deg:+.3f} deg | {mechanical_sanity} | "
        "{solver_quality} | {depth_independence} |".format(**row)
        for row in extrinsics
    )
    lines.extend(
        [
            "",
            "Mechanical sanity tolerances are provisional: "
            f"+/-{nominal['acceptance_reference']['baseline_tolerance_mm']:.1f} mm and "
            f"+/-{nominal['acceptance_reference']['relative_rotation_tolerance_deg']:.1f} deg.",
            "A mechanical match does not override dispersion or depth-independence failures.",
            "First final capture is a hash-bound historical artifact: its archived manifest references frame IDs 7663 onward, but that capture directory was later replaced by the current 0-based 2221-frame dataset.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--nominal-config", type=Path, required=True)
    args = parser.parse_args()

    nominal = read_json(args.nominal_config)
    intrinsics = intrinsic_rows(args.output_root)
    extrinsics = extrinsic_rows(args.output_root, nominal)
    datasets = dataset_rows(args.repo_root)
    summary = {
        "schema": "taxi_receiver.historical_calibration_acceptance/1",
        "created_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "new_capture_performed": False,
        "nominal_geometry": nominal,
        "dataset_inventory": datasets,
        "intrinsics": intrinsics,
        "extrinsics": extrinsics,
        "campaign_status": "Accept"
        if all(row["status"] == "Pass" for row in intrinsics)
        and any(row["status"] == "Accept" for row in extrinsics)
        else "Reject",
    }
    with (args.output_root / "acceptance_summary.json").open(
        "w", encoding="utf-8"
    ) as stream:
        json.dump(summary, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    write_csv(args.output_root / "intrinsic_results.csv", intrinsics)
    write_csv(args.output_root / "extrinsic_results.csv", extrinsics)
    write_csv(args.output_root / "dataset_inventory.csv", datasets)
    (args.output_root / "acceptance_report.md").write_text(
        markdown_report(nominal, intrinsics, extrinsics, datasets),
        encoding="utf-8",
    )
    print(f"campaign acceptance: {summary['campaign_status']}")
    print(f"summary: {args.output_root / 'acceptance_summary.json'}")
    print(f"report: {args.output_root / 'acceptance_report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

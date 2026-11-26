#!/usr/bin/env python3
"""Prove protected baseline hashes and save a scoped, reviewable BER diff.

Never changes source files, the baseline or Git index. Run after validation.
"""
import argparse
import datetime as dt
import difflib
import hashlib
import json
import shutil
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "_codex/ber_20261102"
TX_UART_SCOPE = {
    "code/stm32/tx_stm32/Core/Inc/fsk_tx.h",
    "code/stm32/tx_stm32/Core/Src/fsk_tx.c",
    "code/stm32/tx_stm32/Core/Src/main.c",
}
TASK_FILES = [
    "code/cyclone10/rx_cyclone10/rtl/debug/ber_capture.v",
    "code/cyclone10/rx_cyclone10/tb/ber_capture_tb.sv",
    "code/cyclone10/rx_cyclone10/tb/ber_lock_budget_tb.sv",
    "code/cyclone10/rx_cyclone10/tb/integration_rx_chain_tb.sv",
    "code/cyclone10/rx_cyclone10/rtl/spi/SPI_REGISTER_MAP.md",
    "code/cyclone10/rx_cyclone10/rx_cyclone10.v",
    "code/cyclone10/rx_cyclone10/rx_cyclone10.qsf",
    "code/cyclone10/rx_cyclone10/rtl/spi/spi1_slave.v",
    "code/stm32/rx_stm32/Core/Inc/fpga_rx_spi.h",
    "code/stm32/rx_stm32/Core/Src/fpga_rx_spi.c",
    "code/stm32/rx_stm32/Core/Src/main.c",
    "code/stm32/rx_stm32/Core/Inc/rx_ber.h",
    "code/stm32/rx_stm32/Core/Src/rx_ber.c",
    "code/stm32/rx_stm32/Tests/rx_ber_test.c",
    "tools/ber/ber_protocol.py", "tools/ber/ber_test.py",
    "tools/ber/test_ber.py", "tools/ber/validate.py", "tools/ber/audit.py",
    "codex/BER_IMPLEMENTATION_PLAN.md", "codex/BER_PROTOCOL.md",
    "codex/BER_VALIDATION.md", "codex/UPPER_COMPUTER_PROTOCOL.md",
    *sorted(TX_UART_SCOPE),
    "code/stm32/tx_stm32/Tests/test_fsk_tx_hal_mock.c",
    "code/stm32/tx_stm32/Tests/test_uart_diagnostics.py",
    "code/stm32/tx_stm32/Tests/test_uart_vendor_rearm.py",
    "code/stm32/tx_stm32/Tests/compare_uart_status.py",
    "tools/ber/serial_check.py", "tools/ber/test_serial_check.py",
    "tools/ber/win32_serial_diagnostics.py",
    "code/stm32/tx_stm32/Tests/build_uart_diagnostics.py",
    "code/stm32/tx_stm32/Tests/compare_diagnostic_waveform.py",
    "flutter/lib/main.dart", "flutter/lib/ber_data.dart", "flutter/lib/ber_controller.dart",
    "flutter/lib/ber_view.dart", "flutter/test/ber_test.dart", "flutter/test/widget_test.dart",
    "flutter/lib/ber_command_writer.dart", "flutter/test/ber_command_writer_test.dart",
    "flutter/test/fixtures/ber_vectors.json",
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ARTIFACTS / "final_audit")
    parser.add_argument("--tx-uart-diagnostics", action="store_true",
                        help="Explicit 2026-11-05 authorized scope: audit three TX diagnostic attachment files against their pre-edit snapshot")
    parser.add_argument("--replay-vector-dir", type=Path,
                        help="Replay existing FSK integration vectors with verified pre-BER core and no BER module")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    baseline = json.loads((ARTIFACTS / "baseline.json").read_text(encoding="utf-8-sig"))
    protected, integration = [], []
    scoped_diff = []
    for name, expected in baseline["sha256"].items():
        row = {"path": name, "before_sha256": expected,
               "current_sha256": sha(ROOT / name), "unchanged": sha(ROOT / name) == expected}
        tx_diag_attachment = args.tx_uart_diagnostics and name in TX_UART_SCOPE
        if name in baseline["edit_existing"] or tx_diag_attachment:
            integration.append(row)
            original = ARTIFACTS / ("tx_uart_diag_20261105/baseline" if tx_diag_attachment else "baseline") / name
            row["scope"] = "authorized TX UART diagnostics 2026-11-05" if tx_diag_attachment else "original BER integration"
            row["snapshot_matches_baseline"] = sha(original) == expected
            scoped_diff.extend(difflib.unified_diff(
                [line + "\n" for line in original.read_text().splitlines()],
                [line + "\n" for line in (ROOT / name).read_text().splitlines()],
                "baseline/" + name, "current/" + name))
        else:
            protected.append(row)
    task_files = [{"path": name, "sha256": sha(ROOT / name) if (ROOT / name).exists() else None}
                  for name in TASK_FILES]
    git_status = subprocess.run(["git", "status", "--short"], cwd=ROOT, capture_output=True, check=True).stdout
    git_diff = subprocess.run(["git", "diff", "--no-ext-diff"], cwd=ROOT, capture_output=True, check=True).stdout
    (args.output / "git_status.txt").write_bytes(git_status)
    (args.output / "workspace_tracked.diff").write_bytes(git_diff)
    (args.output / "ber_integration_vs_baseline.diff").write_text("".join(scoped_diff), encoding="utf-8")
    result = {"created": dt.datetime.now().isoformat(),
              "tx_uart_diagnostics_scope": args.tx_uart_diagnostics,
              "protected_unchanged": all(r["unchanged"] for r in protected),
              "snapshot_integrity": all(r["snapshot_matches_baseline"] for r in integration),
              "protected": protected, "integration": integration, "ber_task_files": task_files}
    (args.output / "sha256_audit.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    if args.replay_vector_dir and result["protected_unchanged"]:
        build = args.output / ("baseline_core_replay_" + dt.datetime.now().strftime("%Y%m%d_%H%M%S"))
        build.mkdir(exist_ok=False)
        fpga = ROOT / "code/cyclone10/rx_cyclone10"
        sources = [
            fpga / "rtl/demod/fsk_tone_rom.v", fpga / "rtl/demod/fsk_iq_correlator.v",
            fpga / "rtl/demod/fsk_noise_tracker.v", fpga / "rtl/demod/fsk_demod_core.v",
            fpga / "rtl/sync/fsk_symbol_sync.v", fpga / "rtl/protocol/fsk_frame_rx.v",
            fpga / "tb/integration_rx_chain_tb.sv",
        ]
        staged = []
        for source in sources:
            dest = build / source.name
            shutil.copy2(source, dest);staged.append(dest)
        manifest = json.loads((args.replay_vector_dir / "manifest.json").read_text())
        scenario = next(s for s in manifest["scenarios"] if s["name"] == "complete_frame_nominal")
        commands = [
            ["vlib", "work"],
            ["vlog", "-sv", "+incdir+" + str(fpga / "rtl/protocol").replace("\\", "/"), *map(str, staged)],
            ["vsim", "-c", "-novopt", "-lib", "work", "integration_rx_chain_tb",
             "+SAMPLE_FILE=" + str(args.replay_vector_dir / scenario["files"]["samples_i20_mem"]).replace("\\", "/"),
             "+FRAME_FILE=" + str(args.replay_vector_dir / scenario["files"]["frame_hex"]).replace("\\", "/"),
             "+SAMPLE_COUNT=" + str(scenario["sample_count"]),
             "+FRAME_BYTE_COUNT=" + str(scenario["frame_byte_count"]),
             "+SYNC_WORD=" + manifest["parameters"]["sync_word_hex"],
             "-do", "run -all; quit -code 0"],
        ]
        for i, command in enumerate(commands):
            with (build / f"step_{i}.log").open("w", encoding="utf-8") as log:
                subprocess.run(command, cwd=build, stdout=log, stderr=subprocess.STDOUT, timeout=180, check=True)
        text = (build / "step_2.log").read_text()
        replay = {"no_ber_module": True, "protected_core_matches_pre_ber_hashes": True,
                  "same_failure_reproduced": "FAIL: expected one CRC-valid frame, observed 0" in text,
                  "staged_sources": {str(p): sha(p) for p in staged},
                  "sample_sha256": sha(args.replay_vector_dir / scenario["files"]["samples_i20_mem"])}
        (build / "replay.json").write_text(json.dumps(replay, indent=2), encoding="utf-8")
        print(json.dumps({"baseline_core_replay": str(build), **replay}, indent=2))
    print(json.dumps({"protected_unchanged": result["protected_unchanged"], "protected_count": len(protected),
                      "snapshot_integrity": result["snapshot_integrity"], "task_paths": len(task_files), "output": str(args.output)}, indent=2))
    return int(not result["protected_unchanged"] or not result["snapshot_integrity"])


if __name__ == "__main__":
    raise SystemExit(main())

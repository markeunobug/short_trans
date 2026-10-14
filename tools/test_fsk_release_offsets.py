#!/usr/bin/env python3
"""Run full-frame +/-20 Hz tests against an already compiled release RTL library."""
import argparse
import dataclasses
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    args = parser.parse_args()
    release = args.release.resolve()
    project = release / "source/code/cyclone10/rx_cyclone10"
    regression = project / "simulation/.regression"
    spec = importlib.util.spec_from_file_location("fsk_vectors", project / "tools/gen_fsk_vectors.py")
    vectors = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = vectors
    spec.loader.exec_module(vectors)
    sync = vectors.read_sync_word(project / "rtl/protocol/fsk_sync_word.vh")
    base = next(s for s in vectors.default_scenarios(bytes(range(16)), sync, vectors.DEFAULT_SEED)
                if s.name == "complete_frame_nominal")
    output = release / "offset_vectors"
    output.mkdir(exist_ok=True)
    results = []
    for offset in (-20, 20):
        case = dataclasses.replace(base, name=f"complete_frame_offset_{offset:+d}", frequency_offset_hz=offset)
        samples, phase = vectors.synthesize(case, vectors.scenario_seed(vectors.DEFAULT_SEED, case.name))
        sample_file, frame_file = output / (case.name + ".samples.mem"), output / (case.name + ".frame.hex")
        vectors.write_hex_lines(sample_file, samples, 5)
        vectors.write_hex_lines(frame_file, case.frame_bytes, 2)
        log = output / (case.name + ".log")
        command = ["vsim", "-c", "-lib", "work", "integration_rx_chain_tb", "-l", str(log),
                   "+SAMPLE_FILE=" + sample_file.as_posix(), "+FRAME_FILE=" + frame_file.as_posix(),
                   f"+SAMPLE_COUNT={len(samples)}", f"+FRAME_BYTE_COUNT={len(case.frame_bytes)}",
                   f"+SYNC_WORD={sync:04X}", "-do", "onerror {quit -code 1}; run -all; quit -code 0"]
        completed = subprocess.run(command, cwd=regression, capture_output=True, text=True, errors="replace", timeout=60)
        (output / (case.name + "_console.log")).write_text(completed.stdout + completed.stderr)
        text = log.read_text(errors="replace") if log.exists() else completed.stdout
        passed = completed.returncode == 0 and "PASS" in text and not re.search(r"\bFAIL\b|\*\* (Error|Fatal)", text)
        results.append(dict(name=case.name, offset_hz=offset, status="PASS" if passed else "FAIL",
                            sample_count=len(samples), payload_bytes=len(case.payload), phase_rad=phase,
                            sample_sha256=vectors.file_sha256(sample_file), frame_sha256=vectors.file_sha256(frame_file)))
        print(case.name, results[-1]["status"], flush=True)
    (output / "results.json").write_text(json.dumps(results, indent=2))
    return 0 if all(r["status"] == "PASS" for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

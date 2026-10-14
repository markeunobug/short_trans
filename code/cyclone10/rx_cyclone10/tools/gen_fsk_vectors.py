#!/usr/bin/env python3
"""Generate deterministic 48 kSPS 2FSK RTL simulation vectors.

The generated vectors cover the frozen V1.0 physical layer and common
impairments.  Only Python's standard library is required.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional, Sequence


SAMPLE_RATE = 48_000
BIT_RATE = 100
SAMPLES_PER_SYMBOL = SAMPLE_RATE // BIT_RATE
FREQ_BIT_0 = 1_700.0
FREQ_BIT_1 = 1_900.0
PREAMBLE = 0xAAAA
MAX_PAYLOAD_BYTES = 64
I20_MAX = (1 << 19) - 1
I20_MIN = -(1 << 19)
ADC_LEFT_SHIFT = 12
DEFAULT_SEED = 0x2F5C2026


@dataclass(frozen=True)
class ScenarioSpec:
    name: str
    bits: tuple[int, ...]
    amplitude: float = 0.55
    dc_offset: float = 0.0
    dc_drift_peak: float = 0.0
    snr_db: Optional[float] = None
    frequency_offset_hz: float = 0.0
    lead_samples: int = 0
    trail_samples: int = 0
    kind: str = "symbols"
    frame_bytes: bytes = b""
    payload: bytes = b""


def crc8_atm(data: Iterable[int]) -> int:
    value = 0x00
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ 0x07) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


def crc16_ccitt_false(data: Iterable[int]) -> int:
    value = 0xFFFF
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ 0x1021) & 0xFFFF if value & 0x8000 else (value << 1) & 0xFFFF
    return value


def bytes_to_bits(data: Iterable[int]) -> tuple[int, ...]:
    return tuple((byte >> bit_index) & 1 for byte in data for bit_index in range(7, -1, -1))


def read_sync_word(header_path: Path) -> int:
    text = header_path.read_text(encoding="ascii")
    match = re.search(r"`define\s+FSK_SYNC_WORD\s+16'h([0-9a-fA-F]{4})", text)
    if not match:
        raise ValueError(f"FSK_SYNC_WORD was not found in {header_path}")
    return int(match.group(1), 16)


def build_frame(payload: bytes, sync_word: int, version_type: int, sequence: int) -> bytes:
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ValueError(f"payload is {len(payload)} bytes; maximum is {MAX_PAYLOAD_BYTES}")
    header_prefix = bytes((version_type & 0xFF, sequence & 0xFF, len(payload)))
    header = header_prefix + bytes((crc8_atm(header_prefix),))
    frame_crc = crc16_ccitt_false(header + payload)
    return (
        PREAMBLE.to_bytes(2, "big")
        + sync_word.to_bytes(2, "big")
        + header
        + payload
        + frame_crc.to_bytes(2, "big")
    )


def parse_payload(text: str) -> bytes:
    compact = re.sub(r"[\s,_:-]", "", text)
    if compact.lower().startswith("0x"):
        compact = compact[2:]
    if len(compact) % 2:
        raise argparse.ArgumentTypeError("payload hex must contain complete bytes")
    try:
        payload = bytes.fromhex(compact)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise argparse.ArgumentTypeError("payload exceeds 64 bytes")
    return payload


def scenario_seed(base_seed: int, name: str) -> int:
    return (base_seed ^ zlib.crc32(name.encode("ascii"))) & 0xFFFFFFFF


def clip_i20(value: float) -> int:
    return max(I20_MIN, min(I20_MAX, int(round(value))))


def synthesize(spec: ScenarioSpec, seed: int) -> tuple[list[int], float]:
    rng = random.Random(seed)
    initial_phase = rng.uniform(0.0, 2.0 * math.pi)
    phase = initial_phase
    signal_peak = spec.amplitude * I20_MAX
    noise_sigma = 0.0
    if spec.snr_db is not None:
        signal_rms = signal_peak / math.sqrt(2.0)
        noise_sigma = signal_rms / (10.0 ** (spec.snr_db / 20.0))

    active_samples = len(spec.bits) * SAMPLES_PER_SYMBOL
    total_samples = spec.lead_samples + active_samples + spec.trail_samples
    samples: list[int] = []

    for sample_index in range(total_samples):
        active_index = sample_index - spec.lead_samples
        active = 0 <= active_index < active_samples
        carrier = 0.0
        if active:
            bit = spec.bits[active_index // SAMPLES_PER_SYMBOL]
            frequency = (FREQ_BIT_1 if bit else FREQ_BIT_0) + spec.frequency_offset_hz
            carrier = signal_peak * math.sin(phase)
            phase = (phase + 2.0 * math.pi * frequency / SAMPLE_RATE) % (2.0 * math.pi)

        drift = 0.0
        if total_samples > 1 and spec.dc_drift_peak:
            drift = spec.dc_drift_peak * I20_MAX * math.sin(
                2.0 * math.pi * sample_index / (total_samples - 1)
            )
        noise = rng.gauss(0.0, noise_sigma) if noise_sigma else 0.0
        samples.append(clip_i20(carrier + spec.dc_offset * I20_MAX + drift + noise))

    return samples, initial_phase


def default_scenarios(payload: bytes, sync_word: int, seed: int) -> list[ScenarioSpec]:
    zeroes = (0,) * 24
    ones = (1,) * 24
    alternating = tuple(index & 1 for index in range(24))
    scenarios = [
        ScenarioSpec("ideal_tone_1700", zeroes, kind="fixed_tone"),
        ScenarioSpec("ideal_tone_1900", ones, kind="fixed_tone"),
        ScenarioSpec("ideal_alternating", alternating),
        ScenarioSpec("random_phase_alternating", alternating),
        ScenarioSpec("amplitude_low", alternating, amplitude=0.10),
        ScenarioSpec("amplitude_nominal", alternating, amplitude=0.55),
        ScenarioSpec("amplitude_high", alternating, amplitude=0.90),
        ScenarioSpec("dc_positive", alternating, dc_offset=0.15),
        ScenarioSpec("dc_negative", alternating, dc_offset=-0.15),
        ScenarioSpec("dc_slow_drift", alternating, dc_drift_peak=0.12),
        ScenarioSpec("awgn_30db", alternating, snr_db=30.0),
        ScenarioSpec("awgn_20db", alternating, snr_db=20.0),
        ScenarioSpec("awgn_10db", alternating, snr_db=10.0),
        ScenarioSpec("awgn_0db", alternating, snr_db=0.0),
    ]
    for offset in (-20.0, -10.0, -5.0, 0.0, 5.0, 10.0, 20.0):
        label = f"frequency_{offset:+.0f}hz".replace("+", "plus").replace("-", "minus")
        scenarios.append(ScenarioSpec(label, alternating, frequency_offset_hz=offset))

    frame = build_frame(payload, sync_word, version_type=0x10, sequence=0x35)
    frame_rng = random.Random(scenario_seed(seed, "complete_frame_nominal"))
    random_start_offset = frame_rng.randrange(SAMPLES_PER_SYMBOL)
    scenarios.append(
        ScenarioSpec(
            "complete_frame_nominal",
            bytes_to_bits(frame),
            amplitude=0.55,
            lead_samples=(SAMPLE_RATE // 10) + random_start_offset,
            trail_samples=SAMPLE_RATE // 10,
            kind="complete_frame",
            frame_bytes=frame,
            payload=payload,
        )
    )
    return scenarios


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="ascii", newline="\n")
    temporary.replace(path)


def write_hex_lines(path: Path, values: Iterable[int], width: int) -> None:
    mask = (1 << (width * 4)) - 1
    atomic_write_text(path, "".join(f"{value & mask:0{width}X}\n" for value in values))


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def generate(output_dir: Path, payload: bytes, sync_header: Path, seed: int) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    sync_word = read_sync_word(sync_header)
    manifest = {
        "schema_version": 1,
        "generator": "tools/gen_fsk_vectors.py",
        "seed": seed,
        "parameters": {
            "sample_rate_hz": SAMPLE_RATE,
            "bit_rate_bps": BIT_RATE,
            "samples_per_symbol": SAMPLES_PER_SYMBOL,
            "bit_0_frequency_hz": FREQ_BIT_0,
            "bit_1_frequency_hz": FREQ_BIT_1,
            "preamble_hex": f"{PREAMBLE:04X}",
            "sync_word_hex": f"{sync_word:04X}",
            "bit_order": "MSB-first",
            "crc8": "CRC-8/ATM poly=0x07 init=0x00 refin=false xorout=0x00",
            "crc16": "CRC-16/CCITT-FALSE poly=0x1021 init=0xFFFF refin=false xorout=0x0000",
        },
        "sample_formats": {
            "samples_i20_mem": "signed 20-bit two's-complement, one 5-hex-digit sample per line",
            "samples_i32_mem": "signed 20-bit sample shifted left 12, one 8-hex-digit ADC word per line",
            "bits_mem": "one decoded-intent bit per line; silence samples are described by lead/trail counts",
            "frame_hex": "one complete physical-frame byte per line, including preamble and sync",
        },
        "scenarios": [],
    }

    for spec in default_scenarios(payload, sync_word, seed):
        local_seed = scenario_seed(seed, spec.name)
        samples, initial_phase = synthesize(spec, local_seed)
        prefix = output_dir / spec.name
        i20_path = prefix.with_suffix(".samples_i20.mem")
        i32_path = prefix.with_suffix(".samples_i32.mem")
        bits_path = prefix.with_suffix(".bits.mem")
        write_hex_lines(i20_path, samples, 5)
        write_hex_lines(i32_path, (sample << ADC_LEFT_SHIFT for sample in samples), 8)
        write_hex_lines(bits_path, spec.bits, 1)

        files = {
            "samples_i20_mem": i20_path.name,
            "samples_i32_mem": i32_path.name,
            "bits_mem": bits_path.name,
        }
        if spec.frame_bytes:
            frame_path = prefix.with_suffix(".frame.hex")
            write_hex_lines(frame_path, spec.frame_bytes, 2)
            files["frame_hex"] = frame_path.name

        file_hashes = {name: file_sha256(output_dir / filename) for name, filename in files.items()}
        manifest["scenarios"].append(
            {
                "name": spec.name,
                "kind": spec.kind,
                "seed": local_seed,
                "initial_phase_rad": round(initial_phase, 12),
                "amplitude_full_scale": spec.amplitude,
                "dc_offset_full_scale": spec.dc_offset,
                "dc_drift_peak_full_scale": spec.dc_drift_peak,
                "snr_db": spec.snr_db,
                "frequency_offset_hz": spec.frequency_offset_hz,
                "lead_silence_samples": spec.lead_samples,
                "trail_silence_samples": spec.trail_samples,
                "bit_count": len(spec.bits),
                "sample_count": len(samples),
                "frame_byte_count": len(spec.frame_bytes),
                "payload_hex": spec.payload.hex().upper(),
                "files": files,
                "sha256": file_hashes,
            }
        )

    manifest_path = output_dir / "manifest.json"
    atomic_write_text(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def self_test(sync_header: Path) -> None:
    if crc8_atm(b"123456789") != 0xF4:
        raise AssertionError("CRC-8/ATM standard vector failed")
    if crc16_ccitt_false(b"123456789") != 0x29B1:
        raise AssertionError("CRC-16/CCITT-FALSE standard vector failed")
    sync_word = read_sync_word(sync_header)
    payload = bytes(range(16))
    frame = build_frame(payload, sync_word, 0x10, 0x35)
    if frame[:4] != bytes((0xAA, 0xAA, sync_word >> 8, sync_word & 0xFF)):
        raise AssertionError("frame prefix does not use the shared sync word")
    spec = ScenarioSpec("determinism", (0, 1, 0, 1), snr_db=10.0, dc_offset=0.1)
    first = synthesize(spec, 12345)
    second = synthesize(spec, 12345)
    if first != second:
        raise AssertionError("sample generation is not deterministic")
    if len(first[0]) != 4 * SAMPLES_PER_SYMBOL:
        raise AssertionError("100 bit/s timing is incorrect")
    print("PASS: CRC, shared sync word, frame format, timing, and deterministic AWGN")


def main(argv: Optional[Sequence[str]] = None) -> int:
    script_path = Path(__file__).resolve()
    project_root = script_path.parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=project_root / "simulation" / "generated",
        help="output directory (default: simulation/generated)",
    )
    parser.add_argument(
        "--sync-header",
        type=Path,
        default=project_root / "rtl" / "protocol" / "fsk_sync_word.vh",
        help="shared RTL sync-word header",
    )
    parser.add_argument(
        "--payload-hex",
        type=parse_payload,
        default=bytes(range(16)),
        help="payload for the complete-frame scenario, 0 to 64 bytes",
    )
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=DEFAULT_SEED)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.self_test:
            self_test(args.sync_header.resolve())
            return 0
        manifest = generate(args.output.resolve(), args.payload_hex, args.sync_header.resolve(), args.seed)
        print(
            f"Generated {len(manifest['scenarios'])} deterministic scenarios in "
            f"{args.output.resolve()} (seed=0x{args.seed:08X})"
        )
        print("End-to-end RTL result: NOT RUN")
        return 0
    except (OSError, ValueError, AssertionError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

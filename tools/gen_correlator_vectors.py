#!/usr/bin/env python3
"""Generate deterministic Task 4 samples and bit-exact expected metrics."""

from __future__ import annotations

import argparse
import json
import math
import random
from collections import deque
from pathlib import Path

SAMPLE_RATE = 48_000.0
WINDOW = 480
STEP = 48
CORR_SHIFT = 20
ENERGY_SHIFT = 16
ENERGY_MAX = (1 << 32) - 1


def round_away(value: float) -> int:
    if value >= 0.0:
        return int(math.floor(value + 0.5))
    return int(math.ceil(value - 0.5))


def q15(value: float) -> int:
    return round_away(32767.0 * value)


COEFFICIENTS = [
    (
        q15(math.cos(2.0 * math.pi * n / 30.0)),
        q15(math.sin(2.0 * math.pi * n / 30.0)),
        q15(math.cos(2.0 * math.pi * n / 24.0)),
        q15(math.sin(2.0 * math.pi * n / 24.0)),
    )
    for n in range(120)
]


def clip_sample(value: float) -> int:
    return max(-(1 << 19), min((1 << 19) - 1, round_away(value)))


def make_tone(
    count: int,
    frequency: float,
    amplitude: float,
    phase: float,
    dc_offset: float,
    noise_sigma: float,
    rng: random.Random,
) -> list[int]:
    result = []
    for n in range(count):
        value = (
            dc_offset
            + amplitude * math.sin(2.0 * math.pi * frequency * n / SAMPLE_RATE + phase)
            + rng.gauss(0.0, noise_sigma)
        )
        result.append(clip_sample(value))
    return result


def scale_correlator(value: int) -> int:
    magnitude = abs(value)
    shifted = (magnitude + (1 << (CORR_SHIFT - 1))) >> CORR_SHIFT
    if value < 0:
        return -min(shifted, 1 << 23)
    return min(shifted, (1 << 23) - 1)


def scale_energy(value: int) -> int:
    shifted = (value + (1 << (ENERGY_SHIFT - 1))) >> ENERGY_SHIFT
    return min(shifted, ENERGY_MAX)


def reference_metrics(samples: list[int]) -> list[dict[str, int]]:
    histories = [deque([0] * WINDOW, maxlen=WINDOW) for _ in range(4)]
    sums = [0, 0, 0, 0]
    metrics: list[dict[str, int]] = []

    for index, sample in enumerate(samples):
        coeffs = COEFFICIENTS[index % 120]
        products = [sample * coefficient for coefficient in coeffs]
        for lane in range(4):
            old_value = histories[lane][0]
            histories[lane].append(products[lane])
            sums[lane] += products[lane] - old_value

        accepted = index + 1
        if accepted >= WINDOW and accepted % STEP == 0:
            i0, q0, i1, q1 = (scale_correlator(value) for value in sums)
            energy_f0 = scale_energy(i0 * i0 + q0 * q0)
            energy_f1 = scale_energy(i1 * i1 + q1 * q1)
            total = energy_f0 + energy_f1
            soft = energy_f1 - energy_f0
            difference = abs(soft)
            confidence = 0 if total == 0 else min(255, (difference << 8) // total)
            metrics.append(
                {
                    "accepted_sample": accepted,
                    "energy_f0": energy_f0,
                    "energy_f1": energy_f1,
                    "soft_metric": soft,
                    "total_energy": total,
                    "confidence": confidence,
                    "hard_bit": int(energy_f1 > energy_f0),
                }
            )
    return metrics


def unsigned(value: int, width: int) -> int:
    return value & ((1 << width) - 1)


def pack_metric(metric: dict[str, int]) -> int:
    packed = metric["energy_f0"]
    packed |= metric["energy_f1"] << 32
    packed |= unsigned(metric["soft_metric"], 33) << 64
    packed |= metric["total_energy"] << 97
    packed |= metric["confidence"] << 130
    packed |= metric["hard_bit"] << 138
    return packed


def write_hex(path: Path, values: list[int], digits: int) -> None:
    path.write_text(
        "".join(f"{value:0{digits}x}\n" for value in values),
        encoding="ascii",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("code/cyclone10/rx_cyclone10/tb"),
    )
    args = parser.parse_args()
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(0x2F5C2026)
    segments: list[tuple[str, list[int], int | None]] = [
        ("idle_noise", [clip_sample(rng.gauss(0.0, 400.0)) for _ in range(576)], None),
        ("f0_ideal", make_tone(960, 1600.0, 120_000.0, 0.37, 12_000.0, 100.0, rng), 0),
        ("f1_ideal", make_tone(960, 2000.0, 150_000.0, -0.81, -8_000.0, 100.0, rng), 1),
        ("f0_plus_20_hz", make_tone(960, 1620.0, 100_000.0, 1.17, 4_000.0, 2_500.0, rng), 0),
        ("f1_minus_20_hz", make_tone(960, 1980.0, 100_000.0, -2.03, -3_000.0, 2_500.0, rng), 1),
        ("f0_near_full_scale", make_tone(960, 1600.0, 500_000.0, 0.11, 0.0, 0.0, rng), 0),
    ]

    samples: list[int] = []
    manifest_segments = []
    for name, values, expected_bit in segments:
        start = len(samples)
        samples.extend(values)
        manifest_segments.append(
            {
                "name": name,
                "start": start,
                "end": len(samples),
                "stable_start": start + WINDOW,
                "expected_bit": expected_bit,
            }
        )

    metrics = reference_metrics(samples)
    packed_coefficients = [
        unsigned(c0, 16) << 48
        | unsigned(s0, 16) << 32
        | unsigned(c1, 16) << 16
        | unsigned(s1, 16)
        for c0, s0, c1, s1 in COEFFICIENTS
    ]

    write_hex(
        output_dir / "fsk_correlator_samples.mem",
        [unsigned(sample, 20) for sample in samples],
        5,
    )
    write_hex(
        output_dir / "fsk_correlator_expected.mem",
        [pack_metric(metric) for metric in metrics],
        35,
    )
    write_hex(
        output_dir / "fsk_tone_coefficients.mem",
        packed_coefficients,
        16,
    )
    (output_dir / "fsk_correlator_manifest.json").write_text(
        json.dumps(
            {
                "seed": "0x2F5C2026",
                "sample_count": len(samples),
                "metric_count": len(metrics),
                "segments": manifest_segments,
                "last_metric": metrics[-1],
            },
            indent=2,
        )
        + "\n",
        encoding="ascii",
    )

    print(f"generated {len(samples)} samples and {len(metrics)} metrics in {output_dir}")


if __name__ == "__main__":
    main()


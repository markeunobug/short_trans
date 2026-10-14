#!/usr/bin/env python3
"""Reference checks for the 20 Hz-grid sweep NCO and IQ energy scaling."""

from __future__ import annotations

import math


SAMPLE_RATE = 48_000
WINDOW_SAMPLES = 4_800
CORRELATOR_SHIFT = 24
ENERGY_SHIFT = 16
AMPLITUDE = 100_000


QUARTER = [round(32767 * math.sin(2 * math.pi * i / 256)) for i in range(65)]


def sine_from_phase(phase: int) -> int:
    phase8 = (phase >> 24) & 0xFF
    offset = phase8 & 0x3F
    if phase8 & 0x40:
        offset = 64 - offset
    value = QUARTER[offset]
    return -value if phase8 & 0x80 else value


def phase_increment(frequency_hz: int) -> int:
    return ((frequency_hz << 32) + SAMPLE_RATE // 2) // SAMPLE_RATE


def energy(source_hz: int, reference_hz: int) -> int:
    source_phase = 0
    reference_phase = 0
    source_step = phase_increment(source_hz)
    reference_step = phase_increment(reference_hz)
    sum_i = 0
    sum_q = 0
    for _ in range(WINDOW_SAMPLES):
        sample = (sine_from_phase(source_phase) * AMPLITUDE) >> 15
        cosine = sine_from_phase((reference_phase + 0x40000000) & 0xFFFFFFFF)
        sine = sine_from_phase(reference_phase)
        sum_i += sample * cosine
        sum_q += sample * sine
        source_phase = (source_phase + source_step) & 0xFFFFFFFF
        reference_phase = (reference_phase + reference_step) & 0xFFFFFFFF

    scaled_i = round(sum_i / (1 << CORRELATOR_SHIFT))
    scaled_q = round(sum_q / (1 << CORRELATOR_SHIFT))
    return round((scaled_i * scaled_i + scaled_q * scaled_q) / (1 << ENERGY_SHIFT))


def main() -> None:
    frequencies = list(range(1500, 2101, 20))
    assert len(frequencies) == 31
    for frequency in frequencies:
        actual = phase_increment(frequency) * SAMPLE_RATE / (1 << 32)
        assert abs(actual - frequency) < 0.001

    matched = energy(1800, 1800)
    adjacent = energy(1800, 1820)
    distant = energy(1800, 2000)
    assert matched > 0
    assert matched > adjacent * 1000
    assert matched > distant * 1000
    print(
        "PASS: 31-point NCO grid and 100 ms single-bin IQ selectivity verified "
        f"(matched={matched}, adjacent={adjacent}, distant={distant})"
    )


if __name__ == "__main__":
    main()

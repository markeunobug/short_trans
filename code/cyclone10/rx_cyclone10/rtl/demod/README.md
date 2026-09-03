# Task 4 Fixed-Point Contract

## Interface

`fsk_demod_core` is the integration entry point in the 30 MHz `clk_sys`
domain. `sample_valid` qualifies a signed 20-bit sample. Metrics become valid
after the first 480 accepted samples and then pulse once per 48 accepted
samples. Gaps in `sample_valid` therefore do not alter the sample-domain
window or cadence.

The product-history RAM is a two-port pipeline. One port reads the products
at the current circular pointer while the other writes the previous sample's
products. The addresses are adjacent, including across the circular wrap, so
the core accepts a valid sample on every clk_sys cycle. The testbench uses
17-sample continuous bursts as well as gaps.

The wrapper deliberately does not count five carrier candidates or emit
100 bit/s symbols. Task 5 consumes `metric_valid`,
`energy_above_threshold`, `hard_bit`, `confidence_ok`, and the diagnostic
metrics. It returns its confirmed carrier/lock state on `carrier_active`,
which freezes idle noise learning.

## Fixed-point widths

| Quantity | Width | Scaling or range |
|---|---:|---|
| Input sample | signed 20 | integer, -524288 to 524287 |
| Reference coefficient | signed 16 | Q1.15, values use +/-32767 |
| Parallel I/Q product | signed 36 | exact 20 x 16 product |
| Sliding accumulator | signed 45 | exact sum/subtract of 480 products |
| Scaled I/Q | signed 24 | symmetric rounded `accumulator / 2^20`, saturated |
| Raw squared energy | unsigned 49 | sum of two signed-24 squares |
| `energy_f0/f1` | unsigned 32 | rounded `raw_energy / 2^16`, saturated |
| `soft_metric` | signed 33 | `energy_f1 - energy_f0` |
| `total_energy` | unsigned 33 | `energy_f1 + energy_f0` |
| `confidence` | unsigned 8 | floor of normalized difference times 256 |

The confidence threshold is checked without division:

```text
abs(E1-E0) * 256 >= (E1+E0) * confidence_threshold
```

`confidence_threshold = 8'd128` therefore means 0.5.

## Overflow analysis

The largest magnitude 20x16 product is below `2^34`; signed 36 bits retain
the exact result. A sum of 480 worst-direction products is below `2^43`, so
the signed 45-bit accumulators have at least one guard bit beyond the
mathematical requirement. A full-scale coherent sinusoid produces a scaled
I/Q magnitude of about 3.75 million, below signed-24 full scale. Saturation
is still implemented before squaring so unexpected or future parameter
changes cannot wrap the energy ordering. Energy is likewise saturated
instead of truncated if its shifted value exceeds 32 bits.

The four 480 x 36 product histories contain 69,120 bits. Four input
correlation multiplies and four 24 x 24 squaring multiplies are explicit.
A standalone Quartus 22.1 Analysis & Synthesis run for 10CL025YE144I7G
reported 4,211 logic elements, 1,056 registers, 69,120 memory bits, and 52
embedded 9-bit multiplier elements. The report confirms four 17,280-bit M9K
histories and OLD_DATA read semantics. Final DSP block packing and timing
remain Task 0 integration responsibilities because they require fitting the
real top-level design.

## Noise tracker

`noise_multiplier_q4_4` is unsigned Q4.4 (`8'h40` is 4.0x). The threshold is:

```text
carrier_threshold = saturate(noise_energy * multiplier / 16 + noise_offset)
```

When idle metrics lie at or below that threshold, `noise_energy` follows
them with an EWMA alpha of 1/32. A threshold crossing freezes learning
immediately; `carrier_active` keeps it frozen after Task 5 confirms carrier
or symbol lock. `noise_offset` must initially sit above the measured
idle-energy spread so the estimator can seed. The testbench defaults are
simulation values, not water-tank calibration.

# Automatic gamma stream verification

Run `reference/imu_cboard/.venv/Scripts/python.exe tests/run_adaptive_gamma.py`.

The source stage computes a frame's raw luma sum and counts dark (`Y<48`) and
highlight (`Y>=208`) pixels. `Y=floor((R+2G+B)/4)` is an inexpensive green-weighted
brightness estimate. Only DE pixels after the first VS are counted. The next
VS publishes the previous frame's statistics, including the final active
pixel and excluding a simultaneous first pixel of the new frame.

| Raw frame condition | Target curve | Exponent |
|---|---:|---:|
| Dark and highlight populations both >=1/8 | 2 | 0.80 |
| Otherwise mean <48 | 0 | 0.50 |
| Mean 48..<80 | 1 | 0.65 |
| Mean 80..<112 | 2 | 0.80 |
| Mean 112..144 | 3 | 1.00 |
| Mean >144..176 | 4 | 1.25 |
| Mean >176..208 | 5 | 1.55 |
| Mean >208 | 6 | 1.90 |

Each channel applies `round(255*(value/255)^exponent)` from an initialized
2048×8 synchronous ROM (the unused curve7 is identity). No external memory,
runtime power, division, or frame-buffer pass is required. First-frame/reset
curve is identity. The same classification must occur twice consecutively
before the target changes, and active gamma moves at most one curve per VS.
Selection and enable are constant throughout each output frame. This adds
several input-frame adaptation intervals while avoiding within-frame seams.

RGB, DE and full VS levels have two registered stages in both enabled and
bypass operation; one pixel enters and exits each clock. Input/output black
and white endpoints remain 0/255. Gamma can brighten recorded shadow detail
or improve contrast below saturation; it cannot recover clipped sensor data.

`result.log` checks all 2,048 ROM entries against mathematical powers and
monotonicity, scene responses for night/strong/mixed/neutral lighting,
two-frame decision hysteresis, frame-atomic enable changes, arbitrary RGB
channels, first/last frame pixels including coincident VS and DE, empty frames,
and the exact two-stage RGB/DE/VS cadence (15,365 checked pixels, 60 stats).

`1080p.log` checks one complete 1920×1080 white frame with 2200×1125 raster
timing at approximately 148.5 MHz, no added cycles, 2,073,600 output pixels,
and the worst full-frame luma sum of 528,768,000 without overflow.

These are functional simulation results. The combined pose/adaptive path
has also passed the sustained 30 fps tests in
[integration_128x64_bounds_pipe](../integration_128x64_bounds_pipe/README.md);
the final PDS build has passed both-corner timing and FIFO CDC checks.
Hardware image quality and frame rate still need board measurements.
When automatic gamma is active, the existing fixed display
gamma must be bypassed to avoid applying two unrelated curves.

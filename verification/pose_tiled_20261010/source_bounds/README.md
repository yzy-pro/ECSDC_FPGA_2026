# Source-cache capacity audit

Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/pose_tiled_20261010/source_bounds/run.ps1
```

This baseline audit applies to the default 1920×1080 calibration, 128×32 output tiles,
nearest sampling, exact restoring divider, and yaw/pitch Q2048 inputs in
`[-536,536]`. It does not measure frame throughput or board timing.

`sampled_49_poses.csv` evaluates every output pixel at 49 pose combinations.
Its source beat, command, and valid-pixel counts match the existing five full
RTL runs (zero and four ±536 corners) exactly. The sample's largest tile uses
600 source beats (19,200 bytes). Sampling alone does not cover every angle.
The largest sampled traffic is at yaw −179, pitch 0: 142,370 source beats and
18,477 commands, exceeding zero pose's 136,799 beats and 17,968 commands.

`conservative_bound.txt` covers every integer yaw/pitch input in the domain
using conservative integer intervals. Trigonometric bounds enumerate all
inputs within each 16-unit pose bucket. Each 8×8 output cell bounds every
integer pixel center; source bounds for its containing output tile are the
union of all cell bounds. Signed shifts, division truncation, lens arithmetic,
map validity clipping, nearest rounding, and 16-pixel DDR beat alignment follow
the current RTL. Intervals intentionally include impossible combinations,
which can enlarge bounds but cannot make the valid footprint smaller.

The resulting bound is **1,200 beats / 38,400 bytes per source tile**, below
the instantiated **2,048 beats / 65,536 bytes**. This is a software arithmetic
capacity proof for the stated model and calibration, not formal equivalence
to the HDL. `input_sha256.json` identifies the reviewed inputs. RTL changes,
different calibration, interpolation, tile sizes, or angle limits require a
fresh audit.

The subsequently selected128×64 configuration has a separate conservative
bound of1,529 beats in `conservative_bound_128x64.txt`. See
`tile_comparison.md` for reproducible dimension experiments and the measured
throughput comparison; the128×32 baseline report above remains historical.

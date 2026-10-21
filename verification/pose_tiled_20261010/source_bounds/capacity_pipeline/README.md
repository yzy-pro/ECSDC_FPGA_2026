# Registered bounding-box capacity check

The prior complete PDS run reported slow-corner DDR setup failures at the
tile renderer's state and error registers. The shared path was bounding-box
subtraction→area multiplication→capacity comparison→state/error selection;
worst slack was−0.791ns. The multiplication itself contributed about2.53ns.

The updated renderer splits these operations across P_BOUNDS, P_AREA and
P_CAPACITY. Final projection coordinates update the bounds before P_BOUNDS
captures them. Source-bank/slot ownership and descriptors remain stable while
the extra states run. Nonempty tiles add two clocks each; empty tiles go from
P_BOUNDS directly to P_READY. At128×64 there are255tiles, so the direct control
overhead is at most510clocks(5.1µs at100MHz) per frame. Arbitration phase can
change, so functional throughput still needs measurement.

Run from the repository root:

```powershell
reference/imu_cboard/.venv/Scripts/python.exe verification/pose_tiled_20261010/source_bounds/run_capacity_pipeline.py
```

`tb_tiled_capacity_pipeline.sv` uses the actual exact projector with an
identity lens and32×8 output pixels mapping into16 source beats:

- Capacity16: all256projected pixels remain valid, all16beats are fetched,
  and the full correct image is written before completion.
- Capacity8: the same16-beat footprint sets error before any read/write
  command; busy remains asserted and completion never releases ownership.
- A subsequent+15° yaw maps the whole small raster beyond its source image.
  It emits256black pixels with no further source reads or capacity-check
  state. The test deliberately poisons only the unused stale area register
  with17>16 to verify that the empty-tile bypass ignores it. Projection output
  and map-valid flags are not overridden.

All tests passed; `result.log` and `input_sha256.json` identify the result and
exact RTL inputs. This is a functional boundary regression; the new complete
PDS route must independently establish timing closure.

The updated production RTL also passed the targeted(−144,0)1080p contention
run in `../contended_128x64_yaw-144_pitch0_bounds_pipeline/`. The model retains
32-cycle DDR command latency,25% payload bubbles, one shared read/write
payload beat per clock, and35 refresh-stall clocks per780cycles. Three
complete render times were2,922,517 /3,243,757 /3,245,705clocks; the maximum is
32.45705ms at100MHz, with87,628clocks(0.87628ms) remaining below the30fps
budget. The distinct publication interval was3,333,330clocks, and8,181,083
display pixels passed the oracle. The maximum was494clocks slower than the
corresponding pre-pipeline test. Both the renderer copy and dependency hashes
are archived; prior results were not overwritten.

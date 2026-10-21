Full-frame renderer simulation, 2026-10-09

The archived source files are the exact files compiled for `full1080p.log`.
Their hashes were checked against the active source files after simulation.
`source.sha256.txt` preserves the original compilation snapshot paths.

ModelSim completed with zero errors and zero warnings. One 1920x1080 frame
at yaw Q2048=1072 and pitch Q2048=-715 (approximately +30/-20 degrees)
passed all 2,073,600 RGB565 pixel comparisons:

- Mapped pixels: 1,026,848.
- Black pixels outside the accepted mapping domain: 1,046,752.
- Source DDR word reads: 125,509.
- Completed output DDR word writes: 129,600.
- Renderer duration: 17,806,679 DDR clocks.
- At the modeled 100 MHz clock: 178.066790 ms, equivalent to 5.616 frames/s.

This duration uses the testbench's deterministic command stalls and data
return delays. It is not a board throughput measurement and excludes camera
capture, display traffic arbitration, and waiting for the output VS boundary.
The display scan continues at 60 Hz while completed rendered frames repeat.

The full-frame checker uses a second instance of the actual projector and an
independent deterministic source-pixel function. It verifies coordinate
ordering, source sampling, cache use, black borders, packing, bank/pose
snapshots, DDR backpressure, and final-write completion. Projection geometry
has separate standalone reference-coordinate checks and a reduced-frame
integration test with a floating camera oracle. The narrowed arithmetic is
also checked against full-width products independently.

Reproduce from the active workspace with:

```powershell
& 'reference/imu_cboard/.venv/Scripts/python.exe' tests/run_pose_renderer.py --modelsim D:/pango/modeltech64_10.6e/win64 --full-frame
```

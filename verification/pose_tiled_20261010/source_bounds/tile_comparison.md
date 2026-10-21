# Tile dimensions and throughput margin

Keep **128×64** among the candidates compared here. Its measured throughput
is better than256×32 in the same concurrent model, despite more write commands.
The producer's projection/loading schedule is significant: counting serialized
DDR command savings alone does not predict frame time.

`compare_tiles.ps1` / `tile_comparison.txt` contain all49 pose combinations
(yaw/pitch Q2048 values−536,−357,−179,0,179,357,536). Bounds include all valid
nearest taps of every1080p output pixel, not only tile corners. At(−179,0):

| Output tile | Source commands | Source beats | Output commands | Largest source tile across49 poses |
|---|---:|---:|---:|---:|
| 128×16 | 21,703 | 162,928 | 16,200 | 480 beats |
| 128×32 | 18,477 | 142,370 | 16,200 | 600 beats |
| 128×64 | 16,874 | 133,080 | 16,200 | 1,092 beats |
| 64×64 | 31,918 | 144,924 | 32,400 | 616 beats |
| 256×16 | 19,671 | 187,298 | 8,640 | 1,248 beats |
| 256×32 | 15,754 | 150,589 | 8,640 | 1,552 beats |

`run_tile_candidate.py` compares one full(−179,0) frame with independent
32-cycle read/write command latency and deterministic stalls, checking every
pixel using the renderer regression. It makes temporary renderer copies;
256-wide copies extend horizontal counters to9 bits. Production RTL is not
changed by the experiment.

| Output tile | Standalone render clocks | Time at100MHz |
|---|---:|---:|
| 128×64 | 2,839,702 | 28.39702ms |
| 256×16 | 3,088,796 | 30.88796ms |
| 256×32 | 2,904,737 | 29.04737ms |

`run_contended_candidate.py` compares three completed renders at(−179,0)
using the production wrapper/FIFOs/arbiter and the integration test's pixel
oracles. The model uses32-cycle command latency,25% payload bubbles, a shared
read/write payload bus, and35 clocks of refresh suspension every780 clocks.
The first render precedes active display traffic; subsequent renders include
capture and display contention. This short experiment informs dimension
selection; it does not replace the final multi-pose integration regression.

| Output tile | First render | Second render | Third render | Largest observed publication interval |
|---|---:|---:|---:|---:|
| 128×64 | 2,918,570 | 3,237,356 | 3,238,912 | 3,333,330 clocks |
| 256×32 | 2,981,672 | 3,276,971 | 3,276,522 | 3,333,330 clocks |

Both runs passed frame identity, ownership, output sampling and publication
checks. The128×64 run checked8,172,116 display pixels;256×32 checked8,220,966.
The worst128×64 result leaves94,421 clocks(0.94421ms) below33.33333ms.

The separate128×64 full five-pose24-cycle standalone regression also passed
all output pixels, with27.07757ms at zero and25.47216–25.55960ms at the four
±536 corners. Its log is `build_rebuilt/pose_tiled_full_128x64/result.log`.

The conservative integer capacity audit covers all quantized yaw/pitch
combinations[-536,536] and every pixel. For128×64 it bounds each source tile
by1,529 beats, below the2,048-beat slot. Reproduce with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/pose_tiled_20261010/source_bounds/bound_tile_variant.ps1 -TileWidth 128 -TileHeight 64 -PoseStep 16 -PixelStep 8
```

`fine_sweep.ps1` adds297 sampled poses around the high-traffic region:
yaw[-256,256] and pitch[-64,64], both at16-unit steps. The largest source
command count is16,910 at(−144,0), with134,225 beats. Compared with(−179,0),
that is36 additional commands and1,145 beats; the geometry sweep itself does
not establish a worst-case cycle bound for the complete renderer.

A targeted follow-up then ran the current production128×64 RTL at(−144,0),
using the same32-cycle/shared-payload/35-per780 refresh model. Three renders
took2,922,345 /3,243,757 /3,245,211 clocks. All checks passed, including
8,180,350 display pixels and3,333,330-clock publication intervals. The worst
measured time is32.45211ms, leaving88,122 clocks(0.88122ms) below the30fps
render budget. Reproduce with:

```powershell
reference/imu_cboard/.venv/Scripts/python.exe verification/pose_tiled_20261010/source_bounds/run_contended_candidate.py --width 128 --height 64 --yaw -144 --pitch 0
```

Artifacts are in `contended_128x64_yaw-144_pitch0/`, including the copied
renderer/testbench, exact source hashes, parameter manifest and result log.
The copied renderer was verified identical to the production source after
newline normalization. The helper changes only pose selection and the
three-render termination criterion in the copied integration testbench.

Resource estimates:128×64 and256×32 both double coordinate/output tile RAM
relative to128×32, adding roughly19.5 DRM18K equivalents. PDS implementation
of the final project remains authoritative for resources and clock timing.

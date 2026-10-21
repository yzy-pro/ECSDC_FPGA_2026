# Pose correction with a coordinate mesh

Block-level coordinate generation is feasible. A shared mesh projects sparse
control points through the complete yaw/pitch and calibrated lens model. Each
output pixel then obtains its source coordinate by interpolating the four
surrounding control points, using fixed-point increments/multipliers instead
of evaluating the full projection for every pixel. Sampling and output remain
per pixel. The current128×64 implementation instead uses blocks for DDR
caching and scheduling while retaining exact per-pixel coordinate projection.

`MeshAudit.cs` and `mesh_audit.ps1` compare coordinate meshes against the current
integer Q14/Q18 projector model with the real1920×1080 calibration. Ten poses
cover zero, yaw Q2048−144, ±536 single axes and all four(±536,±536) combinations.
Every output pixel is checked at each pose. A regular grid uses shared control
points; final control points can lie slightly beyond the output raster to keep
power-of-two spacing. Interpolation is rounded to Q14.

The following maxima are across those ten sampled poses. Error is Euclidean
source-coordinate distance in pixels. Error statistics include only cells
whose four corners and reference interior pixels are valid; other cells are
reserved for exact fallback.

| Grid spacing | Shared control-point projections/frame | Largest frame RMS | Largest frame99th percentile | Largest pixel error |
|---|---:|---:|---:|---:|
| 8×8 | 32,776 | 0.023899px | 0.097246px | 0.223320px |
| 16×16 | 8,349 | 0.067466px | 0.311294px | 0.629078px |
| 32×32 | 2,135 | 0.236549px | 1.110755px | 2.110494px |
| 64×64 | 558 | 0.833209px | 3.892534px | 6.331593px |

Zero pose alone has maximum errors0.214565px for16×16 and0.614775px for32×32.
Lens distortion therefore contributes mesh interpolation error even without
pose. For yaw/pitch, perspective division introduces further curvature;
a single translation or affine transform for a whole block is less accurate
than interpolating the combined calibrated mapping. These measurements are
**not a proof over the complete continuous or quantized angle range**, nor a
bound for different camera calibration.

Grid-coordinate bilinear interpolation and image-color bilinear sampling are
different operations. This experiment interpolates `(source_x,source_y)` and
compares against the exact coordinate map. It does not establish color error,
MTF/SFR quality, or equality with nearest sampling. Even subpixel coordinate
errors can change the selected nearest source pixel.

Boundary handling requires special care:

- Four invalid control points do not establish a wholly black cell. The
  sampled16×16 meshes contain up to4 valid interior pixels per frame inside
  cells with four invalid corners;32×32 reaches111. Treating all such cells as
  black would remove valid image content. Conservative geometric bounds or
  exact fallback are required.
- This study falls back whenever any corner is invalid. At(+536,−536), that
  covers746,496 output pixels for16×16 and766,976 for32×32, including large
  areas that are actually black. Adding those exact projections to grid nodes
  materially changes the compute-saving estimate. Safely skipping wholly
  black cells could reduce this cost, but is not implemented or proven here.
- Neighboring blocks must reuse the same projected endpoints, interpolation
  precision and rounding rules to avoid coordinate discontinuities along
  shared edges. Source-load bounding boxes must include every selected tap;
  color bilinear sampling additionally needs a one-pixel sampling halo.
- No false-valid interior pixels occurred with four valid corners in these
  ten poses. That observation does not prove this validity rule for all poses
  or future lens coefficients.

For an initial approximation design,16×16 with8×8 refinement near strongly
curved regions is more defensible than a uniform32×32 grid, given these error
measurements. A strict error guarantee would require conservative bounds or
additional adaptive subdivision and validation.

Fewer full projections do not produce the same ratio of frame-rate increase.
The present projector is already pipelined at one pixel per clock, and the
current renderer also spends time fetching DDR source regions, sampling,
writing2,073,600 output pixels and serving the display. Mesh generation could
reduce arithmetic activity/resources and shorten the tile producer's geometry
phase; actual fps improvement requires measuring the complete redesigned
producer/cache/sampler pipeline under capture/display contention.

Detailed measurements: `mesh_error_samples.csv`. These files are an analysis
only; production RTL and the running PDS input were not changed.

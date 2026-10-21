"""Explore a future tile renderer; this is a floating-point design study, not RTL.

Inverse rotation acts in the ideal image before the measured lens model.
Default mode models in-plane rotation; --yaw-pitch models the agreed axes.
All pixels of every tile are checked, rather than just its corners.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def yaw_pitch_ray(x, y, trig):
    """Reference ray -> current camera, assuming C=Ry(-yaw) Rx(-pitch).

    x right / y down / z forward; yaw up-positive, pitch head-down-positive.
    yaw is about reference up, pitch about the yawed camera right axis.
    Angles use absolute zero, with no subtraction of the startup attitude.
    """
    cy, sy, cp, sp = trig
    rotated_x = cy*x + sy
    yaw_z = -sy*x + cy
    rotated_y = cp*y - sp*yaw_z
    rotated_z = sp*y + cp*yaw_z
    if rotated_z <= 1e-9:
        return None
    return rotated_x/rotated_z, rotated_y/rotated_z


def audit(calibration, degrees, tile_size, render_fps, io_fps, overhead, pose=None):
    height, width = calibration['image_size_hw']
    matrix = calibration['intrinsic_matrix_matlab']
    fx, fy, cx, cy = matrix[0][0], matrix[1][1], matrix[2][0], matrix[2][1]
    k1, k2 = calibration['radial_distortion']
    p1, p2 = calibration['tangential_distortion']
    radians = math.radians(degrees)
    cosine, sine = math.cos(radians), math.sin(radians)
    xs = [(x + 1 - cx) / fx for x in range(width)]
    ys = [(y + 1 - cy) / fy for y in range(height)]
    # Do not extrapolate the radial polynomial arbitrarily far beyond the
    # original correction raster, where it can fold rays back onto the sensor.
    max_radius2 = max(value*value for value in xs) + max(value*value for value in ys)
    if pose is not None:
        yaw, pitch = map(math.radians, pose)
        trig = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    frame_beats = height * width // 16
    frame_bursts = height * math.ceil(width / 256)
    read_beats = read_bursts = write_bursts = valid_pixels = 0
    max_words = max_width = max_height = max_line_span = 0
    source_line_min = [height] * height
    source_line_max = [-1] * height
    behind_pixels = unsupported_pixels = 0
    for top in range(0, height, tile_size):
        for left in range(0, width, tile_size):
            bottom = min(height, top + tile_size)
            right = min(width, left + tile_size)
            min_x, min_y, max_x, max_y = width, height, -1, -1
            for y in range(top, bottom):
                yn = ys[y]
                for x in range(left, right):
                    # Inverse rotation of the ideal ray, then lens distortion.
                    xn = xs[x]
                    if pose is None:
                        rx, ry = cosine * xn + sine * yn, -sine * xn + cosine * yn
                    else:
                        ray = yaw_pitch_ray(xn, yn, trig)
                        if ray is None:
                            behind_pixels += 1
                            continue
                        rx, ry = ray
                    radius2 = rx * rx + ry * ry
                    if pose is not None and radius2 > max_radius2:
                        unsupported_pixels += 1
                        continue
                    scale = 1 + k1 * radius2 + k2 * radius2 * radius2
                    u = fx * (rx * scale + 2*p1*rx*ry + p2*(radius2+2*rx*rx)) + cx - 1
                    v = fy * (ry * scale + p1*(radius2+2*ry*ry) + 2*p2*rx*ry) + cy - 1
                    # A black border is used if any interpolation tap is outside.
                    if not (0 <= u < width-1 and 0 <= v < height-1):
                        continue
                    sx, sy = math.floor(u), math.floor(v)
                    valid_pixels += 1
                    min_x, max_x = min(min_x, sx), max(max_x, sx+1)
                    min_y, max_y = min(min_y, sy), max(max_y, sy+1)
                    source_line_min[y] = min(source_line_min[y], sy)
                    source_line_max[y] = max(source_line_max[y], sy+1)
            # RGB565, 256-bit DDR beats; future controller must support 1..16 beats.
            write_bursts += (bottom-top) * math.ceil((right-left) / 256)
            if max_x < 0:
                continue
            row_words = max_x//16 - min_x//16 + 1
            row_count = max_y-min_y+1
            read_beats += row_words*row_count
            read_bursts += math.ceil(row_words/16)*row_count
            max_words = max(max_words, row_words*row_count)
            max_width = max(max_width, row_words*16)
            max_height = max(max_height, row_count)
    for lo, hi in zip(source_line_min, source_line_max):
        if hi >= 0:
            max_line_span = max(max_line_span, hi-lo+1)
    # Input write + linear display read run at io_fps; corrected output at render_fps.
    beats_per_second = 2*frame_beats*io_fps + (read_beats+frame_beats)*render_fps
    bursts_per_second = 2*frame_bursts*io_fps + (read_bursts+write_bursts)*render_fps
    ideal_cycles = beats_per_second + overhead*bursts_per_second
    return {
        'angle_deg': degrees if pose is None else None,
        'yaw_pitch_deg': pose, 'tile_size': tile_size,
        'valid_pixels': valid_pixels, 'outside_pixels': width*height-valid_pixels,
        'behind_camera_pixels': behind_pixels,
        'outside_reference_radial_domain_pixels': unsupported_pixels,
        'max_source_rows_per_output_line': max_line_span,
        'source_read_beats_per_frame': read_beats,
        'source_read_bursts_per_frame': read_bursts,
        'output_write_bursts_per_frame': write_bursts,
        'max_source_tile_bytes': max_words*32,
        'max_aligned_source_width': max_width, 'max_source_tile_height': max_height,
        'aggregate_MB_per_second': round(beats_per_second*32/1e6, 3),
        'serialized_100MHz_utilization': round(ideal_cycles/100e6, 6),
        'assumed_non_data_cycles_per_burst': overhead,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--angles', type=float, nargs='+', default=[0,30,45,60,90,135,180,270])
    parser.add_argument('--yaw-pitch', type=float, nargs=2, action='append',
                        help='absolute yaw/pitch degrees; repeat for multiple poses; roll ignored')
    parser.add_argument('--tile-size', type=int, default=64)
    parser.add_argument('--render-fps', type=float, default=30)
    parser.add_argument('--io-fps', type=float, default=60)
    parser.add_argument('--burst-overhead', type=int, default=24)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.tile_size <= 0 or args.tile_size % 16 or args.render_fps <= 0 or args.io_fps <= 0 or args.burst_overhead < 0:
        parser.error('tile size must be a positive multiple of 16; rates positive; overhead nonnegative')
    if not all(math.isfinite(angle) for angle in args.angles):
        parser.error('angles must be finite')
    if args.yaw_pitch and not all(math.isfinite(a) for pose in args.yaw_pitch for a in pose):
        parser.error('yaw/pitch must be finite')
    path = ROOT/'calibration/camera_20260930.json'
    calibration = json.loads(path.read_text(encoding='utf-8'))
    cases = []
    inputs = [(0, pose) for pose in args.yaw_pitch] if args.yaw_pitch else [(a, None) for a in args.angles]
    for angle, pose in inputs:
        case = audit(calibration, angle, args.tile_size, args.render_fps, args.io_fps, args.burst_overhead, pose)
        cases.append(case)
        label = f'yaw={pose[0]:g},pitch={pose[1]:g}' if pose is not None else f'angle={angle:g}'
        print(f"{label}: source tile {case['max_source_tile_bytes']} bytes, "
              f"line span {case['max_source_rows_per_output_line']} rows, "
              f"{case['aggregate_MB_per_second']:.1f} MB/s, "
              f"serialized DDR estimate {100*case['serialized_100MHz_utilization']:.1f}%", flush=True)
    report = {
        'model': ('float64 absolute yaw/pitch perspective, then lens distortion, four-tap sampling'
                  if args.yaw_pitch else 'float64 inverse in-plane rotation, then lens distortion, four-tap sampling'),
        'status': 'architecture exploration only; no RTL or board throughput proof',
        'calibration_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'render_fps': args.render_fps, 'input_and_display_fps': args.io_fps,
        'pose_convention': ('C=Ry(-yaw)Rx(-pitch), camera x right/y down/z forward; '
                            'yaw up-positive; pitch down-positive; absolute zero; roll ignored'
                            if args.yaw_pitch else None),
        'radial_domain_policy': ('reject rays beyond maximum normalized radius of original raster; '
                                 'a numerical extrapolation guard, not an independently calibrated field of view'
                                 if args.yaw_pitch else None),
        'requires': ['variable 1..16 beat AXI bursts', 'input/render/display arbitration',
                     'separate corrected-frame banks and ownership', 'tile resampling/output writes'],
        'limitations': ['angle samples do not prove all angles or tilted camera poses',
                        'DDR refresh, row/page misses and read/write turnaround not simulated',
                        'cache banking, power-of-two RAM rounding and compute throughput excluded',
                        'burst overhead is a sensitivity input, not measured hardware latency',
                        'fixed16-beat existing adapter cannot implement these transfer counts'],
        'cases': cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    main()

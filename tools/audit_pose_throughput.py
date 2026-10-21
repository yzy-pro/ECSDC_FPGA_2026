"""Pixel-exact floating-point tile capacity and throughput study; not an RTL proof.

Geometry follows audit_rotation_tiles.py. Each pose is projected once into a
common fine tile grid; larger tile bounding boxes are unions of those boxes.
No corner-only bound is used. All output pixels, including black pixels, still
require output writes and display reads.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parents[1]
BEAT_BYTES = 32
PIXELS_PER_BEAT = 16
MAX_BURST_BEATS = 16


def ceildiv(value, divisor):
    return (value + divisor - 1) // divisor


def geometry(calibration, pose, tile_sizes):
    """Return exact bounding rectangles of every accepted four-tap footprint."""
    height, width = calibration['image_size_hw']
    matrix = calibration['intrinsic_matrix_matlab']
    fx, fy, cx, cy = matrix[0][0], matrix[1][1], matrix[2][0], matrix[2][1]
    k1, k2 = calibration['radial_distortion']
    p1, p2 = calibration['tangential_distortion']
    xs = [(x + 1 - cx) / fx for x in range(width)]
    ys = [(y + 1 - cy) / fy for y in range(height)]
    max_radius2 = max(x*x for x in xs) + max(y*y for y in ys)
    yaw, pitch = map(math.radians, pose)
    cyaw, syaw, cpitch, spitch = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    fine_size = math.gcd(*tile_sizes)
    fine_cols = ceildiv(width, fine_size)
    fine_rows = ceildiv(height, fine_size)
    bounds = [[width, height, -1, -1] for _ in range(fine_cols*fine_rows)]
    # All terms independent of output y are computed once, preserving the
    # operation order of the existing floating-point reference.
    x_terms = [(cyaw*x + syaw, -syaw*x + cyaw, i//fine_size)
               for i, x in enumerate(xs)]
    valid = behind = outside_radial = outside_sensor = 0
    for y, yn in enumerate(ys):
        base = (y//fine_size)*fine_cols
        for rotated_x, yaw_z, fine_col in x_terms:
            rotated_y = cpitch*yn - spitch*yaw_z
            rotated_z = spitch*yn + cpitch*yaw_z
            if rotated_z <= 1e-9:
                behind += 1
                continue
            rx, ry = rotated_x/rotated_z, rotated_y/rotated_z
            radius2 = rx*rx + ry*ry
            if radius2 > max_radius2:
                outside_radial += 1
                continue
            scale = 1 + k1*radius2 + k2*radius2*radius2
            u = fx*(rx*scale + 2*p1*rx*ry + p2*(radius2+2*rx*rx)) + cx - 1
            v = fy*(ry*scale + p1*(radius2+2*ry*ry) + 2*p2*rx*ry) + cy - 1
            if not (0 <= u < width-1 and 0 <= v < height-1):
                outside_sensor += 1
                continue
            valid += 1
            sx, sy = math.floor(u), math.floor(v)
            box = bounds[base+fine_col]
            if sx < box[0]: box[0] = sx
            if sy < box[1]: box[1] = sy
            if sx+1 > box[2]: box[2] = sx+1
            if sy+1 > box[3]: box[3] = sy+1
    assert valid + behind + outside_radial + outside_sensor == width*height
    result = []
    for tile_size in tile_sizes:
        cols, rows = ceildiv(width, tile_size), ceildiv(height, tile_size)
        combined = [[width, height, -1, -1] for _ in range(cols*rows)]
        for index, box in enumerate(bounds):
            if box[2] < 0:
                continue
            left = (index % fine_cols)*fine_size
            top = (index // fine_cols)*fine_size
            dest = combined[(top//tile_size)*cols + left//tile_size]
            dest[0], dest[1] = min(dest[0], box[0]), min(dest[1], box[1])
            dest[2], dest[3] = max(dest[2], box[2]), max(dest[3], box[3])
        reads = bursts = max_tile_beats = max_rows = max_words = active_tiles = 0
        for lo_x, lo_y, hi_x, hi_y in combined:
            if hi_x < 0:
                continue
            active_tiles += 1
            words = hi_x//PIXELS_PER_BEAT - lo_x//PIXELS_PER_BEAT + 1
            count = hi_y-lo_y+1
            reads += words*count
            bursts += ceildiv(words, MAX_BURST_BEATS)*count
            max_tile_beats = max(max_tile_beats, words*count)
            max_rows, max_words = max(max_rows, count), max(max_words, words)
        output_bursts = height*sum(ceildiv(min(tile_size, width-left),
                                          PIXELS_PER_BEAT*MAX_BURST_BEATS)
                                   for left in range(0, width, tile_size))
        result.append({
            'yaw_pitch_deg': list(pose), 'tile_size': tile_size,
            'output_pixels_per_frame': width*height,
            'valid_pixels': valid, 'black_pixels': width*height-valid,
            'behind_camera_pixels': behind,
            'outside_reference_radial_domain_pixels': outside_radial,
            'outside_sensor_pixels': outside_sensor,
            'output_tiles_per_frame': rows*cols,
            'source_tiles_fetched_per_frame': active_tiles,
            'source_read_beats_per_frame': reads,
            'source_read_bursts_per_frame': bursts,
            'output_write_bursts_per_frame': output_bursts,
            'max_source_tile_bytes': max_tile_beats*BEAT_BYTES,
            'max_aligned_source_width_pixels': max_words*PIXELS_PER_BEAT,
            'max_source_tile_rows': max_rows,
        })
    return result


def add_budget(case, width, height, capture_fps, render_fps, display_fps,
               overheads, ddr_hz, drm_blocks):
    """Account for payload and serialized burst cost independently of geometry."""
    frame_beats = height*ceildiv(width, PIXELS_PER_BEAT)
    frame_bursts = height*ceildiv(ceildiv(width, PIXELS_PER_BEAT), MAX_BURST_BEATS)
    channels = {
        'capture_write': (frame_beats, frame_bursts, capture_fps),
        'source_tile_read': (case['source_read_beats_per_frame'],
                             case['source_read_bursts_per_frame'], render_fps),
        'corrected_frame_write': (frame_beats, case['output_write_bursts_per_frame'], render_fps),
        'display_read': (frame_beats, frame_bursts, display_fps),
    }
    case['transfers'] = {
        name: {'beats_per_frame': beats, 'bursts_per_frame': bursts, 'frames_per_second': fps,
               'bytes_per_frame': beats*BEAT_BYTES, 'MB_per_second': beats*BEAT_BYTES*fps/1e6}
        for name, (beats, bursts, fps) in channels.items()
    }
    beats_per_second = sum(beats*fps for beats, _, fps in channels.values())
    bursts_per_second = sum(bursts*fps for _, bursts, fps in channels.values())
    case['aggregate_MB_per_second'] = beats_per_second*BEAT_BYTES/1e6
    case['aggregate_bursts_per_second'] = bursts_per_second
    case['serialized_ddr_sensitivity'] = [
        {'extra_cycles_per_burst': overhead,
         'cycles_per_second': beats_per_second+overhead*bursts_per_second,
         'utilization': (beats_per_second+overhead*bursts_per_second)/ddr_hz}
        for overhead in overheads
    ]
    tile = case['tile_size']
    source_bytes = 2*case['max_source_tile_bytes']
    output_bytes = 2*min(tile, width)*min(tile, height)*2
    coordinate_bytes = 3*min(tile, width)*min(tile, height)*36//8
    capacity = drm_blocks*18*1024//8
    case['raw_tile_ram'] = {
        'source_double_buffer_bytes': source_bytes,
        'output_double_buffer_bytes': output_bytes,
        'total_bytes': source_bytes+output_bytes,
        'device_drm18k_nominal_bytes': capacity,
        'fraction_of_all_device_nominal_drm': (source_bytes+output_bytes)/capacity,
        'bytes_remaining_before_any_other_storage': capacity-source_bytes-output_bytes,
        'three_coordinate_slots_36bit_bytes': coordinate_bytes,
        'total_with_three_coordinate_slots_bytes': source_bytes+output_bytes+coordinate_bytes,
        'bytes_remaining_after_coordinate_slots_before_other_storage': capacity-source_bytes-output_bytes-coordinate_bytes,
    }
    return case


def compute_budget(width, height, fps):
    pixels = width*height
    result = []
    for clock_hz, lanes in ((100_000_000, 1), (100_000_000, 2), (148_500_000, 1)):
        for passes in (1, 2):
            cycles = ceildiv(pixels, lanes)*passes
            result.append({
                'clock_hz': clock_hz, 'pixels_per_cycle': lanes, 'geometry_passes': passes,
                'required_cycles_per_frame': cycles,
                'ideal_compute_only_max_fps': clock_hz/cycles,
                'utilization_at_render_fps': cycles*fps/clock_hz,
                'cycles_per_frame_remaining_for_stalls': clock_hz/fps-cycles,
            })
    return result


def run_pose(job):
    return geometry(*job)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--calibration', type=Path, default=ROOT/'calibration/camera_20260930.json')
    parser.add_argument('--tile-sizes', type=int, nargs='+', default=[64, 128])
    parser.add_argument('--yaw-pitch', type=float, nargs=2, action='append')
    parser.add_argument('--capture-fps', type=float, default=60)
    parser.add_argument('--render-fps', type=float, default=60)
    parser.add_argument('--display-fps', type=float, default=60)
    parser.add_argument('--extra-cycles-per-burst', type=int, nargs='+', default=[8, 12, 16, 24])
    parser.add_argument('--ddr-hz', type=int, default=100_000_000)
    parser.add_argument('--drm18k-blocks', type=int, default=134)
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if any(t <= 0 or t % 16 for t in args.tile_sizes):
        parser.error('tile sizes must be positive multiples of 16')
    rates = (args.capture_fps, args.render_fps, args.display_fps)
    if any(not math.isfinite(rate) or rate <= 0 for rate in rates):
        parser.error('all frame rates must be finite and positive')
    if min(args.workers, args.ddr_hz, args.drm18k_blocks) <= 0 or min(args.extra_cycles_per_burst) < 0:
        parser.error('worker count, DDR clock and RAM capacity must be positive; overhead nonnegative')
    grid = [-90, -60, -30, 0, 30, 60, 90]
    poses = args.yaw_pitch or [(yaw, pitch) for yaw in grid for pitch in grid] + [
        (-15, 0), (15, 0), (0, -15), (0, 15), (30, 20), (-30, -20), (60, 30)]
    # (60,30) already occurs in the grid: preserve only distinct poses.
    poses = list(dict.fromkeys(tuple(pose) for pose in poses))
    if not all(math.isfinite(angle) for pose in poses for angle in pose):
        parser.error('pose angles must be finite')
    calibration = json.loads(args.calibration.read_text(encoding='utf-8'))
    height, width = calibration['image_size_hw']
    started = time.monotonic()
    cases = []
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(run_pose, (calibration, pose, args.tile_sizes)): pose for pose in poses}
        for count, future in enumerate(as_completed(jobs), 1):
            for case in future.result():
                cases.append(add_budget(case, width, height, *rates,
                                        args.extra_cycles_per_burst, args.ddr_hz, args.drm18k_blocks))
            print(f'{count}/{len(poses)} poses complete, {time.monotonic()-started:.1f}s, pose={jobs[future]}', flush=True)
    cases.sort(key=lambda case: (case['tile_size'], case['yaw_pitch_deg']))
    summaries = []
    for tile in args.tile_sizes:
        selected = [case for case in cases if case['tile_size'] == tile]
        bandwidth = max(selected, key=lambda case: case['aggregate_MB_per_second'])
        ram = max(selected, key=lambda case: case['max_source_tile_bytes'])
        summaries.append({
            'tile_size': tile,
            'maximum_sampled_aggregate_MB_per_second': bandwidth['aggregate_MB_per_second'],
            'maximum_sampled_bandwidth_pose': bandwidth['yaw_pitch_deg'],
            'maximum_sampled_source_tile_bytes': ram['max_source_tile_bytes'],
            'maximum_sampled_source_tile_pose': ram['yaw_pitch_deg'],
            'maximum_sampled_raw_tile_ram': ram['raw_tile_ram'],
            'maximum_sampled_serialized_ddr': [max(
                ({'yaw_pitch_deg': case['yaw_pitch_deg'], **case['serialized_ddr_sensitivity'][index]}
                 for case in selected), key=lambda item: item['utilization'])
                for index in range(len(args.extra_cycles_per_burst))],
        })
    source_files = [Path(__file__), ROOT/'tools/audit_rotation_tiles.py',
                    ROOT/'tests/test_pose_throughput.py']
    report = {
        'status': 'floating-point architecture budget only; no RTL, timing, DDR trace or board throughput proof',
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'wall_seconds': time.monotonic()-started,
        'image_size_hw': [height, width], 'unique_pose_count': len(poses),
        'tile_size_case_count': len(cases),
        'output_pixels_per_frame': width*height,
        'required_output_pixels_per_second': width*height*args.render_fps,
        'frame_payload_bytes_RGB565': width*height*2,
        'capture_fps': args.capture_fps, 'render_fps': args.render_fps, 'display_fps': args.display_fps,
        'ddr_clock_hz': args.ddr_hz, 'ddr_payload_bits_per_beat': 256,
        'ddr_ideal_data_MB_per_second': args.ddr_hz*BEAT_BYTES/1e6,
        'calibration_sha256': digest(args.calibration),
        'code_sha256': {str(path.relative_to(ROOT)): digest(path) for path in source_files if path.exists()},
        'pose_convention': 'C=Ry(-yaw)Rx(-pitch); reference up-positive yaw; head-down-positive pitch; absolute angles; roll ignored; IMU Euler order still requires confirmation',
        'radial_domain_policy': 'reject normalized radius outside original raster domain; numerical extrapolation guard, not a measured optical FOV',
        'geometry_sampling': 'every output pixel of every selected pose; larger tile bounds merge exact fine-tile bounds',
        'compute_budget': compute_budget(width, height, args.render_fps),
        'sampled_summaries': summaries,
        'limitations': [
            'Discrete angle samples do not bound the full continuous yaw/pitch domain.',
            'Black pixels reduce source reads but still consume full output and display traffic.',
            'Extra cycles per burst are sensitivity assumptions, not measured DDR latency; refresh, row misses, turnaround and overlap are not simulated.',
            'Each transfer uses 256-bit payload beats and variable 1..16-beat bursts; existing write command splitting emits a full first burst and permits a short trailing burst, so standalone short requests require adapter changes.',
            'Two geometry passes mean recomputing every output coordinate for bounding-box discovery and sampling on one shared engine; two independent engines instead need extra logic.',
            'Compute maximum FPS assumes ideal initiation interval and no bubbles; excludes pipeline filling, DDR stalls, filtering and control overhead.',
            'RAM figures separately show two source rectangles plus two RGB565 output tiles, and then add three coordinate slots at 36 bits per pixel (33 useful bits assumed). All are raw bytes excluding RAM rounding, parity/port banking, FIFOs and existing buffers.',
            'Oversized source rectangles require adaptive output-tile subdivision; no finite-angle guarantee follows from this sampled maximum.',
            'Lens calibration and Euler order require physical validation; no fixed-point numerical error is modeled.',
        ],
        'cases': cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(summaries, indent=2))


if __name__ == '__main__':
    main()

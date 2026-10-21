"""Check the proposed pose reference against independently constructed camera axes."""
import math
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from audit_rotation_tiles import yaw_pitch_ray


def trig(yaw, pitch):
    yaw, pitch = math.radians(yaw), math.radians(pitch)
    return math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)


def main():
    for degrees in (-30, -10, 10, 30):
        yaw_ray = yaw_pitch_ray(0, 0, trig(degrees, 0))
        pitch_ray = yaw_pitch_ray(0, 0, trig(0, degrees))
        assert math.isclose(yaw_ray[0], math.tan(math.radians(degrees)), abs_tol=1e-12)
        assert yaw_ray[1] == 0
        assert pitch_ray[0] == 0
        assert math.isclose(pitch_ray[1], -math.tan(math.radians(degrees)), abs_tol=1e-12)
    assert yaw_pitch_ray(0, 0, trig(180, 0)) is None
    assert yaw_pitch_ray(0, 0, trig(0, 180)) is None
    assert yaw_pitch_ray(0, 0, trig(90, 0)) is None
    assert yaw_pitch_ray(0, 0, trig(0, 90)) is None
    rng = random.Random(20261009)
    for _ in range(2000):
        x, y = rng.uniform(-1.3, 1.3), rng.uniform(-0.8, 0.8)
        yaw, pitch = rng.uniform(-80, 80), rng.uniform(-70, 70)
        cy, sy, cp, sp = values = trig(yaw, pitch)
        # Camera basis in the reference frame, built independently of the
        # sequential ray rotations in the implementation.
        right = (cy, 0, sy)
        down = (sy*sp, cp, -cy*sp)
        forward = (-sy*cp, sp, cy*cp)
        dot = lambda axis: axis[0]*x + axis[1]*y + axis[2]
        depth = dot(forward)
        result = yaw_pitch_ray(x, y, values)
        if depth <= 1e-9:
            assert result is None
        else:
            assert math.isclose(result[0], dot(right)/depth, rel_tol=1e-11, abs_tol=1e-11)
            assert math.isclose(result[1], dot(down)/depth, rel_tol=1e-11, abs_tol=1e-11)
        assert yaw_pitch_ray(x, y, trig(0, 0)) == (x, y)
    print('PASS yaw/pitch reference: axis signs, absolute zero, 2000 independent basis checks, rear/horizon rejection')


if __name__ == '__main__':
    main()

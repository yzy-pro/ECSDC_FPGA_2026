"""Historical uniform-cache feasibility audit; never rewrite RTL.

This compares against the OLD 72-row rectangular cache, not the current
eight-band cache. Validate the latter with tests/verify_cache_windows_1920.py.

Projection uses Q14 lens coefficients and Q22 coordinate increments, matching
the intended existing pipeline conventions. Unlike the old scale_fx/scale_fy
shift-add functions, fractional focal lengths are retained in the audit.
"""
import argparse
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def audit(path):
    c = json.loads(path.read_text(encoding='utf-8'))
    h, w = c['image_size_hw']
    m = c['intrinsic_matrix_matlab']
    fx, fy, cx, cy = m[0][0], m[1][1], m[2][0], m[2][1]
    k1, k2 = c['radial_distortion']
    p1, p2 = c['tangential_distortion']
    assert m[0][1:] == [0, 0] and m[1][0] == 0 and m[1][2] == 0
    assert m[2][2] == 1 and fx > 0 and fy > 0
    q14 = lambda x: round(x * (1 << 14))
    q22 = lambda x: round(x * (1 << 22))
    fqx, fqy, cqx, cqy = map(q14, (fx, fy, cx, cy))
    kq1, kq2, pq1, pq2 = map(q14, (k1, k2, p1, p2))
    ax, ay = q22((1-cx)/fx), q22((1-cy)/fy)
    dx, dy = q22(1/fx), q22(1/fy)
    xs = [(ax+x*dx) >> 8 for x in range(w)]
    x_min, x_max = w, -1
    windows = []
    float_windows = []
    error = [0.0, 0.0]
    for row in range(h):
        y = (ay+row*dy) >> 8
        yf = (row+1-cy)/fy
        low, high, flow, fhigh = h, -1, h, -1
        for col, x in enumerate(xs):
            xx, yy, xy = x*x >> 14, y*y >> 14, x*y >> 14
            r2 = (x*x+y*y) >> 14
            r4 = r2*r2 >> 14
            scale = 16384 + ((kq1*r2) >> 14) + ((kq2*r4) >> 14)
            tx = ((pq1*xy) >> 13) + ((pq2*(r2+2*xx)) >> 14)
            ty = ((pq1*(r2+2*yy)) >> 14) + ((pq2*xy) >> 13)
            xd, yd = ((x*scale) >> 14)+tx, ((y*scale) >> 14)+ty
            assert all(-131072 <= z <= 131071 for z in (r2,r4,scale,tx,ty,xd,yd))
            u = ((xd*fqx) >> 14)+cqx
            v = ((yd*fqy) >> 14)+cqy
            sx = max(0,min(w-1,(u >> 14)-1))
            sy = max(0,min(h-1,(v >> 14)-1))
            x_min, x_max = min(x_min,sx), max(x_max,min(w-1,sx+1))
            low, high = min(low,sy), max(high,min(h-1,sy+1))
            # Independent floating-point MATLAB-convention inverse map.
            xf = (col+1-cx)/fx
            rf = xf*xf+yf*yf
            sf = 1+k1*rf+k2*rf*rf
            uf = (xf*sf+2*p1*xf*yf+p2*(rf+2*xf*xf))*fx+cx
            vf = (yf*sf+p1*(rf+2*yf*yf)+2*p2*xf*yf)*fy+cy
            error[0] = max(error[0],abs(u/16384-uf))
            error[1] = max(error[1],abs(v/16384-vf))
            syf = max(0,min(h-1,math.floor(vf)-1))
            flow,fhigh = min(flow,syf),max(fhigh,min(h-1,syf+1))
        windows.append((low,high))
        float_windows.append((flow,fhigh))
    lines, words, first = 72, 100, 8
    rows = max(hi-lo+1 for lo,hi in windows)
    first_word,last_word = x_min//16,x_max//16
    need_words = last_word-first_word+1
    bits = rows*need_words*272
    issues = []
    if rows > lines:
        issues.append(f'row cache insufficient: requires {rows}, has {lines}')
    if first_word < first or last_word >= first+words:
        issues.append(f'horizontal aperture insufficient: requires beats {first_word}..{last_word}, has {first}..{first+words-1}')
    if bits > 134*18432:
        issues.append('uniform full-row cache exceeds even the entire 134 DRM18K capacity, before other IP')
    return {
        'input': c, 'audit_modifies_rtl': False,
        'comparison_target': 'historical 72-line uniform cache; NOT current eight-band cache',
        'q14': dict(zip(('fx','fy','cx','cy','k1','k2','p1','p2'),(fqx,fqy,cqx,cqy,kq1,kq2,pq1,pq2))),
        'q22': {'xn_start':ax,'yn_start':ay,'xn_step':dx,'yn_step':dy},
        'checked_output_pixels':w*h, 'source_x_taps_inclusive':[x_min,x_max],
        'required_uniform_cache_rows':rows,'floating_reference_max_rows':max(b-a+1 for a,b in float_windows),
        'required_uniform_cache_words_per_row':need_words,
        'first_window':windows[0],'last_window':windows[-1],
        'source_row_max_steps':sorted(set(b[1]-a[1] for a,b in zip(windows,windows[1:]))),
        'ideal_minimum_drm18k_for_272bit_uniform_cache':math.ceil(bits/18432),
        'max_q14_projection_error_pixels':error,
        'compatible_with_legacy_uniform_cache':not issues,'blocking_issues':issues,
        'note':'Uniform-cache comparison only; use eight-band tests and current PDS reports for the new implementation.'
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--calibration',type=Path,default=ROOT/'calibration/camera_20260930.json')
    parser.add_argument('--report',type=Path)
    parser.add_argument('--require-supported',action='store_true')
    args = parser.parse_args()
    result = audit(args.calibration)
    output = json.dumps(result,ensure_ascii=False,indent=2)+'\n'
    if args.report:
        args.report.write_text(output,encoding='utf-8')
    print(output,end='')
    if args.require_supported and not result['compatible_with_legacy_uniform_cache']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()

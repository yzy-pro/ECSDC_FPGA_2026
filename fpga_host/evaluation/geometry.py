"""Chessboard geometry measured in original image pixels, without rectification."""
import cv2
import numpy as np


def fit_line(points):
    points = np.asarray(points, dtype=float).reshape(-1, 2)
    center = points.mean(axis=0)
    _, _, axes = np.linalg.svd(points-center, full_matrices=False)
    normal = axes[-1]
    return np.abs((points-center) @ normal)


def summarize(distances):
    d = np.asarray(distances, dtype=float)
    if not d.size:
        return None
    return dict(rms_px=float(np.sqrt(np.mean(d*d))), p95_px=float(np.percentile(d, 95)),
                max_px=float(d.max()), samples=int(d.size))


def board_segments(corners, pattern):
    cols, rows = pattern
    grid = corners.reshape(rows, cols, 2)
    segments = []
    for r in range(rows):
        for c in range(cols-1):
            segments.append((f'R{r+1}', grid[r, c], grid[r, c+1]))
    for c in range(cols):
        for r in range(rows-1):
            segments.append((f'C{c+1}', grid[r, c], grid[r+1, c]))
    return segments


def geometry_metrics(gray, corners, pattern):
    cols, rows = pattern
    grid = corners.reshape(rows, cols, 2)
    lines = [*grid, *grid.transpose(1, 0, 2)]
    corner_error = np.concatenate([fit_line(line) for line in lines])
    # Sample real edge intensity across each inter-corner segment. Do not use
    # interpolated corner coordinates themselves as evidence of straightness.
    traced = {}
    accepted = total = 0
    for name, start, end in board_segments(corners, pattern):
        delta = end-start
        length = np.linalg.norm(delta)
        if length < 12:
            continue
        tangent = delta/length
        normal = np.array([-tangent[1], tangent[0]])
        count = max(8, int(length*.65/2))
        centers = start + np.linspace(.18, .82, count)[:, None]*delta
        radius = min(8., length*.12)
        offsets = np.arange(-radius, radius+.25, .5)
        coords = centers[:, None, :] + offsets[None, :, None]*normal
        values = cv2.remap(gray, coords[:, :, 0].astype(np.float32),
                           coords[:, :, 1].astype(np.float32), cv2.INTER_LINEAR,
                           borderMode=cv2.BORDER_REPLICATE).astype(float)
        gradient = np.abs(np.gradient(values, .5, axis=1))
        peaks = gradient.argmax(axis=1)
        good = (np.ptp(values, axis=1) >= 25) & (peaks > 1) & (peaks < len(offsets)-2)
        valid = np.flatnonzero(good)
        if len(valid):
            k = peaks[valid]
            a, b, c = gradient[valid, k-1], gradient[valid, k], gradient[valid, k+1]
            denominator = a-2*b+c
            fraction = np.divide(.5*(a-c), denominator, out=np.zeros_like(b), where=np.abs(denominator)>1e-6)
            shift = offsets[k] + .5*np.clip(fraction, -.5, .5)
            points = centers[valid] + shift[:, None]*normal
            traced.setdefault(name, []).extend(points)
        accepted += int(good.sum())
        total += count
    edge_distances = []
    per_line = []
    for name, points in traced.items():
        if len(points) >= 12:
            distances = fit_line(points)
            edge_distances.extend(distances)
            per_line.append(dict(line=name, **summarize(distances)))
    obj = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2).astype(float)
    homography, _ = cv2.findHomography(obj, corners.reshape(-1, 2), 0)
    grid_residual = None
    if homography is not None:
        projected = cv2.perspectiveTransform(obj.reshape(-1, 1, 2), homography).reshape(-1, 2)
        grid_residual = summarize(np.linalg.norm(projected-corners.reshape(-1, 2), axis=1))
    coverage = cv2.contourArea(cv2.convexHull(corners.astype(np.float32)))/(gray.shape[0]*gray.shape[1])
    return dict(corner_straightness=summarize(corner_error), edge_straightness=summarize(edge_distances),
                grid_homography_residual=grid_residual, edge_sample_valid_ratio=accepted/total if total else None,
                coverage_ratio=float(coverage), lines=per_line)

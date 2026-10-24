"""Relative slanted-edge SFR. Not a certified ISO 12233 implementation."""
import cv2
import numpy as np
from fpga_host.evaluation.geometry import board_segments


def slanted_edge_sfr(roi, response='unknown'):
    """Vertical-ish edge; transpose horizontal edges before calling.

    Distances and frequency are in the original image pixel grid, not in a
    perspective-warped board. Saturated, low-contrast and undersampled edges
    return a reason instead of a numeric MTF50.
    """
    image = roi.astype(float)/255.
    if min(image.shape) < 12 or image.shape[0] < 24:
        raise ValueError('边缘 ROI 太小')
    if np.mean((roi <= 2) | (roi >= 253)) > .02:
        raise ValueError('边缘过曝或欠曝，存在端点饱和')
    if response == 'srgb':
        image = np.where(image <= .04045, image/12.92, ((image+.055)/1.055)**2.4)
    gradient = np.abs(np.gradient(image, axis=1))
    peaks = gradient.argmax(axis=1)
    y = np.arange(image.shape[0])
    if np.mean((peaks >= 2) & (peaks < image.shape[1]-2)) < .95:
        raise ValueError('边缘超出 ROI')
    xgrid = np.arange(image.shape[1])
    weights = gradient * (np.abs(xgrid[None, :]-peaks[:, None]) <= 3)
    edge = (weights*xgrid).sum(axis=1)/np.maximum(weights.sum(axis=1), 1e-9)
    slope, intercept = np.polyfit(y, edge, 1)
    angle = float(np.degrees(np.arctan(abs(slope))))
    if not 1.5 <= angle <= 15:
        raise ValueError(f'斜边角度 {angle:.1f}°，请将棋盘格旋转约 5°（允许 1.5～15°）')
    residual = np.sqrt(np.mean((edge-(slope*y+intercept))**2))
    if residual > .4:
        raise ValueError('边缘弯曲或噪声过大，无法可靠测量 SFR')
    distance = (xgrid[None, :]-(slope*y+intercept)[:, None])/np.sqrt(1+slope*slope)
    radius = min(8., np.min([intercept, image.shape[1]-1-intercept,
                            intercept+slope*(len(y)-1), image.shape[1]-1-intercept-slope*(len(y)-1)])-1)
    if radius < 4:
        raise ValueError('边缘两侧采样宽度不足')
    step = .25
    bins = int(2*radius/step)
    indices = np.floor((distance+radius)/step).astype(int)
    valid = (indices >= 0) & (indices < bins)
    counts = np.bincount(indices[valid], minlength=bins)
    sums = np.bincount(indices[valid], weights=image[valid], minlength=bins)
    populated = counts > 0
    if populated.mean() < .98:
        raise ValueError('亚像素采样覆盖不足')
    esf = np.interp(np.arange(bins), np.flatnonzero(populated), sums[populated]/counts[populated])
    left, right = np.median(esf[:8]), np.median(esf[-8:])
    contrast = abs(right-left)
    if contrast < .15:
        raise ValueError('边缘对比度不足')
    esf = (esf-left)/(right-left)
    lsf = np.gradient(esf, step)
    lsf *= np.hamming(len(lsf))
    spectrum = np.abs(np.fft.rfft(lsf, 2048))
    if spectrum[0] < 1e-9:
        raise ValueError('边缘响应无效')
    frequency = np.fft.rfftfreq(2048, step)
    mtf = spectrum/spectrum[0]
    # Compensate the central-difference derivative's frequency response.
    mtf /= np.maximum(np.sinc(2*frequency*step), .1)
    keep = frequency <= .5
    frequency, mtf = frequency[keep], mtf[keep]
    crossing = np.flatnonzero(mtf <= .5)
    mtf50 = None
    if len(crossing) and crossing[0] > 0:
        i = crossing[0]
        mtf50 = float(np.interp(.5, [mtf[i], mtf[i-1]], [frequency[i], frequency[i-1]]))
    selected = np.linspace(0, len(frequency)-1, 65).astype(int)
    return dict(mtf50_cy_px=mtf50, angle_deg=angle, contrast=float(contrast),
                edge_fit_rms_px=float(residual), overshoot=float(max(0., esf.max()-1)),
                undershoot=float(max(0., -esf.min())), frequency_cy_px=frequency[selected].tolist(),
                sfr=mtf[selected].tolist(), response=response)


def board_sfr(gray, corners, pattern, response='unknown'):
    segments = board_segments(corners, pattern)
    # Cover rows and columns, retaining spatially distributed samples.
    selected = np.linspace(0, len(segments)-1, min(24, len(segments))).astype(int)
    edges = []
    h, w = gray.shape
    for index in selected:
        name, start, end = segments[index]
        vector = end-start
        length = np.linalg.norm(vector)
        center = (start+end)/2
        vertical = abs(vector[1]) >= abs(vector[0])
        along = max(1, int(length*.55/2))
        across = max(8, min(20, int(length*.22)))
        hx, hy = (across, along) if vertical else (along, across)
        x, y = np.round(center).astype(int)
        bounds = [int(x-hx), int(y-hy), int(x+hx+1), int(y+hy+1)]
        result = dict(line=name, roi=bounds)
        try:
            if bounds[0] < 0 or bounds[1] < 0 or bounds[2] > w or bounds[3] > h:
                raise ValueError('ROI 超出图像')
            roi = gray[bounds[1]:bounds[3], bounds[0]:bounds[2]]
            result.update(slanted_edge_sfr(roi if vertical else roi.T, response))
            result['valid'] = result['mtf50_cy_px'] is not None
            if not result['valid']:
                result['reason'] = 'MTF50 在奈奎斯特频率内没有交点'
        except ValueError as exc:
            result.update(valid=False, reason=str(exc))
        edges.append(result)
    values = [edge['mtf50_cy_px'] for edge in edges if edge['valid']]
    return dict(mtf50_median_cy_px=float(np.median(values)) if values else None,
                valid_edges=len(values), attempted_edges=len(edges), edges=edges,
                method='relative_slanted_edge_sfr_v1', certified_iso12233=False,
                response=response)

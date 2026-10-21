"""Check the actual test/EmbFPGA.pds, not the separate Git checkout."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
top = (ROOT/'src/top/hdmi_ddr3_top.v').read_text(encoding='ascii')
assert not re.search(r'\bscale_(?:in|out)_\d+_to_\d+\s', top)
assert len(re.findall(r'\.H_NUM\s*\(1920\)', top)) == 3
assert re.search(r'assign alg_rd_en\s*=\s*timing_de;', top)
assert '~pixclk_in' not in top and 'negedge pixclk_in' not in top
assert '.de_in     (display_de)' in top
assert 'FRAME_PIPE_DELAY = (UNDISTORT_ENABLE && !POSE_CORRECTION_ENABLE) ? 23 : 2;' in top
assert "parameter POSE_CORRECTION_ENABLE = 1'b1" in top
assert "parameter POSE_TILED_ENABLE = 1'b1" in top
assert "parameter ADAPTIVE_PREPROCESS_ENABLE = 1'b1" in top
assert "parameter [1:0] ADAPTIVE_PREPROCESS_MODE = 2'd3" in top
assert '.GAMMA_ENABLE(GAMMA_ENABLE && !AUTO_GAMMA)' in top
for file in ('rgb565_to_rgb888.v', 'gamma_correct_rgb888.v'):
    baseline = (ROOT/'reference/sept19_6be49a4'/file).read_bytes()
    current_dir = 'format' if file == 'rgb565_to_rgb888.v' else 'preprocess'
    current = (ROOT/'src/video'/current_dir/file).read_bytes()
    assert current.replace(b'\r\n',b'\n') == baseline.replace(b'\r\n',b'\n'), file
project = (ROOT/'EmbFPGA.pds').read_text(encoding='utf-8')
files = ([n.attrib['file'] for n in ET.fromstring(project).iter('item')
          if n.attrib.get('type')=='FILE'] if project.lstrip().startswith('<')
         else re.findall(r'\(_file "([^"]+)"', project))
rtl = [p for p in files if p.endswith(('.v','.vp','.vh'))]
assert not any('scale_in_1920_to_1440' in p or 'scale_out_1440_to_1920' in p for p in rtl)
for file in ('src/video/format/rgb888_to_rgb565.v','src/video/format/rgb565_to_rgb888.v',
             'src/video/timing/video_raster_delay.v','src/video/frame_buffer/fram_buf_linear.v',
             'src/video/undistort/undistort_band_cache.v','src/video/undistort/undistort_band_tables.v'):
    assert file in rtl, file
for name in rtl + ['src/constraints/hdmi_ddr3_top.fdc']:
    path=(ROOT/name).resolve()
    assert path.is_relative_to(ROOT.resolve()) and path.is_file(), name
ip_items = {n.attrib.get('file') for n in ET.fromstring(project).iter('item')
            if n.attrib.get('type') == 'IP'}
for name in ('ipcore/video_pll/pll.idf', 'ipcore/wr_fram_buf/wr_fram_buf.idf',
             'ipcore/rd_fram_buf/rd_fram_buf.idf', 'ipcore/DDR3_50H/DDR3_50H.idf'):
    assert name in ip_items, name
    assert (ROOT/name).is_file(), name
assert not any(n.attrib.get('type') == 'FILE' and
               (n.attrib.get('file', '').startswith('src/ip/') or
                n.attrib.get('file', '').startswith('DDR3_50H/'))
               for n in ET.fromstring(project).iter('item'))
assert 'EmbFPGA_repo' not in project
cache=(ROOT/'src/video/undistort/undistort_band_cache.v').read_text(encoding='ascii')
assert 'localparam CACHE_DEPTH=2475;' in cache
for file in ('imu_uart_rx_50m.v','imu_protocol_50m.v','attitude_cdc.v','imu_affine_q14.v'):
    assert 'src/imu/'+file in rtl, file
for file in ('pose_frame_bank_allocator.v','adaptive_preprocess_stream.v','pose_tile_read_scheduler.v',
             'adaptive_gamma_stream.v','adaptive_gamma_lut.v','pose_renderer_tiled.v',
             'pose_inverse_project_q14.v','pose_renderer_dma.v','pose_ddr_arbiter.v',
             'pose_async_fifo.v','fram_buf_pose.v'):
    subdir = 'preprocess' if file.startswith('adaptive_') else 'pose'
    assert f'src/video/{subdir}/{file}' in rtl, file
assert 'adaptive_preprocess_stream u_adaptive_preprocess' in top
assert 'cache_even_main [0:2047]' in cache and 'cache_odd_main [0:2047]' in cache
assert 'cache_even_tail [0:CACHE_DEPTH-2048-1]' in cache and 'cache_odd_tail [0:CACHE_DEPTH-2048-1]' in cache
assert 'cache_even_hi' not in cache and 'cache_odd_hi' not in cache
assert top.index('adaptive_preprocess_stream u_adaptive_preprocess') < top.index('rgb888_to_rgb565 u_rgb888_to_rgb565')
print('PASS test/EmbFPGA.pds: active full-frame pose path, source preprocessing, local sources, 1920/no scalers/rising edge/independent DE')

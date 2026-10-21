"""Isolated tiled renderer experiment; never mutates production RTL.

For a256-wide candidate only, extends the four horizontal counters/width from
8 to9 bits in a copied renderer. Single worst-traffic pose(-179,0) minimizes
experiment runtime. This checks standalone DDR only, not shared arbitration.
"""
from pathlib import Path
import argparse,hashlib,json,re,subprocess

ROOT=Path(__file__).resolve().parents[3]
MODEL=Path(r'D:\pango\modeltech64_10.6e\win64')
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--width',type=int,default=256)
p.add_argument('--height',type=int,default=32)
p.add_argument('--latency',type=int,default=32)
a=p.parse_args()
out=ROOT/'verification/pose_tiled_20261010/source_bounds'/f'candidate_{a.width}x{a.height}'
out.mkdir(parents=True,exist_ok=True)
renderer=ROOT/'src/video/pose_renderer_tiled.v'
bench=ROOT/'tests/tb_pose_renderer_tiled.sv'
text=renderer.read_text(encoding='ascii')
if a.width==256:
    text=text.replace('reg [7:0] width[0:1],height[0:1],sxword[0:1],srcwords[0:1];',
        'reg [8:0] width[0:1]; reg [7:0] height[0:1],sxword[0:1],srcwords[0:1];')
    text=text.replace('reg [7:0] launch_x,launch_y,result_x,result_y;',
        'reg [8:0] launch_x,result_x; reg [7:0] launch_y,result_y;')
    text=text.replace('reg [7:0] sample_x,sample_y;',
        'reg [8:0] sample_x; reg [7:0] sample_y;')
(out/'pose_renderer_tiled.v').write_text(text,encoding='ascii')
text=bench.read_text(encoding='ascii')
text=text.replace('render(0,0,0);render(536,536,1);render(536,-536,0);render(-536,536,1);render(-536,-536,0);',
    'render(-179,0,0);')
(out/'tb_pose_renderer_tiled.sv').write_text(text,encoding='ascii')
files=[out/'pose_renderer_tiled.v',out/'tb_pose_renderer_tiled.sv',ROOT/'src/video/pose_inverse_project_q14.v',ROOT/'src/video/pose_reciprocal_lut.v']
(out/'input_sha256.json').write_text(json.dumps({str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2)+'\n')
def run(args,timeout=120):
    r=subprocess.run(list(map(str,args)),cwd=ROOT,text=True,capture_output=True,timeout=timeout)
    if r.returncode or re.search(r'\*\* (?:Fatal|Error):',r.stdout+r.stderr):raise RuntimeError(r.stdout+r.stderr)
    return r.stdout+r.stderr
lib=out/'work'
if not lib.exists():run([MODEL/'vlib.exe',lib])
run([MODEL/'vlog.exe','-sv','-work',lib,*files])
result=run([MODEL/'vsim.exe','-c','-quiet','-vopt','-lib',lib.relative_to(ROOT).as_posix(),'tb_pose_renderer_tiled',
    '-gH=1920','-gV=1080','-gWIDTH=1920','-gHEIGHT=1080','-gFULL=1',f'-gTILE_W={a.width}',f'-gTILE_H={a.height}',
    f'-gREAD_LATENCY={a.latency}',f'-gWRITE_LATENCY={a.latency}','-l',out/'result.log','-do','onerror {quit -code 1}; run -all; quit -f'],timeout=3600)
assert 'PASS tiled' in result,result
print('\n'.join(x for x in result.splitlines() if 'PASS' in x or 'MEASURE' in x))

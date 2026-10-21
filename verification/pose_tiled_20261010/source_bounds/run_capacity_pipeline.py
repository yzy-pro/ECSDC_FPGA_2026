"""Test actual projection geometry at capacity equality/overflow and black tile."""
from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[3]
MODEL=Path(r'D:\pango\modeltech64_10.6e\win64')
OUT=Path(__file__).parent/'capacity_pipeline'
OUT.mkdir(parents=True,exist_ok=True)
files=[Path(__file__).parent/'tb_tiled_capacity_pipeline.sv']+[ROOT/'src/video'/s for s in ('pose_renderer_tiled.v','pose_inverse_project_q14.v','pose_reciprocal_lut.v')]
def run(args,timeout=120):
    r=subprocess.run(list(map(str,args)),cwd=ROOT,text=True,capture_output=True,timeout=timeout)
    if r.returncode or re.search(r'\*\* (?:Fatal|Error):',r.stdout+r.stderr):raise RuntimeError(r.stdout+r.stderr)
    return r.stdout+r.stderr
lib=OUT/'work'
if not lib.exists():run([MODEL/'vlib.exe',lib])
run([MODEL/'vlog.exe','-sv','-work',lib,*files])
output=run([MODEL/'vsim.exe','-c','-quiet','-vopt','-lib',lib.relative_to(ROOT).as_posix(),'tb_tiled_capacity_pipeline',
    '-l',OUT/'result.log','-do','onerror {quit -code 1}; run -all; quit -f'])
assert 'PASS pipelined tile capacity boundary regression' in output,output
(OUT/'input_sha256.json').write_text(json.dumps({str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2)+'\n')
print('\n'.join(x for x in output.splitlines() if 'PASS' in x))

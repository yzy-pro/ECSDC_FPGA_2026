"""Compile and verify automatic gamma at 148.5 MHz, one RGB pixel per clock."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
from generate_adaptive_gamma_lut import generate

ROOT=Path(__file__).resolve().parents[1]
MODEL=Path(r'D:\pango\modeltech64_10.6e\win64')
OUT=ROOT/'verification/pose_tiled_20261010/adaptive_gamma'
OUT.mkdir(parents=True,exist_ok=True)
sources=[ROOT/'src/video/adaptive_gamma_stream.v',ROOT/'src/video/adaptive_gamma_lut.v',
    ROOT/'tests/tb_adaptive_gamma_stream.sv',ROOT/'tests/tb_adaptive_gamma_1080p.sv']
assert sources[1].read_text(encoding='ascii')==generate(),'generated gamma ROM stale'

def run(command):
    result=subprocess.run(list(map(str,command)),cwd=ROOT,text=True,capture_output=True,timeout=180)
    output=result.stdout+result.stderr
    if result.returncode or re.search(r'\*\* (?:Fatal|Error):',output):raise RuntimeError(output)
    return output

lib=OUT/'work'
if not lib.exists():run([MODEL/'vlib.exe',lib])
run([MODEL/'vlog.exe','-sv','-work',lib,*sources])
output=''
for bench,log in [('tb_adaptive_gamma_stream','result.log'),('tb_adaptive_gamma_1080p','1080p.log')]:
    result=run([MODEL/'vsim.exe','-c','-quiet','-vopt','-lib',lib.relative_to(ROOT).as_posix(),
        bench,'-l',OUT/log,'-do','onerror {quit -code 1}; run -all; quit -f'])
    assert 'PASS adaptive gamma' in result,result
    output+=result
(OUT/'input_sha256.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},indent=2)+'\n',encoding='ascii')
print('\n'.join(line for line in output.splitlines() if 'PASS' in line or 'SCENE' in line))

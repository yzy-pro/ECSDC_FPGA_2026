"""Check tiled exact renderer; full mode enforces the 1080p30 clock budget."""
import argparse
from pathlib import Path
import subprocess
import re
ROOT = Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--full', action='store_true')
    p.add_argument('--modelsim', type=Path, default=Path(r'D:\pango\modeltech64_10.6e\win64'))
    p.add_argument('--read-latency',type=int,default=24)
    p.add_argument('--write-latency',type=int,default=24)
    p.add_argument('--tile-width',type=int,default=128)
    p.add_argument('--tile-height',type=int,default=64)
    args=p.parse_args()
    directory=ROOT/'build_rebuilt'/f'pose_tiled_{"full" if args.full else "small"}_{args.tile_width}x{args.tile_height}'
    directory.mkdir(parents=True,exist_ok=True)
    lib=directory/'work'
    def run(cmd,timeout=120):
        r=subprocess.run(list(map(str,cmd)),cwd=ROOT,text=True,capture_output=True,timeout=timeout)
        if r.returncode or re.search(r'\*\* (?:Fatal|Error):',r.stdout+r.stderr):
            raise RuntimeError(r.stdout+r.stderr)
        return r.stdout+r.stderr
    if not lib.exists():run([args.modelsim/'vlib.exe',lib])
    run([args.modelsim/'vlog.exe','-sv','-work',lib,ROOT/'tests/tb_pose_renderer_tiled.sv',
         ROOT/'src/video/pose/pose_renderer_tiled.v',ROOT/'src/video/pose/pose_inverse_project_q14.v',
         ROOT/'src/video/pose/pose_reciprocal_lut.v'])
    overrides=['-gH=1920','-gV=1080','-gWIDTH=1920','-gHEIGHT=1080','-gFULL=1'] if args.full else []
    overrides.extend([f'-gTILE_W={args.tile_width}',f'-gTILE_H={args.tile_height}'])
    output=run([args.modelsim/'vsim.exe','-c','-quiet','-vopt','-lib',lib.relative_to(ROOT).as_posix(),
                'tb_pose_renderer_tiled',*overrides,f'-gREAD_LATENCY={args.read_latency}',
                f'-gWRITE_LATENCY={args.write_latency}','-l',directory/'result.log','-do',
                'onerror {quit -code 1}; run -all; quit -f'],timeout=14400 if args.full else 300)
    if 'PASS tiled' not in output:raise RuntimeError(output)
    print('\n'.join(x for x in output.splitlines() if 'PASS' in x or 'MEASURE' in x))
if __name__=='__main__':main()

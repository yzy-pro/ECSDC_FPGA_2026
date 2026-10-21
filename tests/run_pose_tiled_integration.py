"""Measure actual frame publications under 60Hz capture/display DDR contention."""
import argparse
from pathlib import Path
import subprocess
import re
import hashlib
import json
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--full',action='store_true')
    p.add_argument('--frames',type=int,help='input frames (default: 28 full, 12 small)')
    p.add_argument('--latency',type=int,default=32)
    p.add_argument('--shared-payload',action='store_true',help='allow only one read or write payload beat per clock')
    p.add_argument('--preprocess',action='store_true',help='include adaptive gamma and registered RGB888-to-RGB565 converter')
    p.add_argument('--refresh-cycles',type=int,default=0,help='periodic clocks with commands/payload suspended (35 is conservative for configured 300ns tRFC)')
    p.add_argument('--refresh-interval',type=int,default=780,help='refresh period in 100MHz clocks (configured tREFI=7.8us)')
    p.add_argument('--modelsim',type=Path,default=Path(r'D:\pango\modeltech64_10.6e\win64'))
    p.add_argument('--output',type=Path,help='simulation artifact directory')
    args=p.parse_args()
    frames=args.frames if args.frames is not None else (28 if args.full else 12)
    if frames<1:p.error('--frames must be positive')
    if args.latency<0:p.error('--latency must be nonnegative')
    if args.refresh_interval<1 or not 0<=args.refresh_cycles<args.refresh_interval:
        p.error('refresh cycles must be nonnegative and smaller than the positive refresh interval')
    directory=args.output or ROOT/'build_rebuilt'/('pose_tiled_integration_full' if args.full else 'pose_tiled_integration_small')
    directory=directory.resolve()
    directory.mkdir(parents=True,exist_ok=True);lib=directory/'work'
    def run(cmd,timeout=120):
        r=subprocess.run(list(map(str,cmd)),cwd=ROOT,text=True,capture_output=True,timeout=timeout)
        if r.returncode or re.search(r'\*\* (?:Fatal|Error):',r.stdout+r.stderr):raise RuntimeError(r.stdout+r.stderr)
        return r.stdout+r.stderr
    if not lib.exists():run([args.modelsim/'vlib.exe',lib])
    sources=[ROOT/'src/video'/s for s in ('fram_buf_pose.v','pose_renderer_tiled.v','pose_renderer_dma.v',
             'pose_inverse_project_q14.v','pose_reciprocal_lut.v','pose_ddr_arbiter.v','pose_async_fifo.v',
             'adaptive_gamma_stream.v','adaptive_gamma_lut.v','rgb888_to_rgb565.v')]
    manifest={
        'parameters':{'full':args.full,'frames':frames,'latency':args.latency,
                      'shared_payload':args.shared_payload,'refresh_cycles':args.refresh_cycles,
                      'refresh_interval':args.refresh_interval,'preprocess':args.preprocess},
        'sha256':{path.relative_to(ROOT).as_posix():hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in [Path(__file__),ROOT/'tests/tb_fram_buf_pose_tiled.sv',*sources]}}
    (directory/'source_identity.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    run([args.modelsim/'vlog.exe','-sv','-work',lib,ROOT/'tests/tb_fram_buf_pose_tiled.sv',*sources])
    overrides=['-gH=1920','-gV=1080','-gFULL=1'] if args.full else []
    overrides.extend([f'-gSHARED_PAYLOAD={int(args.shared_payload)}',f'-gREFRESH_CYCLES={args.refresh_cycles}',
                      f'-gREFRESH_INTERVAL={args.refresh_interval}',f'-gPREPROCESS={int(args.preprocess)}'])
    out=run([args.modelsim/'vsim.exe','-c','-quiet','-vopt','-lib',lib.relative_to(ROOT).as_posix(),
             'tb_fram_buf_pose_tiled',*overrides,f'-gFRAMES={frames}',f'-gDDR_LATENCY={args.latency}',
             '-l',directory/'result.log','-do','onerror {quit -code 1}; run -all; quit -f'],timeout=14400)
    if 'PASS concurrent' not in out:raise RuntimeError(out)
    print('\n'.join(x for x in out.splitlines() if any(s in x for s in ('PASS','RENDER','PUBLISH','MODEL'))))
if __name__=='__main__':main()

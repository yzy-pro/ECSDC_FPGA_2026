"""Isolated three-render throughput experiment at the worst sampled pose.

Starts from the production concurrent test, forces every captured pose(-179,0),
and finishes after3complete renders. The normal30fps/ownership/pixel assertions
are retained. This is a quick comparison, not a full qualification run.
"""
from pathlib import Path
import argparse,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[3]
MODEL=Path(r'D:\pango\modeltech64_10.6e\win64')
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--width',type=int,default=256)
p.add_argument('--height',type=int,default=32)
p.add_argument('--yaw',type=int,default=-179)
p.add_argument('--pitch',type=int,default=0)
p.add_argument('--tag',default='',help='distinct artifact suffix; preserve earlier source-version evidence')
a=p.parse_args()
suffix='' if (a.yaw,a.pitch)==(-179,0) else f'_yaw{a.yaw}_pitch{a.pitch}'
if a.tag:suffix+='_'+a.tag
out=ROOT/'verification/pose_tiled_20261010/source_bounds'/f'contended_{a.width}x{a.height}{suffix}'
out.mkdir(parents=True,exist_ok=True)
text=(ROOT/'src/video/pose_renderer_tiled.v').read_text(encoding='ascii')
text=re.sub(r'parameter TILE_W=\d+, TILE_H=\d+',f'parameter TILE_W={a.width}, TILE_H={a.height}',text)
if a.width==256:
    text=text.replace('reg [7:0] width[0:1],height[0:1],sxword[0:1],srcwords[0:1];','reg [8:0] width[0:1]; reg [7:0] height[0:1],sxword[0:1],srcwords[0:1];')
    text=text.replace('reg [7:0] launch_x,launch_y,result_x,result_y;','reg [8:0] launch_x,result_x; reg [7:0] launch_y,result_y;')
    text=text.replace('reg [7:0] sample_x,sample_y;','reg [8:0] sample_x; reg [7:0] sample_y;')
(out/'pose_renderer_tiled.v').write_text(text,encoding='ascii')
text=(ROOT/'tests/tb_fram_buf_pose_tiled.sv').read_text(encoding='ascii')
text=text.replace('POSE_COUNT=11','POSE_COUNT=1')
text=re.sub(r'(function automatic signed \[15:0\] pose_yaw\(input integer pose_index\);).*?endfunction',lambda m:m[1]+f' pose_yaw={a.yaw}; endfunction',text,flags=re.S)
text=re.sub(r'(function automatic signed \[15:0\] pose_pitch\(input integer pose_index\);).*?endfunction',lambda m:m[1]+f' pose_pitch={a.pitch}; endfunction',text,flags=re.S)
text=text.replace('prev_rendered=rendered_frames;',
    'prev_rendered=rendered_frames; if(rendered_frames==3)begin $display("PASS three-render candidate: max_render_clocks=%0d max_publication_clocks=%0d checked_display_pixels=%0d",max_render_cycles,max_publication_clocks,display_checked);$finish;end')
(out/'tb_fram_buf_pose_tiled.sv').write_text(text,encoding='ascii')
files=[out/'pose_renderer_tiled.v',out/'tb_fram_buf_pose_tiled.sv']+[ROOT/'src/video'/s for s in (
    'fram_buf_pose.v','pose_renderer_dma.v','pose_inverse_project_q14.v','pose_reciprocal_lut.v','pose_ddr_arbiter.v',
    'pose_async_fifo.v','adaptive_gamma_stream.v','adaptive_gamma_lut.v','rgb888_to_rgb565.v')]
(out/'input_sha256.json').write_text(json.dumps({str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2)+'\n')
(out/'experiment.json').write_text(json.dumps({'tile_width':a.width,'tile_height':a.height,'yaw_q2048':a.yaw,
    'pitch_q2048':a.pitch,'latency':32,'shared_payload':True,'refresh_cycles':35,'refresh_interval':780,
    'preprocess':False,'stop_after_completed_renders':3,'origin_sha256':{
        str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in
        [ROOT/'src/video/pose_renderer_tiled.v',ROOT/'tests/tb_fram_buf_pose_tiled.sv',Path(__file__)]}},indent=2)+'\n')
def run(args,timeout=120):
    r=subprocess.run(list(map(str,args)),cwd=ROOT,text=True,capture_output=True,timeout=timeout)
    if r.returncode or re.search(r'\*\* (?:Fatal|Error):',r.stdout+r.stderr):raise RuntimeError(r.stdout+r.stderr)
    return r.stdout+r.stderr
lib=out/'work'
if not lib.exists():run([MODEL/'vlib.exe',lib])
run([MODEL/'vlog.exe','-sv','-work',lib,*files])
result=run([MODEL/'vsim.exe','-c','-quiet','-vopt','-lib',lib.relative_to(ROOT).as_posix(),'tb_fram_buf_pose_tiled',
    '-gH=1920','-gV=1080','-gFULL=1','-gFRAMES=10','-gSHARED_PAYLOAD=1','-gREFRESH_CYCLES=35','-gREFRESH_INTERVAL=780',
    '-gPREPROCESS=0','-gDDR_LATENCY=32','-l',out/'result.log','-do','onerror {quit -code 1}; run -all; quit -f'],timeout=7200)
assert 'PASS three-render' in result,result
print('\n'.join(x for x in result.splitlines() if any(s in x for s in ('PASS','RENDER','PUBLISH','MODEL'))))

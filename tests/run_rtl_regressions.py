"""Run actual RTL with Icarus or ModelSim; fail if tools are missing.

Generated stimuli, expected values, fault injections and vvp files live in the
ignored build_rebuilt directory. Coordinate-only fixtures retag the cache calibration:
they test the arithmetic, not the row memory schedule (checked separately).
"""
import argparse
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import uuid
from contextlib import nullcontext

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from generate_undistort_cache import mapping, literal, XN_START, YN_START, XN_STEP, YN_STEP


def run(args, cwd, timeout=90):
    return subprocess.run(list(map(str,args)), cwd=cwd, text=True, capture_output=True, timeout=timeout)


def coordinate_bench(p1, p2, baseline=False):
    rng=random.Random(1920)
    vectors=[]
    # Consecutive full rows, line blanking, abrupt input jumps, bubbles, and
    # resets with occupied arithmetic/valid pipelines.
    for row in (0, 1, 563, 564, 1079):
        vectors.extend((1, (XN_START+x*XN_STEP)>>8, (YN_START+row*YN_STEP)>>8, 1) for x in range(1920))
        vectors.extend((0, 0, 0, 1) for _ in range(30))
    vectors.extend((rng.randrange(2),rng.randint(-20663,21346),rng.randint(-11420,12214),int(i%151>2)) for i in range(1200))
    vectors.extend((0,0,0,1) for _ in range(30))
    commands=[]
    # Independent expected Q14 projection is computed per input sample;
    # the testbench checks the real DUT registers and delayed DE, not a copy
    # of the DUT's pipeline assignments.
    for enable,x,y,ready in vectors:
        if baseline:
            r2=(x*x+y*y)>>14; r4=r2*r2>>14
            scale=16384+((-4687*r2)>>14)+((1455*r4)>>14)
            u=((x*scale)>>14)*826+12552715
            v=((y*scale)>>14)*827+9197458
        else:
            u,v=mapping(x,y,p1,p2)
        commands.append(f'        sample({enable},{x},{y},{u},{v},{ready});')
    return '''`timescale 1ns/1ps
module tb_coordinates;
    localparam LATENCY=DELAYVALUE, COORD_DELAY=COORDVALUE;
    reg clk=0;
    always #5 clk=~clk;
    reg rstn=0, en=0;
    reg ready=0;
    integer drive_x=0, drive_y=0;
    integer u_expect[0:COORD_DELAY], v_expect[0:COORD_DELAY];
    reg [LATENCY-1:0] enables=0;
    integer j, checked=0;
    undistort_rd_buf #(.P1_Q14(PONE),.P2_Q14(PTWO)) dut (
        .ddr_clk(clk),.ddr_rstn(rstn),.vout_clk(clk),.rd_fsync(1'b0),
        .rd_active(en),.rd_en(en),.init_done(1'b0),
        .completed_frame_bank(2'd0),.ddr_rrdy(1'b0),.ddr_rdone(1'b0),
        .ddr_rdata(256'd0),.ddr_rdata_en(1'b0)
    );
    task sample(input bit valid, input integer x,y,u,v, input bit running);
        begin
            @(negedge clk);
            en=valid; drive_x=x*256; drive_y=y*256; ready=running;
            @(posedge clk); #1;
            if (!running) enables=0;
            else begin
                enables={enables[LATENCY-2:0],valid};
                for(j=COORD_DELAY;j>0;j=j-1) begin u_expect[j]=u_expect[j-1]; v_expect[j]=v_expect[j-1]; end
                u_expect[0]=u; v_expect[0]=v;
                // The new focal projection adds one coordinate stage;
                // baseline and current delays are checked independently.
            end
            if(dut.vout_de !== enables[LATENCY-1]) $fatal(1,"DE latency/reset mismatch");
        end
    endtask
    integer previous_u=0,previous_v=0;
    reg previous_valid=0;
    always @(negedge clk) begin
        previous_u=u_expect[COORD_DELAY]; previous_v=v_expect[COORD_DELAY]; previous_valid=enables[COORD_DELAY];
    end
    always @(posedge clk) begin
        #2;
        if(ready && previous_valid) begin
            if($signed(dut.xsrc2) !== previous_u || $signed(dut.ysrc2) !== previous_v)
                $fatal(1,"coordinate skew: got %0d,%0d expected %0d,%0d",$signed(dut.xsrc2),$signed(dut.ysrc2),previous_u,previous_v);
            checked=checked+1;
        end
    end
    initial begin
        force dut.vout_pipeline_ready=ready;
        force dut.xn_acc_q22=drive_x;
        force dut.yn_acc_q22=drive_y;
        repeat(3) @(negedge clk);
        rstn=1;
COMMANDS
        #4;
        $display("PASS coordinates: %0d samples, signed Q14, bubbles, reset, DE latency",checked);
        $finish;
    end
endmodule
'''.replace('PONE',str(p1)).replace('PTWO',str(p2)).replace('COMMANDS','\n'.join(commands)).replace('DELAYVALUE',str(18 if baseline else 23)).replace('COORDVALUE',str(6 if baseline else 7))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iverilog', default=shutil.which('iverilog'))
    parser.add_argument('--vvp', default=shutil.which('vvp'))
    parser.add_argument('--modelsim',type=Path,help='ModelSim win64 directory; alternative to Icarus')
    parser.add_argument('--dynamic-imu',action='store_true',help='apply per-frame IMU changes in full raster test')
    parser.add_argument('--full-raster', action='store_true', help='also simulate three complete 1080p frames (can take 15 minutes)')
    parser.add_argument('--frames',type=int,default=3)
    parser.add_argument('--bilinear',action='store_true')
    args=parser.parse_args()
    if not args.modelsim and (not args.iverilog or not args.vvp):
        parser.error('Icarus iverilog and vvp are required; supply paths or add them to PATH')
    contract=run([sys.executable,ROOT/'tests/verify_main_contract.py'],ROOT)
    if contract.returncode:
        raise RuntimeError(contract.stdout+contract.stderr)
    print(contract.stdout.strip())
    # Keep artifacts in the ignored build tree; Windows restricted accounts
    # cannot always reopen tempfile's owner-only directories.
    directory = ROOT/'build_rebuilt'/('rtl_'+uuid.uuid4().hex)
    directory.mkdir(parents=True)
    with nullcontext(directory) as directory:
        tmp=Path(directory)
        def simulate(label, tb, sources, must_fail=False, timeout=90):
            tbfile=tmp/(label+'.sv'); tbfile.write_text(tb,encoding='ascii')
            exe=tmp/(label+'.vvp')
            top=re.search(r'module\s+(\w+)',tb)[1]
            if args.modelsim:
                lib=tmp/(label+'_work')
                made=run([args.modelsim/'vlib.exe',lib],tmp)
                if made.returncode: raise RuntimeError(made.stdout+made.stderr)
                compile_result=run([args.modelsim/'vlog.exe','-sv','-work',lib,tbfile,*sources,ROOT/'src/imu/imu_affine_q14.v'],tmp)
                if compile_result.returncode: raise RuntimeError(compile_result.stdout+compile_result.stderr)
                logfile=tmp/(label+'.log')
                print(f'Running {label}; progress log: {logfile}',flush=True)
                with logfile.open('w',encoding='utf-8') as log:
                    completed=subprocess.run([str(args.modelsim/'vsim.exe'),'-c','-quiet','-lib',str(lib),top,
                        '-do','onerror {quit -code 1}; run -all; quit -f'],cwd=tmp,stdout=log,
                        stderr=subprocess.STDOUT,timeout=timeout)
                output=logfile.read_text(encoding='utf-8')
                failed=completed.returncode or re.search(r'\*\* (?:Fatal|Error):',output)
                if must_fail:
                    if not failed: raise AssertionError(f'{label}: injected bug was not detected: {output}')
                    print(f'PASS {label}: historical bug rejected')
                else:
                    if failed or 'PASS' not in output: raise AssertionError(label+': '+output)
                    print(label+': '+ '\n'.join(x for x in output.splitlines() if 'PASS' in x))
                return
            compile_result=run([args.iverilog,'-g2012','-s',top,'-o',exe,tbfile,*sources,ROOT/'src/imu/imu_affine_q14.v'],tmp)
            if compile_result.returncode:
                raise RuntimeError(compile_result.stdout+compile_result.stderr)
            logfile=tmp/(label+'.log')
            print(f'Running {label}; progress log: {logfile}',flush=True)
            with logfile.open('w',encoding='utf-8') as log:
                completed=subprocess.run([str(args.vvp),str(exe)],cwd=tmp,stdout=log,
                                         stderr=subprocess.STDOUT,timeout=timeout)
            result=subprocess.CompletedProcess(completed.args,completed.returncode,
                                               logfile.read_text(encoding='utf-8'),'')
            if must_fail:
                if not result.returncode or 'FATAL' not in result.stdout:
                    raise AssertionError(f'{label}: injected bug was not detected: {result.stdout}')
                print(f'PASS {label}: historical bug rejected')
            else:
                if result.returncode or 'PASS' not in result.stdout:
                    raise AssertionError(label+': '+result.stdout+result.stderr)
                print(label+': '+result.stdout.strip())
        simulate('imu_affine',(ROOT/'tests/tb_imu_affine.sv').read_text(encoding='ascii'),[])
        simulate('imu_protocol',(ROOT/'tests/tb_imu_protocol.sv').read_text(encoding='ascii'),
                 [ROOT/'src/imu/imu_protocol_50m.v',ROOT/'src/imu/imu_uart_rx_50m.v'])
        simulate('attitude_cdc',(ROOT/'tests/tb_attitude_cdc.sv').read_text(encoding='ascii'),
                 [ROOT/'src/imu/attitude_cdc.v'])
        simulate('pose_frame_bank_allocator',
                 (ROOT/'tests/tb_pose_frame_bank_allocator.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/pose/pose_frame_bank_allocator.v'])
        simulate('adaptive_preprocess_stream',
                 (ROOT/'tests/tb_adaptive_preprocess_stream.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/preprocess/adaptive_preprocess_stream.v'])
        simulate('pose_tile_read_scheduler',
                 (ROOT/'tests/tb_pose_tile_read_scheduler.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/pose/pose_tile_read_scheduler.v'])
        projector_tb=(ROOT/'tests/tb_pose_inverse_project_q14.sv').read_text(encoding='ascii')
        simulate('pose_inverse_project_q14', projector_tb,
                 [ROOT/'src/video/pose/pose_inverse_project_q14.v',
                  ROOT/'src/video/pose/pose_reciprocal_lut.v'])
        simulate('pose_inverse_project_reciprocal_lut',
                 projector_tb.replace('parameter integer RECIPROCAL_LUT_ENABLE = 0',
                                      'parameter integer RECIPROCAL_LUT_ENABLE = 1'),
                 [ROOT/'src/video/pose/pose_inverse_project_q14.v',
                  ROOT/'src/video/pose/pose_reciprocal_lut.v'])
        simulate('pose_reciprocal_lut_error',
                 (ROOT/'tests/tb_pose_reciprocal_lut.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/pose/pose_reciprocal_lut.v'])
        simulate('pose_focal_product',(ROOT/'tests/tb_pose_focal_product.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/pose/pose_inverse_project_q14.v',
                  ROOT/'src/video/pose/pose_reciprocal_lut.v'])
        simulate('pose_async_fifo',(ROOT/'tests/tb_pose_async_fifo.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/pose/pose_async_fifo.v'])
        simulate('pose_ddr_arbiter',(ROOT/'tests/tb_pose_ddr_arbiter.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/pose/pose_ddr_arbiter.v'])
        pose_sources=[ROOT/'src/video/pose'/name for name in (
            'pose_inverse_project_q14.v','pose_reciprocal_lut.v','pose_renderer_dma.v','pose_renderer_tiled.v',
            'pose_async_fifo.v','pose_ddr_arbiter.v','fram_buf_pose.v')]
        pose_sources += [ROOT/'src/video/preprocess'/name for name in
                         ('adaptive_gamma_stream.v','adaptive_gamma_lut.v')]
        pose_sources.append(ROOT/'src/video/format/rgb888_to_rgb565.v')
        for mode in (1,0):
            bench=(ROOT/'tests/tb_pose_renderer_dma.sv').read_text(encoding='ascii')
            bench=bench.replace('parameter integer INTERPOLATION_MODE=1',
                                'parameter integer INTERPOLATION_MODE='+str(mode))
            simulate('pose_renderer_'+str(mode),bench,pose_sources)
        line_bench=(ROOT/'tests/tb_pose_renderer_dma.sv').read_text(encoding='ascii')
        line_bench=line_bench.replace('parameter integer CACHE_LINE_WORDS=1',
                                      'parameter integer CACHE_LINE_WORDS=4')
        simulate('pose_renderer_line4',line_bench,pose_sources)
        simulate('fram_buf_pose',(ROOT/'tests/tb_fram_buf_pose.sv').read_text(encoding='ascii'),pose_sources)
        simulate('pose_renderer_tiled',(ROOT/'tests/tb_pose_renderer_tiled.sv').read_text(encoding='ascii'),pose_sources)
        simulate('fram_buf_pose_tiled',(ROOT/'tests/tb_fram_buf_pose_tiled.sv').read_text(encoding='ascii'),pose_sources)
        simulate('pose_capture_throughput',
                 (ROOT/'tests/tb_pose_capture_throughput.sv').read_text(encoding='ascii'),pose_sources)
        simulate('input_frame_alignment',
                 (ROOT/'tests/tb_input_frame_alignment.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/format/rgb888_to_rgb565.v', ROOT/'src/video/frame_buffer/wr_buf.v'])
        simulate('rgb888_raster',
                 (ROOT/'tests/tb_rgb888_raster.sv').read_text(encoding='ascii'),
                 [ROOT/'src/video/format/rgb565_to_rgb888.v', ROOT/'src/video/timing/video_raster_delay.v'])
        trans=ROOT/'src/video/frame_buffer/wr_cmd_trans.v'
        tb=(ROOT/'tests/tb_read_completion.sv').read_text(encoding='ascii')
        simulate('read_completion',tb,[trans])
        old=tmp/'old_completion.v'
        old.write_text(trans.read_text(encoding='ascii').replace('if(read_en && rd_data_cnt ==', 'if(rd_data_cnt =='),encoding='ascii')
        simulate('reject_early_completion',tb,[old],True)
        cache_tb=(ROOT/'tests/tb_cache_return.sv').read_text(encoding='ascii')
        cache_sources=[ROOT/'src/video/undistort/undistort_band_cache.v',ROOT/'src/video/undistort/undistort_band_tables.v']
        simulate('cache_return',cache_tb,[trans,ROOT/'src/video/undistort/undistort_rd_buf.v',*cache_sources])
        simulate('band_ddr_adapter',(ROOT/'tests/tb_band_ddr_adapter.sv').read_text(encoding='ascii'),
                 [trans,ROOT/'src/video/frame_buffer/rd_ctrl.v',*cache_sources])
        rtl=(ROOT/'src/video/undistort/undistort_rd_buf.v').read_text(encoding='ascii')
        raster_tb=(ROOT/'tests/tb_direct1920_raster.sv').read_text(encoding='ascii')
        raster_sources=[ROOT/'src/video/timing/sync_vg.v',ROOT/'src/video/timing/video_raster_delay.v',trans,*cache_sources]
        broken=tmp/'aliased_cache.v'
        cache_rtl=cache_sources[0].read_text(encoding='ascii')
        broken.write_text(cache_rtl.replace('7:band_base=2040','7:band_base=0'),encoding='ascii')
        simulate('reject_cache_alias',cache_tb,[trans,ROOT/'src/video/undistort/undistort_rd_buf.v',broken,cache_sources[1]],True)
        if args.full_raster:
            raster_tb=raster_tb.replace('parameter FRAME_COUNT=3','parameter FRAME_COUNT='+str(args.frames))
            if args.bilinear:
                raster_tb=raster_tb.replace('parameter INTERPOLATION_MODE=1','parameter INTERPOLATION_MODE=0')
            if args.dynamic_imu:
                raster_tb=raster_tb.replace('parameter DYNAMIC_IMU=0','parameter DYNAMIC_IMU=1')
            simulate('direct1920_raster',raster_tb,[*raster_sources,ROOT/'src/video/undistort/undistort_rd_buf.v'],timeout=3600)
        # A parameter override without a matching cache schedule must fail
        # elaboration even when the project is built directly from the GUI.
        badtb=tmp/'bad_calibration.sv'
        badtb.write_text('module bad_calibration; undistort_rd_buf #(.P1_Q14(1234)) dut(); endmodule',encoding='ascii')
        if args.modelsim:
            lib=tmp/'bad_work'; run([args.modelsim/'vlib.exe',lib],tmp)
            compiled=run([args.modelsim/'vlog.exe','-sv','-work',lib,badtb,ROOT/'src/video/undistort/undistort_rd_buf.v',*cache_sources,ROOT/'src/imu/imu_affine_q14.v'],tmp)
            assert not compiled.returncode, compiled.stdout+compiled.stderr
            bad=run([args.modelsim/'vsim.exe','-c','-lib',lib,'bad_calibration','-do','onerror {quit -code 1}; run -all; quit -f'],tmp)
            assert 'REGENERATE_UNDISTORT_CACHE_FOR_P1_P2' in bad.stdout and '** Error:' in bad.stdout,bad.stdout
        else:
            bad=run([args.iverilog,'-g2012','-s','bad_calibration','-o',tmp/'bad.vvp',badtb,ROOT/'src/video/undistort/undistort_rd_buf.v',*cache_sources,ROOT/'src/imu/imu_affine_q14.v'],tmp)
            assert bad.returncode and 'REGENERATE_UNDISTORT_CACHE_FOR_P1_P2' in bad.stderr, bad.stderr
        print('PASS mismatched calibration rejected during RTL elaboration')
        baseline_file=ROOT/'reference/sept19_6be49a4/undistort_rd_buf.v'
        if not baseline_file.is_file():
            raise RuntimeError('September 19 reference fixture unavailable')
        baseline_tb=coordinate_bench(0,0,baseline=True).replace('#(.P1_Q14(0),.P2_Q14(0))','#(.H_NUM(1920))')
        simulate('sept19_coordinate_reference',baseline_tb,[baseline_file])
        for p1,p2 in [(0,0),(20,-13),(-13,20)]:
            fixture=rtl
            for name,p in [('CACHE_P1_Q14',p1),('CACHE_P2_Q14',p2)]:
                fixture=re.sub(name+r" = -?18'sd\d+",name+' = '+literal(p),fixture)
            source=tmp/'coordinate_fixture.v'; source.write_text(fixture,encoding='ascii')
            tb=coordinate_bench(p1,p2)
            simulate(f'coordinates_{p1}_{p2}',tb,[source,*cache_sources])
            if (p1,p2)==(20,-13):
                source.write_text(fixture.replace('xy_d3 <= xy_d2;', 'xy_d3 <= xy1 >>> FRAC_BITS;'),encoding='ascii')
                simulate('reject_xy_skew',tb,[source,*cache_sources],True)


if __name__=='__main__':
    main()

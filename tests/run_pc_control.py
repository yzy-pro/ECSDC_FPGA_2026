"""Verify CP2102 protocol, frame controls, gamma snapshots and geometry modes."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modelsim', type=Path, default=Path(r'D:\pango\modeltech64_10.6e\win64'))
    args = parser.parse_args()
    output = ROOT / 'build_rebuilt/pc_control'
    output.mkdir(parents=True, exist_ok=True)
    library = output / 'work'

    def run(command, timeout=300):
        result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True,
                                text=True, timeout=timeout)
        text = result.stdout + result.stderr
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):', text):
            raise RuntimeError(text)
        return text

    if not library.exists():
        run([args.modelsim / 'vlib.exe', library])
    sources = sorted((ROOT / 'src/control').glob('*.v'))
    sources += [ROOT / 'src/imu/imu_uart_rx_50m.v']
    sources += sorted((ROOT / 'src/video/pose').glob('*.v'))
    sources += sorted((ROOT / 'src/video/preprocess').glob('*.v'))
    sources += sorted((ROOT / 'src/video/format').glob('*.v'))
    benches = ['tb_pc_control', 'tb_gamma_telemetry', 'tb_pc_control_frame_alignment', 'tb_pose_ddr_arbiter', 'tb_pose_renderer_tiled',
               'tb_fram_buf_pose_tiled', 'tb_adaptive_gamma_stream', 'tb_adaptive_gamma_1080p']
    run([args.modelsim / 'vlog.exe', '-sv', '-work', library, *sources,
         *(ROOT / 'tests' / (name + '.sv') for name in benches)])
    cases = [(name, []) for name in ('tb_pc_control', 'tb_gamma_telemetry',
                                     'tb_adaptive_gamma_stream', 'tb_adaptive_gamma_1080p')]
    cases += [('tb_pc_control', ['-gCLK_HZ=50000000'])]
    cases += [('tb_gamma_telemetry', ['-gCOLOR=1'])]
    cases += [('tb_pc_control_frame_alignment', [f'-gGAMMA={gamma}']) for gamma in (0, 1)]
    cases += [('tb_pose_renderer_tiled', ['-gRUNTIME=1', f'-gCONTROL_MODE={mode}']) for mode in range(4)]
    cases += [('tb_pose_renderer_tiled', [])]
    # Exercise the fully pipelined row loader with both supported tile heights.
    cases += [('tb_pose_renderer_tiled', ['-gTILE_H=64'])]
    cases += [('tb_pose_ddr_arbiter', ['-gSTREAM=1'])]
    cases += [('tb_fram_buf_pose_tiled', ['-gPREPROCESS=1', '-gSHARED_PAYLOAD=1',
                                        '-gREFRESH_CYCLES=35', '-gREFRESH_INTERVAL=780'])]
    cases += [('tb_fram_buf_pose_tiled', ['-gPREPROCESS=1', '-gRUNTIME=1', '-gFRAMES=32',
                                        '-gSHARED_PAYLOAD=1', '-gREFRESH_CYCLES=35'])]
    for index, (bench, parameters) in enumerate(cases):
        text = run([args.modelsim / 'vsim.exe', '-c', '-quiet', '-vopt', '-lib',
                    library.relative_to(ROOT).as_posix(), bench, *parameters,
                    '-l', output / f'{index:02d}_{bench}.log', '-do',
                    'onerror {quit -code 1}; run -all; quit -f'])
        if 'PASS' not in text:
            raise AssertionError(text)
        print(bench, ' '.join(parameters), flush=True)
        print('\n'.join(line for line in text.splitlines() if 'PASS' in line), flush=True)


if __name__ == '__main__':
    main()

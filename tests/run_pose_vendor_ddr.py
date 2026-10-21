"""Test pose_ddr_arbiter against the generated vendor DDR controller/PHY model.

The application arbiter and unencrypted DDR RTL come from this workspace.
The matching encrypted ModelSim library and Micron memory model come from
the original DDR3_50H example (not shipped in this workspace). A source hash
manifest records the exact provenance; this is a functional simulation, not
a board throughput or timing guarantee.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vendor-root', type=Path, default=ROOT.parent /
                        'HDMI_IN_DDR3_HDMI_OUT/source/rtl/DDR3_50H')
    parser.add_argument('--modelsim', type=Path,
                        default=Path(r'D:\pango\modeltech64_10.6e\win64'))
    parser.add_argument('--primitive-library', type=Path,
                        default=Path(r'D:\pango\PDS_2025.2-ads\arch\vendor\pango\verilog\simulation'))
    parser.add_argument('--output', type=Path,
                        default=ROOT / 'verification/pose_large_angle_20261009/vendor_ddr')
    args = parser.parse_args()
    vendor = args.vendor_root.resolve()
    primitive = args.primitive_library.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    build = ROOT / 'build_rebuilt' / ('vendor_ddr_' + uuid.uuid4().hex)
    build.mkdir(parents=True)
    work = build / 'work'
    source_list = vendor / 'sim/modelsim/sim_file_list.f'
    if not source_list.is_file():
        parser.error(f'generated vendor file list is missing: {source_list}')
    sources = [primitive / 'GTP_GRS.v', ROOT / 'tests/tb_pose_vendor_ddr.sv',
               ROOT / 'src/video/pose/pose_ddr_arbiter.v']
    provenance = []
    for line in source_list.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('+') or line.startswith('C:/'):
            continue
        path = (source_list.parent / line).resolve()
        relative = path.relative_to(vendor)
        if relative.parts[0] == 'example_design' and path.name != 'ddr3.v':
            continue
        workspace_path = ROOT / 'ipcore' / 'DDR3_50H' / relative
        if relative.parts[0] != 'sim_lib' and workspace_path.is_file():
            path = workspace_path
        if not path.is_file():
            parser.error(f'required vendor source is missing: {path}')
        sources.append(path)
    # The DDR model includes this file relative to its original sim directory.
    included = vendor / 'example_design/bench/mem/ddr3_parameters.vh'
    for path in [*sources, included]:
        provenance.append({'path': str(path),
                           'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    (output / 'source_identity.json').write_text(json.dumps({
        'description': __doc__, 'sources': provenance,
        'primitive_library': str(primitive), 'vendor_root': str(vendor),
        'work_library': str(work),
    }, indent=2), encoding='utf-8')

    def invoke(command, log_name):
        log_path = output / log_name
        with log_path.open('w', encoding='utf-8') as log:
            result = subprocess.run(list(map(str, command)), cwd=build,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=600)
        text = log_path.read_text(encoding='utf-8', errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):', text):
            raise RuntimeError(f'{log_name} failed; see {log_path}\n{text[-5000:]}')
        return text

    invoke([args.modelsim / 'vlib.exe', work], 'vlib.log')
    invoke([args.modelsim / 'vlog.exe', '-sv', '-work', work, '-mfcu',
            '+define+SIMULATION', '+define+den4096Mb', '+define+sg25E', '+define+x16',
            '+incdir+' + str(source_list.parent), '-y', primitive, '+libext+.v',
            *sources], 'compile.log')
    result = invoke([args.modelsim / 'vsim.exe', '-c', '-quiet', '-lib', work,
                     'tb_pose_vendor', '-do',
                     'onerror {quit -code 1}; run -all; quit -f'], 'sim.log')
    if 'PASS real vendor DDR3 arbiter' not in result:
        raise RuntimeError(f'PASS marker missing; see {output / "sim.log"}')
    print('\n'.join(line for line in result.splitlines()
                    if 'VENDOR' in line or 'PASS real vendor' in line))
    print(f'Logs and source hashes: {output}')


if __name__ == '__main__':
    main()

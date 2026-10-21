"""Record/check the real local EmbFPGA.pds input files (no Git required)."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def inputs():
    project = (ROOT/'EmbFPGA.pds').read_text(encoding='utf-8')
    if project.lstrip().startswith('<'):
        names=[n.attrib['file'] for n in ET.fromstring(project).iter('item')
               if n.attrib.get('type')=='FILE' and n.attrib['file'].endswith(('.v','.vp','.vh'))]
    else:
        block = re.search(r'\(_widget wgt_my_design_src(.*?)\n        \(_widget', project, re.S)
        if not block:
            raise SystemExit('Cannot identify the project design source list')
        names = re.findall(r'\(_file "([^"]+)"', block[1])
    if not names or any('scale_in_1920_to_1440' in n or 'scale_out_1440_to_1920' in n for n in names):
        raise SystemExit('Missing sources or legacy scalers in active project')
    names += ['src/hdmi_ddr3_top.fdc', 'generate_project.ps1',
              'calibration/camera_20260930.json', 'tools/generate_undistort_cache.py']
    hashes = {}
    for name in sorted(set(names)):
        path = (ROOT/name).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise SystemExit(f'Project source outside test or missing: {name}')
        hashes[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--check', action='store_true')
    args=parser.parse_args()
    hashes=inputs()
    if args.check:
        saved=json.loads(args.manifest.read_text(encoding='utf-8'))
        if saved['sha256'] != hashes:
            raise SystemExit('Project sources changed during implementation; rebuild required')
        print('Local test/EmbFPGA.pds source identity verified')
        return
    if args.manifest.exists():
        raise SystemExit('Refusing to overwrite existing identity')
    args.manifest.write_text(json.dumps({
        'project': str(ROOT/'EmbFPGA.pds'),
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'algorithm_baseline': '6be49a4',
        'adaptation_reference': '7a185511ac8e9ebfa51e8f78bfa2f2f56eac8e9e',
        'architecture': 'default full-frame yaw/pitch projection; locked source slot, two corrected slots, word cache and burst DDR arbiter; legacy band path selectable',
        'board_validated': False, 'sha256': hashes,
    }, indent=2)+'\n', encoding='utf-8')
    print(f'Local project identity saved: {args.manifest}')


if __name__=='__main__':
    main()

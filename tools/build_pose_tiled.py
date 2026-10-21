"""Build isolated PDS inputs; audit immutable snapshots separately from current RTL."""
import argparse
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import json
import hashlib
import re
from datetime import datetime
from audit_pose_fifo_cdc import audit as audit_fifo_cdc
ROOT=Path(__file__).resolve().parents[1]

def sha256(data):
    return hashlib.sha256(data).hexdigest()

def input_name(name,directory):
    """Normalize only project source roots; generated task files are not inputs."""
    path=Path(name)
    # PDS rewrites absolute file references relative to the isolated project
    # when saving. Resolve that spelling before comparing source membership.
    if not path.is_absolute() and path.parts and path.parts[0] in ('src','ipcore'):
        return path.as_posix() if '..' not in path.parts else None
    path=path if path.is_absolute() else directory/path
    for base in (directory/'input_snapshot',ROOT):
        try:
            path=path.resolve().relative_to(base.resolve())
            break
        except ValueError:
            pass
    else:return None
    if path.parts and path.parts[0] in ('src','ipcore') and '..' not in path.parts:
        return path.as_posix()
    return None

def project_config(tree,directory,version=3):
    """Digest build settings and source membership, excluding mutable task status."""
    def canonical(node):
        return {'tag':node.tag,'attributes':dict(sorted(node.attrib.items())),
                'text':(node.text or '').strip(),'children':[canonical(c) for c in node]}
    def options(node):
        if version==1:
            return sorted(ET.tostring(child,encoding='unicode').strip()
                          for child in node.findall('./options/option'))
        return sorted((canonical(child) for child in node.findall('./options/option')),
                      key=lambda item:item['attributes'].get('name',''))
    entries={'options':options(tree.getroot()),'parts':[], 'tasks':[], 'sources':[]}
    for part in tree.iter('part'):entries['parts'].append(dict(sorted(part.attrib.items())))
    for task in tree.iter('task'):
        entries['tasks'].append({'name':task.get('name'),'options':options(task),
            'actions':[{'name':action.get('name'),'options':options(action)}
                       for action in task.findall('action')]})
    for node in tree.iter('item'):
        if node.get('type') in ('FILE','IP') and (name:=input_name(node.get('file',''),directory)):
            file_options=options(node)
            # PDS expands FILE format/library attributes into identical
            # option children on save. These add no new configuration.
            if version>=3:
                file_options=[item for item in file_options if not (
                    item['attributes'].get('name') in ('format','library') and
                    item['attributes'].get('value')==node.get(item['attributes']['name']) and
                    item['attributes'].get('type')=='string' and not item['children'])]
            entries['sources'].append({'file':name,'format':node.get('format'),
                                      'library':node.get('library'),'options':file_options})
    return sha256(json.dumps(entries,sort_keys=True,separators=(',',':')).encode())

def snapshot_inputs(directory,hashes,tree,*,retrospective=False):
    """Create a write-once snapshot without modifying a running PDS project."""
    manifest=directory/'snapshot_identity.json'
    if manifest.exists():
        verify_snapshot(directory,hashes,tree)
        return
    blobs={name:(ROOT/name).read_bytes() for name in hashes}
    changed=[name for name,data in blobs.items() if sha256(data)!=hashes[name]]
    if changed:raise SystemExit(f'Refusing snapshot: inputs differ from original manifest: {changed}')
    # Preserve complete source trees, including relative include/ROM files.
    # Current sources have no literal include/readmem dependency outside them.
    # Conservatively track all copied files so later supporting-file edits are visible.
    for source_root in ('src','ipcore'):
        for source in (ROOT/source_root).rglob('*'):
            if source.is_file():blobs.setdefault(source.relative_to(ROOT).as_posix(),source.read_bytes())
    for name,data in blobs.items():
        target=directory/'input_snapshot'/name
        target.parent.mkdir(parents=True,exist_ok=True)
        if target.exists():
            if target.read_bytes()!=data:raise SystemExit(f'Refusing to replace snapshot input: {target}')
        else:target.write_bytes(data)
    original_project=(ROOT/'EmbFPGA.pds').read_bytes()
    isolated_project=(directory/'pose_tiled.pds').read_bytes()
    for name,data in (('original_project.pds',original_project),('isolated_project.pds',isolated_project)):
        target=directory/'input_snapshot'/name
        if target.exists() and target.read_bytes()!=data:raise SystemExit(f'Refusing to replace snapshot project: {target}')
        if not target.exists():target.write_bytes(data)
    evidence={'version':1,'project_config_version':3,'created_at':datetime.now().isoformat(),
        'retrospective_live_build_snapshot':retrospective,
        'pds_reads_snapshot_inputs':not retrospective,
        'source_identity_sha256':sha256((directory/'source_identity.json').read_bytes()),
        'source_files':{name:sha256(data) for name,data in sorted(blobs.items())},
        'original_project_sha256':sha256(original_project),
        'isolated_project_at_snapshot_sha256':sha256(isolated_project),
        'original_project_config_sha256':project_config(ET.ElementTree(ET.fromstring(original_project)),directory),
        'build_project_config_sha256':project_config(tree,directory)}
    manifest.write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    verify_snapshot(directory,hashes,tree)
    print(f'Verified {len(blobs)} snapshot files; retrospective={retrospective}: {directory}',flush=True)

def verify_snapshot(directory,hashes,tree):
    manifest=directory/'snapshot_identity.json'
    if not manifest.is_file():return None
    evidence=json.loads(manifest.read_text(encoding='utf-8'))
    if sha256((directory/'source_identity.json').read_bytes())!=evidence['source_identity_sha256']:
        raise SystemExit('Source identity manifest changed after snapshot')
    invalid=[name for name,digest in evidence['source_files'].items()
             if not (directory/'input_snapshot'/name).is_file() or
             sha256((directory/'input_snapshot'/name).read_bytes())!=digest]
    invalid += [name for name,digest in hashes.items() if evidence['source_files'].get(name)!=digest]
    for name,key in (('original_project.pds','original_project_sha256'),
                     ('isolated_project.pds','isolated_project_at_snapshot_sha256')):
        path=directory/'input_snapshot'/name
        if not path.is_file() or sha256(path.read_bytes())!=evidence[key]:invalid.append(name)
    if invalid:raise SystemExit(f'Snapshot contents changed or missing: {invalid}')
    saved_tree=ET.parse(directory/'input_snapshot/isolated_project.pds')
    if project_config(saved_tree,directory,evidence.get('project_config_version',1))!=evidence['build_project_config_sha256']:
        raise SystemExit('Snapshot project configuration digest is inconsistent')
    if project_config(tree,directory)!=project_config(saved_tree,directory):
        raise SystemExit('Isolated project build settings changed after snapshot')
    if evidence['pds_reads_snapshot_inputs']:
        for node in tree.iter('item'):
            if node.get('type') in ('FILE','IP') and (name:=input_name(node.get('file',''),directory)):
                actual=Path(node.get('file'))
                actual=actual if actual.is_absolute() else directory/actual
                if actual.resolve()!=(directory/'input_snapshot'/name).resolve():
                    raise SystemExit(f'Project input escapes immutable snapshot: {name}')
    return evidence

def source_status(directory,hashes,tree,allow_drift=False):
    snapshot=verify_snapshot(directory,hashes,tree)
    expected=snapshot['source_files'] if snapshot else hashes
    changed=[name for name,digest in expected.items() if not (ROOT/name).is_file() or
             sha256((ROOT/name).read_bytes())!=digest]
    project_changed=bool(snapshot and project_config(ET.parse(ROOT/'EmbFPGA.pds'),directory)!=
                         project_config(ET.parse(directory/'input_snapshot/original_project.pds'),directory))
    status={'snapshot_verified':bool(snapshot),
        'current_source_matches':not changed and not project_changed,
        'changed_source_files':changed,'current_project_config_changed':project_changed,
        'retrospective_live_build_snapshot':bool(snapshot and snapshot['retrospective_live_build_snapshot'])}
    (directory/'source_status.json').write_text(json.dumps(status,indent=2)+'\n',encoding='utf-8')
    if not status['current_source_matches']:
        message=f'Current workspace differs from build inputs: files={changed}, project_config_changed={project_changed}'
        if not allow_drift:raise SystemExit(message+'; snapshot-only historical audit requires --allow-source-drift')
        if not snapshot:raise SystemExit('Historical audit requires a verified input snapshot')
        print('HISTORICAL SNAPSHOT ONLY: '+message,flush=True)
    else:print('Build inputs match current workspace.',flush=True)
    return status

def audit_routed_build(directory,status=None):
    """Require both-corner timing, Gray bus skew, and a generated bitstream."""
    timing=directory/'prj_tasks/pnr_1/report_timing/hdmi_ddr3_top.rtr'
    report=timing.read_text(encoding='utf-8',errors='replace')
    if not re.search(r'Design Summary\s*:\s*All Constraints Met',report):
        raise SystemExit(f'Routed timing constraints failed: {timing}')
    if 'Timing analysis mode : multi corner' not in report:
        raise SystemExit(f'Both operating corners must be checked: {timing}')
    for corner in ('Slow','Fast'):
        for kind in ('Setup','Hold','Recovery','Removal','Minimum Pulse Width'):
            if f'{kind} Summary({corner} Corner)' not in report:
                raise SystemExit(f'Missing {corner} {kind} timing coverage: {timing}')
    cdc=audit_fifo_cdc(timing.parent/'report_db')
    (directory/'pose_fifo_cdc.json').write_text(json.dumps(cdc,indent=2)+'\n',encoding='utf-8')
    bitstream=directory/'prj_tasks/pnr_1/generate_bitstream/hdmi_ddr3_top.sbit'
    if not bitstream.is_file() or not bitstream.stat().st_size:
        raise SystemExit(f'Missing generated bitstream: {bitstream}')
    if bitstream.stat().st_mtime < timing.stat().st_mtime:
        raise SystemExit(f'Bitstream predates final timing report: {bitstream}')
    evidence={'timing_passed':True,'fifo_cdc_passed':True,'board_tested':False,
              'source_status':status,
              'files':{str(path.relative_to(directory)):{'bytes':path.stat().st_size,
                       'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
                       for path in (timing,bitstream,directory/'source_identity.json',
                                    directory/'snapshot_identity.json',directory/'source_status.json')
                       if path.is_file()}}
    (directory/'build_audit.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print(f'PASS routed timing, FIFO CDC, and bitstream identity: {directory}',flush=True)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--route',action='store_true')
    p.add_argument('--output',type=Path)
    p.add_argument('--resume',action='store_true',help='resume an unchanged isolated --output build')
    p.add_argument('--audit-only',action='store_true',help='check a finished --route --output build without running PDS')
    p.add_argument('--snapshot-only',action='store_true',help='archive verified inputs of an existing build without changing its project or running PDS')
    p.add_argument('--allow-source-drift',action='store_true',help='audit a historical snapshot; never claim it represents current workspace sources')
    args=p.parse_args()
    if sum((args.resume,args.audit_only,args.snapshot_only))>1:p.error('choose only one of --resume/--audit-only/--snapshot-only')
    if (args.resume or args.audit_only or args.snapshot_only) and not args.output:p.error('--resume/--audit-only/--snapshot-only requires --output')
    if args.allow_source_drift and not args.audit_only:p.error('--allow-source-drift is only valid with --audit-only')
    if args.audit_only:args.route=True
    directory=args.output or ROOT/'verification'/('pds_pose_tiled_'+datetime.now().strftime('%Y%m%d_%H%M%S'))
    directory=directory.resolve();directory.mkdir(parents=True,exist_ok=True)
    project=directory/'pose_tiled.pds'
    identity=directory/'source_identity.json'
    if args.resume or args.audit_only or args.snapshot_only:
        tree=ET.parse(project)
        hashes=json.loads(identity.read_text(encoding='utf-8'))
        if args.snapshot_only:
            snapshot_inputs(directory,hashes,tree,retrospective=True)
            source_status(directory,hashes,tree)
            return
    else:
        if project.exists():p.error('output already contains a build; use --resume or a new directory')
        tree=ET.parse(ROOT/'EmbFPGA.pds')
        hashes={}
        for node in tree.iter('item'):
            if node.attrib.get('type') in ('FILE','IP'):
                name=input_name(node.attrib['file'],directory)
                if name:
                    path=ROOT/name
                    hashes[name]=hashlib.sha256(path.read_bytes()).hexdigest()
                    node.set('file',(directory/'input_snapshot'/name).as_posix())
        for node in tree.iter('state'):node.set('value','INIT')
        # PDS marks several timing options read-only in Tcl. Set them in the
        # isolated project before opening it, rather than mutating a live task.
        settings={
            'cmd_place':{'optimize_multi_corner_timing':'TRUE',
                         'optimize_dp_recovery':'TRUE','optimize_rp_recovery':'TRUE'},
            'cmd_route_optimize':{'fix_hold_violation':'TRUE'},
            'cmd_report_post_pnr_timing':{'nworst':'64','max_path':'64','report_max_skew':'TRUE'}}
        for action in tree.iter('action'):
            for name,value in settings.get(action.attrib.get('name'),{}).items():
                options=action.find('options')
                option=options.find(f"option[@name='{name}']")
                if option is None:
                    option=ET.SubElement(options,'option',name=name,
                                         type='interger' if name in ('nworst','max_path') else 'switch')
                option.set('value',value)
        tree.write(project,encoding='utf-8',xml_declaration=True)
        identity.write_text(json.dumps(hashes,indent=2),encoding='utf-8')
        snapshot_inputs(directory,hashes,tree)
    status=source_status(directory,hashes,tree,args.allow_source_drift)
    stages=['compile','synthesize']
    if args.route:stages+=['dev_map','place','route','route_optimize','report_timing','gen_bit_stream']
    actions=dict(zip(('compile','synthesize','dev_map','place','route','route_optimize','report_timing','gen_bit_stream'),
                     ('cmd_compile','cmd_synthesize','cmd_devmap','cmd_place','cmd_route',
                      'cmd_route_optimize','cmd_report_post_pnr_timing','cmd_gen_bitstream')))
    def completed(tree,stage):
        action=next(a for a in tree.iter('action') if a.attrib.get('name')==actions[stage])
        return action.find('state').attrib['value']=='OK'
    if args.audit_only:
        incomplete=[stage for stage in stages if not completed(tree,stage)]
        if incomplete:raise SystemExit(f'PDS stages incomplete: {incomplete}')
        audit_routed_build(directory,status)
        return
    lines=[f'open_project {{{project.as_posix()}}}',
           'set_option max_threads 8',
           'set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484',
           'set_option -options {top_module {hdmi_ddr3_top}} [get_filesets design_1]']
    for stage in stages:
        if args.resume and completed(tree,stage):continue
        task='syn_1' if stage in ('compile','synthesize') else 'pnr_1'
        lines += [f'launch_tasks [get_tasks {task}] -to_action {stage}',
                  f'wait_on_tasks [get_tasks {task}] -to_action {stage}']
    stem='resume_'+datetime.now().strftime('%Y%m%d_%H%M%S') if args.resume else 'build'
    script=directory/(stem+'.tcl');script.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print(f'PDS output: {directory}',flush=True)
    log_path=directory/(stem+'.log')
    with log_path.open('w',encoding='utf-8') as log:
        result=subprocess.run([r'D:\pango\PDS_2025.2-ads\bin\pds_shell.exe','-file',str(script)],
                              cwd=directory,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode or re.search(r'^E:',log_path.read_text(encoding='utf-8',errors='replace'),re.M):
        raise SystemExit(f'PDS failed ({result.returncode}); inspect {log_path}')
    final_tree=ET.parse(project)
    status=source_status(directory,hashes,final_tree)
    incomplete=[stage for stage in stages if not completed(final_tree,stage)]
    if incomplete:raise SystemExit(f'PDS stages incomplete: {incomplete}; inspect {log_path}')
    if args.route:audit_routed_build(directory,status)
    print(f'PDS finished: {directory}',flush=True)
if __name__=='__main__':main()

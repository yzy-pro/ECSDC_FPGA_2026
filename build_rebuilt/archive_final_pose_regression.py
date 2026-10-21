from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,os,re,shutil,subprocess,sys

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools'))
import build_identity
stamp=datetime.now().strftime('%Y%m%d_%H%M%S')
archive=root/'verification/pose_large_angle_20261009/rtl'/('final_bounded20_'+stamp)
archive.mkdir(parents=True,exist_ok=False)
command=[str(root/'reference/imu_cboard/.venv/Scripts/python.exe'),
         str(root/'tests/run_rtl_regressions.py'),'--modelsim',r'D:\pango\modeltech64_10.6e\win64']
def hashes():
    values=build_identity.inputs()
    for path in sorted((root/'tests').rglob('*')):
        if path.is_file() and path.suffix in {'.sv','.v','.vh','.py','.json','.mem','.hex'}:
            values[path.relative_to(root).as_posix()]=hashlib.sha256(path.read_bytes()).hexdigest()
    return values
before=hashes()
manifest={'created_utc':datetime.now(timezone.utc).isoformat(),'command':command,'sha256':before,
          'scope':'quick RTL regressions; final bounded-product RTL; no full 1080p raster option',
          'board_validated':False}
(archive/'source_identity.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print('ARCHIVE '+str(archive),flush=True)
summary=archive/'quick_regression.log'
with summary.open('w',encoding='utf-8') as output:
    finished=subprocess.run(command,cwd=root,stdout=output,stderr=subprocess.STDOUT,timeout=1200)
text=summary.read_text(encoding='utf-8')
directories=set()
for name in re.findall(r'progress log: (.*\.log)',text):
    directories.add(Path(name.strip()).parent)
for directory in directories:
    for path in directory.iterdir():
        if path.suffix in {'.log','.sv'}:
            shutil.copy2(path,archive/path.name)
after=hashes()
changed=sorted(set(before)^set(after)|{name for name in before.keys()&after.keys() if before[name]!=after[name]})
result={'completed_utc':datetime.now(timezone.utc).isoformat(),'returncode':finished.returncode,
        'unchanged_sources':not changed,'changed_sources':changed,
        'build_directories':[str(path) for path in directories],
        'pass_lines':[line for line in text.splitlines() if 'PASS' in line],
        'artifact_sha256':{path.name:hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted(archive.iterdir()) if path.is_file()}}
(archive/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(text,flush=True)
print('SOURCES_UNCHANGED '+str(not changed),flush=True)
print('ARCHIVE '+str(archive),flush=True)
sys.exit(finished.returncode or (1 if changed else 0))

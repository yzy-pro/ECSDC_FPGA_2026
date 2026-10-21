import copy
import importlib.util
from pathlib import Path
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',root/'tools/audit_pose_fifo_cdc.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
directory=root/'build_rebuilt/cdc_audit_fixtures';directory.mkdir(exist_ok=True)
tree=ET.Element('tables');table=ET.SubElement(tree,'table')
for fifo in ('u_capture_fifo','u_display_fifo'):
    for prefix,sync in (('wr','wr_gray_rd1'),('rd','rd_gray_wr1')):
        group=ET.SubElement(table,'row')
        fields=['MaxSkew Path 6.734ns','5.234','','','','','','','','','6.734','1.500','','']
        for text in fields:ET.SubElement(group,'data').text=text
        extrema=ET.SubElement(group,'row')
        for bit in range(10):
            path=ET.SubElement(extrema,'row');source='binary' if bit==9 else 'gray'
            fields=['Path','5.234','0','1',f'top/{fifo}/{prefix}_{source}[{bit}]/opit_0/CLK',
                    f'top/{fifo}/{sync}[{bit}]/opit_0/D','src','dst','0','1.0','6.734','1.500','','']
            for text in fields:ET.SubElement(path,'data').text=text

def write_fixture(value):
    for corner in ('slow','fast'):
        ET.ElementTree(value).write(directory/f'report_timing_{corner}_path_max_skew.db')

write_fixture(tree)
assert len(module.audit(directory)['corners']['slow'])==4
for fault in ('negative_skew','missing_msb','wrong_source','relaxed_bound','missing_group'):
    bad=copy.deepcopy(tree)
    group=bad.find('table/row')
    if fault=='negative_skew':group.findall('data')[1].text='-0.001';group.findall('data')[11].text='6.735'
    elif fault=='missing_msb':group.find('row').remove(group.findall('row/row')[-1])
    elif fault=='wrong_source':group.find('row/row').findall('data')[4].text='wrong_source'
    elif fault=='relaxed_bound':group.findall('data')[10].text='10.000'
    else:bad.find('table').remove(group)
    write_fixture(bad)
    try:module.audit(directory)
    except ValueError:pass
    else:raise AssertionError(f'fault accepted: {fault}')
write_fixture(tree)
print('PASS FIFO CDC audit fixtures: 40 bits including merged MSBs, both corners, five injected failures rejected')

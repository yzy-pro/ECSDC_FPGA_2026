from pathlib import Path
import re
t=Path('test.pds').read_text()
for widget,name,fmt,top in [('wgt_my_design_src','probe.v','verilog',' + "probe"'),
                            ('wgt_import_logic_con_file','probe.fdc','fdc','')]:
    t=re.sub(r'        \(_widget '+widget+r'\n        \)',
        f'        (_widget {widget}\n            (_input\n                (_file "{name}"{top}\n                    (_format {fmt})\n                    (_timespec "2026-10-09T18:00:00")\n                )\n            )\n        )',t)
t=t.replace('(_gci_state (_integer 4))','(_gci_state (_integer 0))')
t=t.replace('(_option selected_syn_tool_opt (_integer 1))','(_option ads (_switch ON))\n            (_option selected_syn_tool_opt (_integer 2))')
Path('build_rebuilt/cdc_constraint_probe/probe.pds').write_text(t)

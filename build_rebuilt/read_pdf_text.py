from pathlib import Path
import re,zlib,sys
source=Path(sys.argv[1]).read_bytes()
objects={int(m[1]):m[2] for m in re.finditer(rb'(\d+) \d+ obj\b(.*?)endobj',source,re.S)}
def stream(obj):
    m=re.search(rb'stream\r?\n(.*?)\r?\nendstream',obj,re.S)
    if not m:return b''
    try:return zlib.decompress(m[1])
    except zlib.error:return m[1]
fonts={}
for alias,objid in re.findall(rb'/F(\d+) (\d+) \d+ R',source):
    obj=objects.get(int(objid),b'')
    m=re.search(rb'/ToUnicode (\d+) \d+ R',obj)
    if not m:continue
    cmap=stream(objects[int(m[1])]); mapping={}
    for block in re.findall(rb'beginbfchar(.*?)endbfchar',cmap,re.S):
        for a,b in re.findall(rb'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',block):
            mapping[int(a,16)]=bytes.fromhex(b.decode()).decode('utf-16-be','replace')
    for block in re.findall(rb'beginbfrange(.*?)endbfrange',cmap,re.S):
        for a,b,c in re.findall(rb'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',block):
            for i in range(int(a,16),int(b,16)+1): mapping[i]=chr(int(c,16)+i-int(a,16))
    fonts[int(alias)]=mapping
text=[]
for obj in objects.values():
    data=stream(obj)
    if b'TJ' not in data:continue
    font=0
    for command in re.finditer(rb'/F(\d+)\s+[\d.]+\s+Tf|\[((?:[^\]]|\](?!\s*TJ))*)\]\s*TJ',data):
        if command[1]:font=int(command[1]);continue
        line=[]
        for token in re.finditer(rb'\(((?:\\.|[^\\)])*)\)|<([a-fA-F0-9]+)>',command[2]):
            if token[1] is not None:line.append(token[1].decode('latin1'))
            else:
                codes=bytes.fromhex(token[2].decode('ascii'));mapping=fonts.get(font,{})
                line.append(''.join(mapping.get(int.from_bytes(codes[i:i+2],'big'),'?') for i in range(0,len(codes),2)))
        text.append(''.join(line))
Path(sys.argv[2]).write_text('\n'.join(text),encoding='utf-8')
print(len(objects),len(fonts),len(text))

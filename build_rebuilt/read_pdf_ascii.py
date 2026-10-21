from pathlib import Path
import re,zlib,sys
source=Path(sys.argv[1]).read_bytes()
text=[]
for stream in re.finditer(rb'stream\r?\n(.*?)\r?\nendstream',source,re.S):
    try: data=zlib.decompress(stream[1])
    except zlib.error: continue
    for command in re.finditer(rb'\[(.*?)\]\s*TJ',data,re.S):
        line=[]
        for token in re.finditer(rb'\(((?:\\.|[^\\)])*)\)|<([a-fA-F0-9]+)>',command[1]):
            if token[1] is not None: line.append(token[1].decode('latin1'))
            else:
                codes=bytes.fromhex(token[2].decode('ascii'))
                line.append(''.join(chr(int.from_bytes(codes[i:i+2],'big')+29)
                    if int.from_bytes(codes[i:i+2],'big')<100 else '?'
                    for i in range(0,len(codes),2)))
        text.append(''.join(line))
Path(sys.argv[2]).write_text('\n'.join(text),encoding='utf-8')

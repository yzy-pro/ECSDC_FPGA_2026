"""Verify generated eight-band limits, slot ROM and lookahead retention."""
from pathlib import Path
import re
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from generate_undistort_cache import schedule,ROWS,BASES,CACHE_DEPTH,SLOT_BITS,table_source,check_parameters

def main():
    check_parameters(ROOT)
    rows=schedule()
    table=(ROOT/'src/video/undistort/undistort_band_tables.v').read_text(encoding='ascii')
    assert table==table_source(rows),'stale table'
    slots=[int(x,16) for x in re.findall(r"slots\[\d+\] = 48'h([0-9a-f]+)",table)]
    assert len(slots)==541
    addresses=set()
    for b,n in enumerate(ROWS):
        for y,entry in enumerate(slots):
            assert ((entry>>(SLOT_BITS*b))&63)==y%(n//2)
        for local in range(n//2):
            for word in range(15):
                a=BASES[b]+local*15+word
                assert a not in addresses and 0<=a<CACHE_DEPTH
                addresses.add(a)
    assert len(addresses)==CACHE_DEPTH
    tags=[{} for _ in range(8)]
    loaded=[r[0]-1 for r in rows[0]]
    checked=0
    for output in range(1080):
        for b,n in enumerate(ROWS):
            low,high=rows[output][b]
            target=rows[min(output+2,1079)][b][1]
            for y in range(loaded[b]+1,target+1):
                old=tags[b].get(y%n)
                assert old is None or old<rows[max(output-1,0)][b][0],'lookahead evicts live source row'
                tags[b][y%n]=y
            loaded[b]=target
            for y in range(low,high+1):
                assert tags[b].get(y%n)==y
                checked+=1
    print(f'PASS eight-band slot ROM, {CACHE_DEPTH} unique addresses/parity, {checked} row checks, dynamic envelope, two-line lookahead')
if __name__=='__main__':main()

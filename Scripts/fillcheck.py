# Heap-on-node fill levels ([MS-PST] 2.3.1.2/2.3.1.3): for each block, the stored rgbFillLevel
# nibble (HNHDR for blocks 0-7, HNBITMAPHDR at blocks 8, 136, ... for the next 128) versus the
# level computed from the block's actual free space (2.3.1.5 FILLLEVEL ranges).
import sys, struct; sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from pstdump import PST
def level(free):
    for lim, lv in ((3584,0),(2560,1),(2048,2),(1792,3),(1536,4),(1280,5),(1024,6),(768,7),(512,8),(256,9),(128,10),(64,11),(32,12),(16,13),(8,14)):
        if free >= lim: return lv
    return 15
def free_of(b):
    ibHnpm = struct.unpack_from('<H', b, 0)[0]
    cAlloc, cFree = struct.unpack_from('<HH', b, ibHnpm)
    offs = struct.unpack_from('<%dH' % (cAlloc + 1), b, ibHnpm + 4)
    used_end = offs[-1]
    return 8176 - (ibHnpm + 4 + 2 * (cAlloc + 1)) + (ibHnpm - used_end), len(b)
def check(p, nid):
    blocks = p.data(p.nodes[nid][0]); stored = {}
    hdr = blocks[0]
    for i in range(8): stored[i] = (hdr[8 + i // 2] >> (4 * (i % 2))) & 0xF
    for k in range(8, len(blocks), 128):
        bm = blocks[k]
        for i in range(128): stored[k + i] = (bm[2 + i // 2] >> (4 * (i % 2))) & 0xF
    bad = []
    for i, b in enumerate(blocks):
        fr, ln = free_of(b)
        # a block padded to 8176 (not the last) has the padding as free space too
        exp = level(fr)
        if stored.get(i) != exp: bad.append((i, stored.get(i), exp, fr))
    return len(blocks), bad
if __name__ == '__main__':
    for path in sys.argv[1:]:
        p = PST(path); tot = 0; badn = 0; ex = []
        for nid in sorted(p.nodes):
            try:
                if not p.nodes[nid][0]: continue
                blocks = p.data(p.nodes[nid][0])
                if not blocks or len(blocks[0]) < 12 or blocks[0][2] != 0xEC: continue
                n, bad = check(p, nid); tot += 1
                if bad: badn += 1; ex.append((hex(nid), n, bad[:4]))
            except Exception as e: pass
        print(path.split('/')[-1][:44], 'heaps', tot, 'with wrong fill levels', badn); [print('   ', e) for e in ex[:6]]

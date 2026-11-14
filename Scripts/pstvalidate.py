# Strict [MS-PST] Unicode NDB validator (not shipped): the checks Outlook
# makes that libpff/readpst skip — page and block trailers (CRC, signature,
# BID), B-tree page shape and ordering, reference counts, and the allocation
# map (every used 64-byte unit marked, nothing else; free total = header).
import struct, sys, zlib

def crc32_pst(data):
    # [MS-PST] 5.3: reflected 0xEDB88320, initial 0, no final XOR.
    # zlib.crc32 uses initial 0xFFFFFFFF and final XOR: undo both.
    return (zlib.crc32(data, 0xFFFFFFFF) ^ 0xFFFFFFFF) & 0xFFFFFFFF if False else _crc(data)

_T = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
    _T.append(c)
def _crc(data):
    c = 0
    for b in data:
        c = _T[(c ^ b) & 0xFF] ^ (c >> 8)
    return c

def sig(ib, bid):
    v = ib ^ bid
    return ((v >> 16) ^ v) & 0xFFFF

AMAP_BASE, REGION = 0x4400, 253952

def main(path):
    b = open(path, 'rb').read()
    u16 = lambda o: struct.unpack_from('<H', b, o)[0]
    u32 = lambda o: struct.unpack_from('<I', b, o)[0]
    u64 = lambda o: struct.unpack_from('<Q', b, o)[0]
    errs, notes = [], []
    def err(m):
        if len(errs) < 60: errs.append(m)
        else: errs.append(None)
    # Header CRCs.
    if u32(4) != _crc(b[8:8+471]): err('header dwCRCPartial wrong')
    if u32(524) != _crc(b[8:8+516]): err('header dwCRCFull wrong')
    eof, amapLast, cbAMapFree = u64(184), u64(192), u64(200)
    if eof != len(b): err(f'ibFileEof {eof:#x} != file size {len(b):#x}')
    used = {}   # unit index -> what
    def mark(ib, size, what):
        if ib % 64: err(f'{what} at {ib:#x} not 64-aligned')
        for u in range(ib // 64, (ib + size + 63) // 64):
            if u in used: err(f'overlap at {u*64:#x}: {used[u]} and {what}')
            used[u] = what

    def page(ib, ptype, bidExpected=None, what='page'):
        p = b[ib:ib+512]
        t, trep, wsig, crc, bid = p[496], p[497], struct.unpack_from('<H', p, 498)[0], struct.unpack_from('<I', p, 500)[0], struct.unpack_from('<Q', p, 504)[0]
        if t != ptype or trep != ptype: err(f'{what} {ib:#x}: ptype {t:#x}/{trep:#x}, expected {ptype:#x}')
        if crc != _crc(p[:496]): err(f'{what} {ib:#x}: page CRC wrong')
        if ptype in (0x80, 0x81, 0x86):   # B-tree pages and DList carry a signature; AMap/PMap: 0
            if wsig != sig(ib, bid): err(f'{what} {ib:#x}: wSig {wsig:#x} != {sig(ib, bid):#x}')
        elif wsig != 0: err(f'{what} {ib:#x}: map page wSig must be 0, is {wsig:#x}')
        if bidExpected is not None and bid != bidExpected: err(f'{what} {ib:#x}: trailer bid {bid:#x} != referenced {bidExpected:#x}')
        return p, bid

    # B-trees.
    blocks, nodes = {}, {}
    def btree(ib, bidRef, isNBT, lastKey=None):
        p, bid = page(ib, 0x81 if isNBT else 0x80, bidRef, 'NBT' if isNBT else 'BBT')
        mark(ib, 512, f'{"NBT" if isNBT else "BBT"} page {ib:#x}')
        cEnt, cEntMax, cbEnt, cLevel = p[488], p[489], p[490], p[491]
        want = (32 if isNBT else 24) if cLevel == 0 else 24
        if cbEnt != want: err(f'page {ib:#x}: cbEnt {cbEnt} != {want}')
        if cEntMax != 488 // cbEnt: err(f'page {ib:#x}: cEntMax {cEntMax} != {488 // cbEnt}')
        if cEnt > cEntMax: err(f'page {ib:#x}: cEnt {cEnt} > max')
        if struct.unpack_from('<I', p, 492)[0] != 0: err(f'page {ib:#x}: dwPadding not 0')
        prev = None
        for i in range(cEnt):
            e = i * cbEnt
            key = struct.unpack_from('<Q', p, e)[0] if not (isNBT and cLevel == 0) else struct.unpack_from('<Q', p, e)[0]
            if isNBT and cLevel == 0: key = struct.unpack_from('<Q', p, e)[0]
            if prev is not None and key <= prev: err(f'page {ib:#x}: keys not ascending ({prev:#x} then {key:#x})')
            prev = key
            if cLevel > 0:
                cbid, cib = struct.unpack_from('<QQ', p, e + 8)
                btree(cib, cbid, isNBT)
            elif isNBT:
                nid = struct.unpack_from('<Q', p, e)[0]
                if nid >> 32: err(f'NBT {ib:#x}: nid has high dword set {nid:#x}')
                bdata, bsub, parent = struct.unpack_from('<QQI', p, e + 8)
                nodes[nid & 0xFFFFFFFF] = (bdata, bsub, parent)
            else:
                bbid, bib, cb, cRef = struct.unpack_from('<QQHH', p, e)
                if bbid & 1: err(f'BBT: bid {bbid:#x} has the reserved bit 0 set')
                blocks[bbid] = (bib, cb, cRef)
    nbtBid, nbtIb, bbtBid, bbtIb = u64(216), u64(224), u64(232), u64(240)
    btree(bbtIb, bbtBid, False)
    btree(nbtIb, nbtBid, True)

    # Blocks.
    for bid, (ib, cb, cRef) in blocks.items():
        size = cb + 16
        size = (size + 63) // 64 * 64
        if cb > 8176: err(f'block {bid:#x}: cb {cb} > 8176')
        t = ib + size - 16
        tcb, tsig, tcrc, tbid = struct.unpack_from('<HHIQ', b, t)
        if tcb != cb: err(f'block {bid:#x} @ {ib:#x}: trailer cb {tcb} != {cb}')
        if tsig != sig(ib, bid): err(f'block {bid:#x} @ {ib:#x}: wSig wrong')
        if tcrc != _crc(b[ib:ib+cb]): err(f'block {bid:#x} @ {ib:#x}: CRC wrong')
        if tbid != bid: err(f'block {bid:#x} @ {ib:#x}: trailer bid {tbid:#x}')
        if cRef < 1: err(f'block {bid:#x}: cRef {cRef}')
        mark(ib, size, f'block {bid:#x}')
    # Every block a node or an internal block refers to must exist.
    refs = {}
    def ref(bid, who):
        if bid == 0: return
        bid &= ~1
        refs[bid] = refs.get(bid, 0) + 1
        if bid not in blocks: err(f'{who}: block {bid:#x} not in BBT'); return
        ib, cb, _ = blocks[bid]
        d = b[ib:ib+cb]
        if bid & 2:   # internal: XBLOCK / XXBLOCK / SLBLOCK / SIBLOCK
            btype, lvl, n = d[0], d[1], struct.unpack_from('<H', d, 2)[0]
            if btype == 1:
                for i in range(n): ref(struct.unpack_from('<Q', d, 8 + 8 * i)[0], f'xblock {bid:#x}')
            elif btype == 2:
                for i in range(n):
                    if lvl == 0:
                        _, bd, bs = struct.unpack_from('<QQQ', d, 8 + 24 * i)
                        ref(bd, f'slblock {bid:#x}'); ref(bs, f'slblock {bid:#x}')
                    else:
                        ref(struct.unpack_from('<Q', d, 8 + 16 * i + 8)[0], f'siblock {bid:#x}')
            else: err(f'internal block {bid:#x}: btype {btype}')
    for nid, (bd, bs, parent) in nodes.items():
        ref(bd, f'node {nid:#x}'); ref(bs, f'node {nid:#x} sub')
    for bid, (ib, cb, cRef) in blocks.items():
        n = refs.get(bid, 0)
        if n == 0: err(f'block {bid:#x} in BBT but nothing refers to it')
        if cRef != n + 1 and cRef != n:
            notes.append(f'block {bid:#x}: cRef {cRef}, referenced {n}')

    # Fixed pages: DList, AMaps, PMaps.
    nregions = (len(b) - AMAP_BASE + REGION - 1) // REGION
    for k in range(nregions):
        a = AMAP_BASE + k * REGION
        page(a, 0x84, None, 'AMap'); mark(a, 512, f'AMap {a:#x}')
        if k % 8 == 0:
            page(a + 512, 0x83, None, 'PMap'); mark(a + 512, 512, f'PMap {a+512:#x}')
        if a == amapLast: pass
    if AMAP_BASE + (nregions - 1) * REGION != amapLast: err(f'ibAMapLast {amapLast:#x} != last AMap {AMAP_BASE + (nregions-1)*REGION:#x}')
    # DList at 0x4200 (before the first AMap) — outside the AMap's range.
    if b[0x4200 + 496] == 0x86:
        page(0x4200, 0x86, None, 'DList')
    else:
        notes.append('no DList page at 0x4200')
    # AMap bits vs use.
    free = 0
    leaked = [0]
    for k in range(nregions):
        a = AMAP_BASE + k * REGION
        bits = b[a:a+496]
        for i in range(496 * 8):
            u = (a // 64) + i
            if u * 64 >= len(b): break
            bit = (bits[i // 8] >> (7 - i % 8)) & 1
            inuse = u in used
            if bit and not inuse: leaked[0] += 1
            if not bit and inuse: err(f'AMap marks {u*64:#x} free but {used[u]} is there')
            if not bit: free += 64
    if free != cbAMapFree: err(f'cbAMapFree {cbAMapFree:#x} != free counted {free:#x}')
    notes.append(f'{leaked[0]} units marked used with nothing there (Outlook files have these too)')
    print(f'{path}: nodes {len(nodes)}, blocks {len(blocks)}, regions {nregions}, free {free:#x}')
    shown = [e for e in errs if e]
    print('ERRORS' if shown else 'no errors', len(shown) + (1 if None in errs else 0))
    for e in shown[:60]: print('  ', e)
    for n in notes[:10]: print('  note:', n)

if __name__ == '__main__':
    for p in sys.argv[1:]: main(p)

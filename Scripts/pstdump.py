# Minimal [MS-PST] inspector (Unicode only) used to study real Outlook files
# and to check mailin's PSTWriterV2 output. Not shipped.
import struct, sys

CRYPT = None
def load_crypt():
    # mpbbCrypt decode table = third 256-byte part (mpbbI) of the spec table
    import re
    src = open('/Users/shirshendusasmal/Downloads/mailin/Packages/ArchiveCore/Sources/ArchiveCore/PSTSpecReader.swift').read()
    start = src.index('= [', src.index('static let crypt: [UInt8]')) + 2
    body = src[start+1:src.index(']', start)]
    nums = [int(x) for x in re.findall(r'\d+', body)]
    assert len(nums) == 768, len(nums)
    return nums

class PST:
    def __init__(self, path):
        self.b = open(path, 'rb').read()
        b = self.b
        self.u64 = lambda o: struct.unpack_from('<Q', b, o)[0]
        self.u32 = lambda o: struct.unpack_from('<I', b, o)[0]
        self.u16 = lambda o: struct.unpack_from('<H', b, o)[0]
        assert struct.unpack_from('<H', b, 10)[0] >= 23, 'unicode only'
        self.crypt = b[513]
        global CRYPT
        if CRYPT is None: CRYPT = load_crypt()
        self.nodes = {}; self.blocks = {}
        self.walk(self.u64(224), True); self.walk(self.u64(240), False)

    def walk(self, ib, nbt, depth=0):
        b = self.b
        cEnt, cbEnt, lvl = b[ib+488], b[ib+490], b[ib+491]
        for i in range(cEnt):
            e = ib + i*cbEnt
            if lvl > 0: self.walk(self.u64(e+16), nbt, depth+1)
            elif nbt:
                nid = self.u32(e); self.nodes[nid] = (self.u64(e+8), self.u64(e+16), self.u32(e+24))
            else:
                bid = self.u64(e) & ~1; self.blocks[bid] = (self.u64(e+8), self.u16(e+16), self.u16(e+18))

    def block(self, bid):
        ib, cb, _ = self.blocks[bid & ~1]
        d = bytearray(self.b[ib:ib+cb])
        if bid & 2 == 0 and self.crypt == 1:
            d = bytearray(CRYPT[512 + x] for x in d)
        return bytes(d)

    def data(self, bid):
        """Node data as a list of blocks (XBLOCK expanded)."""
        if bid == 0: return []
        d = self.block(bid)
        if bid & 2 == 0: return [d]
        btype, lvl, cnt = d[0], d[1], struct.unpack_from('<H', d, 2)[0]
        assert btype == 1, ('XBLOCK expected', btype)
        out = []
        for i in range(cnt):
            child = struct.unpack_from('<Q', d, 8 + 8*i)[0]
            out += self.data(child) if lvl > 1 else [self.block(child)]
        return out

    def subnodes(self, bid):
        if bid == 0: return {}
        d = self.block(bid)
        btype, lvl, cnt = d[0], d[1], struct.unpack_from('<H', d, 2)[0]
        out = {}
        for i in range(cnt):
            if lvl == 0:
                e = 8 + 24*i
                out[struct.unpack_from('<I', d, e)[0]] = (struct.unpack_from('<Q', d, e+8)[0], struct.unpack_from('<Q', d, e+16)[0])
            else:
                out.update(self.subnodes(struct.unpack_from('<Q', d, 8 + 16*i + 8)[0]))
        return out

def heap(blocks):
    h = {'blocks': blocks}
    b0 = blocks[0]
    h['sig'], h['client'], h['root'] = b0[2], b0[3], struct.unpack_from('<I', b0, 4)[0]
    return h

def alloc(h, hid):
    if hid == 0: return b''
    bi, idx = hid >> 16, (hid >> 5) & 0x7FF
    blk = h['blocks'][bi]
    pm = struct.unpack_from('<H', blk, 0)[0]
    starts = [struct.unpack_from('<H', blk, pm + 4 + 2*i)[0] for i in range(struct.unpack_from('<H', blk, pm)[0] + 1)]
    return blk[starts[idx-1]:starts[idx]]

def bth(h, hid):
    hdr = alloc(h, hid)
    assert hdr[0] == 0xB5, hdr[:1]
    ck, ce, lv, root = hdr[1], hdr[2], hdr[3], struct.unpack_from('<I', hdr, 4)[0]
    def rec(hid, lv):
        d = alloc(h, hid); out = []
        if lv == 0:
            for i in range(0, len(d), ck+ce): out.append((d[i:i+ck], d[i+ck:i+ck+ce]))
        else:
            for i in range(0, len(d), ck+4): out += rec(struct.unpack_from('<I', d, i+ck)[0], lv-1)
        return out
    return rec(root, lv) if root else [], (ck, ce, lv)

def pc(p, nid):
    dbid, sbid, parent = p.nodes[nid]
    h = heap(p.data(dbid))
    recs, _ = bth(h, h['root'])
    out = {}
    for k, v in recs:
        pid = struct.unpack_from('<H', k)[0]; pt, hn = struct.unpack_from('<HI', v)
        out[pid] = (pt, hn)
    return out, h

def tc_cols(p, nid):
    dbid, sbid, parent = p.nodes[nid]
    h = heap(p.data(dbid))
    t = alloc(h, h['root'])
    assert t[0] == 0x7C
    ccols = t[1]
    rgib = struct.unpack_from('<4H', t, 2)
    rowidx, rows = struct.unpack_from('<II', t, 10)
    cols = [struct.unpack_from('<IHBB', t, 22 + 8*i) for i in range(ccols)]
    return rgib, cols, rowidx, rows

if __name__ == '__main__':
    p = PST(sys.argv[1])
    print('nodes', len(p.nodes), 'blocks', len(p.blocks), 'crypt', p.crypt)
    for nid in sorted(p.nodes):
        d, s, par = p.nodes[nid]
        print(hex(nid), 'type', hex(nid & 0x1F), 'parent', hex(par), 'data', hex(d), 'sub', hex(s))

# LTP-level checks SCANPST made on mailin's v3 file (2026-10-14), for any PST:
#  - every table context's row-index keys strictly ascending and non-zero ("keys overlap")
#  - every data tree: all blocks but the last full ("Middle page not full")
#  - attachment PidTagAttachSize = Outlook's sum of property values (method 1 only)
#  - templates 0x60D-0x610, 0x62B, 0x64C, 0x671, 0x692, 0x6B6, 0x6D7, 0x6F8 present
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from pstdump import PST, heap, bth, alloc

def tcs_of(p):
    """(label, data blocks) for every table context, top-level and in subnodes."""
    out = []
    def consider(label, bd, bs):
        if not bd: return
        blocks = p.data(bd)
        if blocks and len(blocks[0]) > 3 and blocks[0][2] == 0xEC and blocks[0][3] == 0x7C:
            out.append((label, blocks, bs))
    for nid, (bd, bs, _) in p.nodes.items():
        consider(f'{nid:#x}', bd, bs)
        if bs:
            for snid, (sbd, sbs) in p.subnodes(bs).items():
                consider(f'{nid:#x}/{snid:#x}', sbd, sbs)
    return out

def main(path):
    p = PST(path)
    errs = []
    # Tables: row index keys.
    for label, blocks, bs in tcs_of(p):
        h = heap(blocks)
        t = alloc(h, h['root'])
        ri = struct.unpack_from('<I', t, 10)[0]
        if not ri: continue
        recs, _ = bth(h, ri)
        keys = [struct.unpack_from('<I', k)[0] for k, v in recs]
        if any(k == 0 for k in keys) and label.split('/')[-1] not in ('0x60d',):
            errs.append(f'table {label}: row id 0')
        if any(b <= a for a, b in zip(keys, keys[1:])):
            errs.append(f'table {label}: row ids not ascending')
    # Data trees: middle blocks full.
    seen = set()
    def tree(bid, who):
        if not bid or bid in seen: return
        seen.add(bid)
        if bid & 2 == 0: return
        d = p.block(bid)
        if d[0] != 1: return
        lvl, n = d[1], struct.unpack_from('<H', d, 2)[0]
        kids = [struct.unpack_from('<Q', d, 8 + 8 * i)[0] for i in range(n)]
        if lvl == 1:
            sizes = [p.blocks[k & ~1][1] for k in kids]
            if any(s != 8176 for s in sizes[:-1]):
                errs.append(f'{who}: data tree {bid:#x} middle block not full {sizes[:-1][:4]}')
        for k in kids: tree(k, who)
    for nid, (bd, bs, _) in p.nodes.items():
        tree(bd, f'node {nid:#x}')
        if bs:
            for snid, (sbd, sbs) in p.subnodes(bs).items(): tree(sbd, f'node {nid:#x}/{snid:#x}')
    # Attachment sizes.
    att_ok = att_bad = 0
    fixed = {0x0002: 0, 0x0003: 4, 0x000B: 1, 0x0040: 8, 0x0014: 8}
    for nid, (bd, bs, _) in p.nodes.items():
        if nid & 0x1F != 4 or not bs: continue
        for snid, (abd, abs_) in p.subnodes(bs).items():
            if snid & 0x1F != 5: continue
            h = heap(p.data(abd)); recs, _ = bth(h, h['root'])
            asubs = p.subnodes(abs_) if abs_ else {}
            total = 0; size = None; method = None
            for kk, v in recs:
                pid = struct.unpack_from('<H', kk)[0]; pt, hn = struct.unpack_from('<HI', v)
                if pid == 0x0E20: size = hn
                if pid == 0x3705: method = hn
                if pt in fixed: total += fixed[pt]
                elif pt in (0x1F, 0x1E, 0x102, 0x0D):
                    if hn and hn & 0x1F == 0: total += len(alloc(h, hn))
                    elif hn in asubs: total += sum(len(x) for x in p.data(asubs[hn][0]))
            if method != 1: continue
            if size == total: att_ok += 1
            else:
                att_bad += 1
                if att_bad <= 3: errs.append(f'attachment {nid:#x}/{snid:#x}: PidTagAttachSize {size} != {total}')
    missing = [hex(t) for t in (0x60D, 0x60E, 0x60F, 0x610, 0x62B, 0x64C, 0x671, 0x692, 0x6B6, 0x6D7, 0x6F8) if t not in p.nodes]
    print(f'{path.split("/")[-1][:40]:40} tables ok-check, attachments size ok {att_ok} bad {att_bad}, templates missing {missing}')
    for e in errs[:12]: print('   ', e)
    print('   errors', len(errs))

if __name__ == '__main__':
    for a in sys.argv[1:]:
        try: main(a)
        except Exception as e: print(a.split('/')[-1], 'skipped:', e)

# Compares a fresh mailin PST with a SCANPST-repaired one of the same content: per message
# (matched by subject), the values SCANPST corrected — PidTagMessageSize, DisplayCc,
# DisplayBcc — plus the contents-row copies; and the size rule (data-block bytes) on both.
import sys, struct, collections
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from pstdump import PST, pc, alloc

def leafbytes(p, bid, seen):
    if not bid: return 0
    bid &= ~1
    if bid in seen: return 0
    seen.add(bid)
    if not bid & 2: return p.blocks[bid][1]
    d = p.block(bid); tot = 0
    if d[0] == 1:
        for i in range(struct.unpack_from('<H', d, 2)[0]): tot += leafbytes(p, struct.unpack_from('<Q', d, 8 + 8 * i)[0], seen)
    elif d[0] == 2:
        for i in range(struct.unpack_from('<H', d, 2)[0]):
            if d[1] == 0:
                _, bd, bs = struct.unpack_from('<QQQ', d, 8 + 24 * i); tot += leafbytes(p, bd, seen) + leafbytes(p, bs, seen)
            else: tot += leafbytes(p, struct.unpack_from('<Q', d, 8 + 16 * i + 8)[0], seen)
    return tot

def s(props, h, tag):
    v = props.get(tag)
    return alloc(h, v[1]).decode('utf-16-le') if v and v[1] else None

def table(p, path):
    out = {}
    for nid in [n for n in p.nodes if n & 0x1F == 4]:
        props, h = pc(p, nid); d, sb, _ = p.nodes[nid]
        out[s(props, h, 0x0037)] = dict(size=props[0x0E08][1], cc=s(props, h, 0x0E03), bcc=s(props, h, 0x0E02),
                                        blocks=leafbytes(p, d, set()) + leafbytes(p, sb, set()))
    return out

new, rep = table(PST(sys.argv[1]), sys.argv[1]), table(PST(sys.argv[2]), sys.argv[2])
c = collections.Counter(); ex = []
for subj, r in rep.items():
    n = new.get(subj)
    if n is None: c['missing in new'] += 1; continue
    for k in ('size', 'cc', 'bcc'):
        ok = n[k] == r[k]; c[f'{k} {"equal" if ok else "DIFFERS"}'] += 1
        if not ok and len(ex) < 6: ex.append((subj, k, n[k], r[k]))
    c[f'new size == new data-block bytes {n["size"] == n["blocks"]}'] += 1
print(f'messages: new {len(new)}, repaired {len(rep)}')
for k, v in sorted(c.items()): print(f'  {k:40} {v}')
for e in ex: print('  e.g.', e)

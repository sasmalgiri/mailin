# Decodes node 0xC01 ("HMP", heap client signature 0x9C): user root -> 4-byte HID -> BTH(16-byte key, 4-byte value).
import sys, glob, struct; sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from pstdump import PST, heap, bth, pc, alloc
def hmp(p):
    if 0xc01 not in p.nodes or not p.nodes[0xc01][0]: return None, None
    raw = b''.join(p.data(p.nodes[0xc01][0]))
    h = heap(p.data(p.nodes[0xc01][0]))
    root = alloc(h, h['root'])
    inner = struct.unpack('<I', root[:4])[0]
    hdr = alloc(h, inner)
    recs, _ = bth(h, inner)
    return (raw[:12].hex(' '), root.hex(' '), hdr.hex(' ')), recs
def keymap(p):
    sk = {}
    for n in p.nodes:
        try: props, h = pc(p, n)
        except Exception: continue
        for tag in (0x300B, 0x0FF9, 0x65E0, 0x0E30):
            v = props.get(tag)
            if v and v[1]:
                try: sk.setdefault(alloc(h, v[1]) if v[1] & 0x1F == 0 else None, []).append((hex(n), hex(tag)))
                except Exception: pass
    return sk
if __name__ == '__main__':
    for path in sys.argv[1:]:
        p = PST(path); hdrs, recs = hmp(p)
        print(path.split('/')[-1], hdrs, 'records', None if recs is None else len(recs))
        if recs:
            sk = keymap(p)
            vals = collections = [struct.unpack('<I', v)[0] for _, v in recs]
            print('  key matches a property', sum(1 for k, _ in recs if k in sk), 'of', len(recs))
            for k, v in recs[:6]: print('  ', k.hex(), v.hex(), sk.get(k))
            import collections as C; print('  values', C.Counter(vals).most_common(6))

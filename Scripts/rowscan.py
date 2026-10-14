# Emulates the SCANPST contents-table check as observed on real Outlook files:
# every cell a row holds must equal the message's own property, except the
# columns Outlook keeps only in tables (row id, row version, message status,
# change key). Prints mismatching rows per folder.
import sys, struct, glob
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from pstdump import PST, pc, alloc
import rowcheck

ROW_ONLY = {0x67F2, 0x67F3, 0x0E17, 0x3013}

def check(path, limit=None):
    p = PST(path)
    folders = sorted({p.nodes[m][2] for m in p.nodes if m & 0x1F == 4})
    total = bad = 0
    reasons = {}
    for f in folders:
        cnid = (f >> 5) << 5 | 0xE
        if cnid not in p.nodes: continue
        cols, rgib, rows, h, sbid = rowcheck.table_rows(p, cnid)
        for row in rows[:limit]:
            rid = struct.unpack_from('<I', row, 0)[0]
            if rid not in p.nodes: continue
            props, mh = pc(p, rid)
            ceb = row[rgib[2]:]
            total += 1
            why = []
            for tag, ib, cb, ibit in cols:
                pid, ptype = tag >> 16, tag & 0xFFFF
                exists = (ceb[ibit // 8] >> (7 - ibit % 8)) & 1
                if pid in ROW_ONLY: continue
                has = pid in props
                if exists and not has: why.append(f'{tag:#x} only in row'); continue
                if not exists: continue
                pt, hn = props[pid]
                raw = int.from_bytes(row[ib:ib + cb], 'little')
                if ptype in (0x0003, 0x000B, 0x0002):
                    mask = (1 << (8 * cb)) - 1
                    if (hn & mask) != (raw & mask): why.append(f'{tag:#x} value')
                elif ptype in (0x0040, 0x0014):
                    if int.from_bytes(alloc(mh, hn), 'little') != raw: why.append(f'{tag:#x} value')
                elif ptype in (0x001F, 0x0102):
                    try:
                        rv = alloc(h, raw) if raw and raw & 0x1F == 0 else None
                        mv = alloc(mh, hn) if hn and hn & 0x1F == 0 else None
                        if rv is not None and mv is not None and rv != mv: why.append(f'{tag:#x} value')
                    except Exception:
                        pass
            if why:
                bad += 1
                for w in why: reasons[w] = reasons.get(w, 0) + 1
    print(f'{path.split("/")[-1][:40]:40} rows {total:5} mismatching {bad:5}  {dict(sorted(reasons.items(), key=lambda x: -x[1])[:6])}')

if __name__ == '__main__':
    for p in sys.argv[1:]:
        try: check(p)
        except Exception as e: print(p.split('/')[-1], 'skipped:', e)

# Contents-table diagnostic for a finished PST (not shipped).
#
# For every folder with messages it decodes the contents TC and checks:
#  1. TCINFO / TCOLDESC: column widths against the property type, offsets inside the
#     right size-class area of the row (rgib[TCI_4b], [TCI_2b], [TCI_1b], [TCI_bm]),
#     overlapping cells, unique existence bits, rowid/rowver fixed slots.
#  2. Row index (hidRowIndex BTH) <-> row matrix <-> NBT: each RowID once, row
#     index points at the row holding that RowID, each message whose nidParent is the
#     folder has a row and vice versa.
#  3. Each row against its message PC, per column: existence in row / in message,
#     decoded value (HNIDs resolved to heap or subnode, strings as UTF-16), equality.
#     Columns are classed as COPIED (template "Copied? = Y" and stored on messages),
#     TABLE-ONLY (row id/version, status, change key) or COMPUTED by the store.
import sys, struct, collections
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from pstdump import PST, heap, bth, alloc

FIXED = {0x0002: 2, 0x0003: 4, 0x0004: 4, 0x0005: 8, 0x0006: 8, 0x0007: 8, 0x000A: 4,
         0x000B: 1, 0x0014: 8, 0x0040: 8, 0x0048: 16}
TABLE_ONLY = {0x67F2, 0x67F3, 0x0E17, 0x3013}
COMPUTED = {0x0E03, 0x0E02, 0x0E1B, 0x0057, 0x0058}   # [MS-PST] 2.5.2.3 SPGET_* (or derived)

def tcinfo(h):
    t = alloc(h, h['root'])
    assert t[0] == 0x7C, 'not a TC'
    rgib = struct.unpack_from('<4H', t, 2)
    hidRowIndex, hnidRows = struct.unpack_from('<II', t, 10)
    cols = [struct.unpack_from('<IHBB', t, 22 + 8 * i) for i in range(t[1])]
    return rgib, hidRowIndex, hnidRows, cols

def check_descriptors(rgib, cols, errs, where):
    TCI_4b, TCI_2b, TCI_1b, TCI_bm = rgib
    bits = collections.Counter(c[3] for c in cols)
    for b, n in bits.items():
        if n > 1: errs.append(f'{where}: existence bit {b} used by {n} columns')
    spans = []
    for tag, ib, cb, bit in cols:
        ptype = tag & 0xFFFF
        want = FIXED.get(ptype, 4)
        if ptype in (0x0005, 0x0006, 0x0007, 0x0014, 0x0040, 0x0048) and cb == 4:
            want = 4  # 8+-byte types may be stored as an HNID
        if cb != want and not (ptype in (0x0040, 0x0014) and cb == 8):
            errs.append(f'{where}: column {tag:#010x} cb {cb}, type wants {want}')
        area = 'bm'
        if cb >= 4: lo, hi = 0, TCI_4b
        elif cb == 2: lo, hi = TCI_4b, TCI_2b
        else: lo, hi = TCI_2b, TCI_1b
        if not (lo <= ib and ib + cb <= hi):
            errs.append(f'{where}: column {tag:#010x} at {ib}+{cb} outside its size area [{lo},{hi})')
        spans.append((ib, ib + cb, tag))
        if tag == 0x67F20003 and (ib, bit) != (0, 0): errs.append(f'{where}: PidTagLtpRowId not at ib 0 / bit 0')
        if tag == 0x67F30003 and (ib, bit) != (4, 1): errs.append(f'{where}: PidTagLtpRowVer not at ib 4 / bit 1')
    spans.sort()
    for (a0, a1, ta), (b0, b1, tb) in zip(spans, spans[1:]):
        if b0 < a1: errs.append(f'{where}: cells overlap {ta:#010x} and {tb:#010x}')
    ncols_bits = (TCI_bm - TCI_1b) * 8
    if max(bits) >= ncols_bits: errs.append(f'{where}: existence bitmap too small ({ncols_bits} bits for bit {max(bits)})')

def resolve(p, h, subs, ptype, raw):
    """Decode a row cell / PC value. Returns (value, where)."""
    if ptype in (0x0003, 0x000B, 0x0002):
        return raw, 'inline'
    if ptype in (0x0040, 0x0014) and isinstance(raw, bytes):
        return int.from_bytes(raw, 'little'), 'inline8'
    hnid = raw
    if hnid == 0: return b'', 'empty'
    if hnid & 0x1F == 0:
        return alloc(h, hnid), 'heap'
    if hnid in subs:
        return b''.join(p.data(subs[hnid][0])), 'subnode'
    return None, f'dangling {hnid:#x}'

def message_values(p, nid):
    bd, bs, _ = p.nodes[nid]
    h = heap(p.data(bd)); recs, _ = bth(h, h['root'])
    subs = p.subnodes(bs) if bs else {}
    out = {}
    for k, v in recs:
        pid = struct.unpack_from('<H', k)[0]; pt, hn = struct.unpack_from('<HI', v)
        if pt in (0x0040, 0x0014):
            out[pid] = (pt, int.from_bytes(alloc(h, hn), 'little'), 'heap')
        else:
            val, where = resolve(p, h, subs, pt, hn)
            out[pid] = (pt, val, where)
    return out

def show(pt, v):
    if isinstance(v, bytes):
        if pt == 0x001F:
            try: return repr(v.decode('utf-16-le'))[:48]
            except Exception: return 'bad utf16 ' + v[:16].hex()
        return v[:20].hex() + ('…' if len(v) > 20 else '')
    return hex(v) if isinstance(v, int) else str(v)

def main(path, detail_rows=1):
    p = PST(path)
    folders = sorted({p.nodes[m][2] for m in p.nodes if m & 0x1F == 4})
    for f in folders:
        cnid = (f >> 5) << 5 | 0x0E
        errs = []
        bd, bs, _ = p.nodes[cnid]
        h = heap(p.data(bd)); subs = p.subnodes(bs) if bs else {}
        rgib, ri, hr, cols = tcinfo(h)
        check_descriptors(rgib, cols, errs, f'TC {cnid:#x}')
        # Row matrix.
        if hr and hr & 0x1F == 0: blocks = [alloc(h, hr)]
        elif hr: blocks = p.data(subs[hr][0])
        else: blocks = []
        rows = []
        for blk in blocks:
            for off in range(0, len(blk) - rgib[3] + 1, rgib[3]):
                rows.append(blk[off:off + rgib[3]])
        recs, _ = bth(h, ri) if ri else ([], None)
        index = {struct.unpack_from('<I', k)[0]: int.from_bytes(v, 'little') for k, v in recs}
        msgs = {m for m in p.nodes if m & 0x1F == 4 and p.nodes[m][2] == f}
        rowids = [struct.unpack_from('<I', r, 0)[0] for r in rows[:len(index)]]
        dup = [k for k, n in collections.Counter(rowids).items() if n > 1]
        if dup: errs.append(f'duplicate RowIDs {dup[:3]}')
        for rid, idx in index.items():
            if idx >= len(rows) or struct.unpack_from('<I', rows[idx], 0)[0] != rid:
                errs.append(f'row index {rid:#x} -> {idx} does not hold that RowID')
        if set(index) != msgs:
            errs.append(f'rows without message {sorted(set(index) - msgs)[:3]}, messages without row {sorted(msgs - set(index))[:3]}')
        # Cells vs messages.
        stats = collections.Counter(); first = []
        for n, (rid, idx) in enumerate(sorted(index.items(), key=lambda x: x[1])):
            row = rows[idx]; ceb = row[rgib[2]:rgib[3]]
            mv = message_values(p, rid)
            for tag, ib, cb, bit in sorted(cols):
                pid, pt = tag >> 16, tag & 0xFFFF
                exists = (ceb[bit // 8] >> (7 - bit % 8)) & 1
                raw = row[ib:ib + cb]
                if pt in (0x0040, 0x0014) and cb == 8: rv, rwhere = int.from_bytes(raw, 'little'), 'inline8'
                elif cb in (1, 2) or pt in (0x0003,):
                    rv, rwhere = int.from_bytes(raw, 'little'), 'inline'
                else: rv, rwhere = resolve(p, h, subs, pt, int.from_bytes(raw, 'little'))
                cls = 'TABLE-ONLY' if pid in TABLE_ONLY else ('COMPUTED' if pid in COMPUTED else 'COPIED')
                m = mv.get(pid)
                if not exists and m is None: state = 'absent both'
                elif exists and m is None: state = 'row only'
                elif not exists and m is not None: state = 'message only'
                else:
                    mval = m[1]
                    if pt == 0x000B: mval &= 0xFF; rv &= 0xFF
                    state = 'equal' if mval == rv else 'DIFFERENT'
                if rwhere.startswith('dangling'): state = 'ROW HNID ' + rwhere
                stats[(f'{tag:#010x}', cls, state)] += 1
                if n < detail_rows:
                    first.append(f'    {tag:#010x} {cls:10} {state:12} row[{rwhere}]={show(pt, rv) if exists else "-"}  msg={show(pt, m[1]) + " [" + m[2] + "]" if m else "-"}')
        print(f'folder {f:#x}  contents TC {cnid:#x}: rows {len(rows)} (index {len(index)}, messages {len(msgs)}), rgib {rgib}, columns {len(cols)}')
        for e in errs[:10]: print('  STRUCTURE:', e)
        if not errs: print('  structure: descriptors, row index, NBT references consistent')
        if first:
            print(f'  first row (RowID {sorted(index.items(), key=lambda x: x[1])[0][0]:#x}):'); print('\n'.join(first))
        print('  per column over all rows:')
        for (tag, cls, state), c in sorted(stats.items()):
            if state not in ('absent both',): print(f'    {tag} {cls:10} {state:24} {c}')

if __name__ == '__main__':
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 1)

# Compare each contents-table row's cells with its message PC (what SCANPST checks).
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
from pstdump import PST, pc, heap, bth, alloc

def table_rows(p, nid):
    dbid, sbid, _ = p.nodes[nid]
    h = heap(p.data(dbid))
    t = alloc(h, h['root'])
    ccols = t[1]
    rgib = struct.unpack_from('<4H', t, 2)
    rowidx, hnrows = struct.unpack_from('<II', t, 10)
    cols = [struct.unpack_from('<IHBB', t, 22 + 8 * i) for i in range(ccols)]
    # Row matrix: in a subnode (NID type) or a HID.
    if hnrows & 0x1F == 0 and hnrows:
        data = alloc(h, hnrows)
    else:
        subs = p.subnodes(sbid)
        bd, _ = subs[hnrows]
        data = b''.join(p.data(bd))
    rowsize = rgib[3]
    # Rows are stored per block of 8 KB in subnodes: rows never straddle blocks.
    out = []
    if hnrows & 0x1F == 0 and hnrows:
        blocks = [data]
    else:
        blocks = p.data(p.subnodes(sbid)[hnrows][0])
    for blk in blocks:
        for off in range(0, len(blk) - rowsize + 1, rowsize):
            out.append(blk[off:off + rowsize])
    return cols, rgib, out, h, sbid

def cell(row, col, rgib, h, p, sbid):
    tag, ib, cb, ibit = col
    ceb = row[rgib[3] - ((len_cols := None) or 0):] if False else None
    raw = row[ib:ib + cb]
    return raw

if __name__ == '__main__':
    p = PST(sys.argv[1])
    folder_contents = int(sys.argv[2], 16)
    which = [int(x) for x in sys.argv[3:]]
    cols, rgib, rows, h, sbid = table_rows(p, folder_contents)
    ncols = len(cols)
    cebStart = rgib[2]
    for r in which:
        row = rows[r]
        rowid = struct.unpack_from('<I', row, 0)[0]
        props, mh = pc(p, rowid)
        ceb = row[cebStart:]
        print(f'row {r} rowid {rowid:#x}')
        for tag, ib, cb, ibit in sorted(cols, key=lambda c: c[0]):
            exists = (ceb[ibit // 8] >> (7 - ibit % 8)) & 1
            pid, ptype = tag >> 16, tag & 0xFFFF
            raw = row[ib:ib + cb]
            v = int.from_bytes(raw, 'little')
            pv = props.get(pid)
            note = ''
            if pv is None:
                note = 'NOT IN MESSAGE' if exists else 'absent both'
            else:
                pt, hn = pv
                if ptype in (0x0003, 0x000B):
                    note = 'same' if (hn & (0xFF if ptype == 0x0B else 0xFFFFFFFF)) == (v & (0xFF if ptype == 0x0B else 0xFFFFFFFF)) else f'DIFFERENT (msg {hn:#x})'
                elif ptype == 0x0040:
                    mv = int.from_bytes(alloc(mh, hn), 'little')
                    note = 'same' if mv == v else f'DIFFERENT (msg {mv:#x} row {v:#x})'
                elif ptype == 0x001F:
                    try:
                        rv = alloc(h, v).decode('utf-16-le') if v and v & 0x1F == 0 else '(subnode)'
                    except Exception: rv = '?'
                    try:
                        mv = alloc(mh, hn).decode('utf-16-le') if hn and hn & 0x1F == 0 else '(subnode)'
                    except Exception: mv = '?'
                    note = 'same' if rv == mv else f'DIFFERENT row={rv[:40]!r} msg={mv[:40]!r}'
            print(f'   {tag:#010x} exists={exists} {note}')

# Independent validation of mailin's PST fixtures (not shipped). Expected values are
# regenerated here from the fixture definitions in PSTSpecWriterTests.swift, not read
# from mailin. Decoders: libpff (pypff), libpst (readpst), and the Python [MS-PST]
# decoder pstdump.py, which shares no code with the Swift reader or writer.
import sys, os, struct, subprocess, hashlib, json, collections
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import pypff
from pstdump import PST, heap, bth, alloc
import pstvalidate, pstltp, rowscan

UNI = "Résumé — naïve façade ✓ Ελληνικά 日本語 עברית 🙂"

def variant(i, to=("Ann <ann@example.org>",), cc=(), bcc=(), subject=None, body=None, html="", atts=()):
    return dict(mid=f"<v{i}@example.com>", subject=subject or f"Message {i}", body=body or f"Body of message {i}.",
                html=html, to=list(to), cc=list(cc), bcc=list(bcc),
                atts=[(n, bytes(((j * 31 + i) & 0xFF) for j in range(sz))) for n, sz in atts])

def fixtures():
    yield '01-empty-store', []
    yield '02-one-plain-message', [variant(1)]
    yield '03-recipients-to-cc-bcc', [variant(2, to=["Ann <ann@example.org>", "bob@example.org", "Chloé Durand <chloe@example.fr>"],
                                               cc=["Cara <cara@example.net>", "dan@example.net"], bcc=["hidden@example.net", "Eve <eve@example.com>"])]
    yield '04-html-and-unicode', [variant(3, subject=UNI, body=UNI + "\nSecond line.", html=f"<p>{UNI}</p>")]
    yield '05-attachments-small-and-multiblock', [variant(4, atts=[("small.txt", 40), ("two-blocks.bin", 12000), ("many-blocks.bin", 300000)])]
    yield '06-crosses-table-and-heap-blocks', [variant(100 + k, subject=f"Boundary {k} " + "x" * 60) for k in range(300)]

def full1k():
    out = []
    for i in range(1000):
        long = (f"Long paragraph {i} for the body. " * 400) if i % 25 == 0 else ""
        body = f"Hello number {i}.\n{long}Regards,\nSender {i % 30}"
        atts = []
        if i % 10 == 0:
            n = 20000 if i % 40 == 0 else 300
            atts = [(f"file-{i}.bin", bytes(((j * 7 + i) & 0xFF) for j in range(n)))]
        cc = ["Cara <cara@example.net>"] if i % 3 == 0 else []
        bcc = ["hidden@example.net"] if i % 7 == 0 else []
        out.append(dict(mid=f"<w{i}@example.com>", subject=f"Subject {i} — résumé ✓", body=body,
                        html=f"<p>Hello <b>{i}</b></p>" if i % 4 == 0 else "", to=["Ann <ann@example.org>", "bob@example.org"],
                        cc=cc, bcc=bcc, atts=atts, folder='Inbox' if i % 5 == 0 else 'mailin export'))
    return out

def addr(s):
    s = s.strip()
    if '<' in s: return s[s.index('<') + 1:s.index('>')].lower()
    return s.lower()

def recipients_pstdump(p, nid):
    bd, bs, _ = p.nodes[nid]
    subs = p.subnodes(bs)
    rbd, rbs = subs[0x692]
    h = heap(p.data(rbd)); t = alloc(h, h['root'])
    rg = struct.unpack_from('<4H', t, 2); hr = struct.unpack_from('<I', t, 14)[0]
    cols = {c[0]: c for c in (struct.unpack_from('<IHBB', t, 22 + 8 * i) for i in range(t[1]))}
    data = alloc(h, hr) if hr and hr & 0x1F == 0 else (b''.join(p.data(p.subnodes(rbs)[hr][0])) if hr else b'')
    out = collections.defaultdict(list)
    for off in range(0, len(data) - rg[3] + 1, rg[3]):
        row = data[off:off + rg[3]]
        kind = struct.unpack_from('<I', row, cols[0x0C150003][1])[0]
        hn = struct.unpack_from('<I', row, cols[0x3003001F][1])[0]
        out[kind].append(alloc(h, hn).decode('utf-16-le').lower())
    return out

def check(path, expected, expect_folders=None):
    rep = {'file': os.path.basename(path), 'sha256': hashlib.sha256(open(path, 'rb').read()).hexdigest(), 'problems': []}
    P = rep['problems']
    # Structure (strict NDB, LTP, rows): capture their printed verdicts.
    import io, contextlib
    for mod, fn in ((pstvalidate, pstvalidate.main), (pstltp, pstltp.main), (rowscan, rowscan.check)):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf): fn(path)
        txt = buf.getvalue()
        ok = ('no errors 0' in txt) if mod is pstvalidate else (('errors 0' in txt) if mod is pstltp else ('mismatching     0' in txt))
        rep[mod.__name__] = 'pass' if ok else 'FAIL'
        if not ok: P.append(f'{mod.__name__}: ' + txt.strip().replace('\n', ' | ')[:300])
    # libpff: every message, folder counts, subject/body/html/attachment bytes.
    f = pypff.file(); f.open(path)
    seen = {}; counts = collections.Counter()
    def walk(fold, name):
        for i in range(fold.number_of_sub_messages):
            m = fold.get_sub_message(i); counts[name] += 1
            atts = []
            for j in range(m.number_of_attachments):
                a = m.get_attachment(j); atts.append(a.read_buffer(a.size))
            ident = (m.transport_headers or '')
            seen.setdefault(m.subject, []).append(dict(body=m.plain_text_body, html=m.html_body, atts=atts, folder=name, id=m.identifier))
        for i in range(fold.number_of_sub_folders):
            s = fold.get_sub_folder(i); walk(s, s.name)
    walk(f.get_root_folder(), '')
    p = PST(path)
    nid_by_subject = {}
    for nid in [n for n in p.nodes if n & 0x1F == 4]:
        nid_by_subject.setdefault(None, None)
    for e in expected:
        got = seen.get(e['subject'], [])
        if len(got) != 1: P.append(f"{e['mid']}: found {len(got)} times by subject"); continue
        g = got[0]
        body = (g['body'] or b'').decode('utf-8', 'replace') if isinstance(g['body'], bytes) else (g['body'] or '')
        if body.replace('\r\n', '\n') != e['body']: P.append(f"{e['mid']}: body differs ({len(body)} vs {len(e['body'])})")
        if e['html']:
            html = (g['html'] or b'').decode('utf-8', 'replace') if isinstance(g['html'], bytes) else (g['html'] or '')
            if e['html'] not in html: P.append(f"{e['mid']}: html differs")
        if [a for _, a in e['atts']] != g['atts']: P.append(f"{e['mid']}: attachment bytes differ ({[len(a) for a in g['atts']]})")
        if 'folder' in e and g['folder'] != e['folder']: P.append(f"{e['mid']}: in folder {g['folder']}")
        # Recipients through the independent Python decoder.
        rec = recipients_pstdump(p, g['id'])
        for kind, lst in ((1, e['to']), (2, e['cc']), (3, e['bcc'])):
            if sorted(addr(x) for x in lst) != sorted(rec.get(kind, [])): P.append(f"{e['mid']}: recipients type {kind} {rec.get(kind)} vs {lst}")
    rep['messages'] = sum(counts.values()); rep['folders'] = dict(counts)
    if expect_folders and dict((k, v) for k, v in counts.items() if v) != expect_folders: P.append(f'folders {dict(counts)}')
    if sum(len(v) for v in seen.values()) != len(expected): P.append(f'libpff sees {sum(len(v) for v in seen.values())} messages, expected {len(expected)}')
    # libpst.
    out = '/tmp/rp-' + rep['file']
    subprocess.run(['rm', '-rf', out]); os.makedirs(out)
    r = subprocess.run(['readpst', '-q', '-o', out, '-S', '-j0', path], capture_output=True, text=True)
    files = sum(len(fs) for _, _, fs in os.walk(out))
    nat = sum(len(e['atts']) for e in expected)
    rep['readpst'] = f'exit {r.returncode}, {files} files (expected {len(expected) + nat})'
    if r.returncode != 0 or files != len(expected) + nat: P.append('readpst: ' + rep['readpst'])
    rep['verdict'] = 'PASS' if not P else 'FAIL'
    return rep

if __name__ == '__main__':
    reports = []
    for name, exp in fixtures():
        reports.append(check(f'/tmp/pstfix/{name}.pst', exp))
    reports.append(check(sys.argv[1] if len(sys.argv) > 1 else '/tmp/mailin-spec-1k.pst', full1k(), {'mailin export': 800, 'Inbox': 200}))
    for r in reports:
        print(f"{r['verdict']:4} {r['file']:42} msgs {r['messages']:5} ndb {r['pstvalidate']} ltp {r['pstltp']} rows {r['rowscan']} readpst {r['readpst']}")
        for pr in r['problems'][:6]: print('       ', pr)
    json.dump(reports, open('/tmp/pstfix/validation.json', 'w'), indent=1)

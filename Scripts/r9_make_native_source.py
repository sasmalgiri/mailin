#!/usr/bin/env python3
"""R9 (native mail half): the synthetic source mbox that is imported into Apple Mail
(File > Import Mailboxes...) and exported back with Mailbox > Export Mailbox..., so the
fixture pack holds an mbox WRITTEN BY APPLE MAIL (owner permission 2026-11-09).

  Scripts/r9_make_native_source.py [<out dir>]   (default /tmp/r9-native)

Writes <out>/source/R9-native.mbox (six made-up messages: Unicode subjects, one HTML body,
PDF / PNG / CSV / UTF-8-named attachments, a reply) and <out>/source-inventory.json
(Message-ID, subject, attachment names + SHA-256 of the bytes). No personal data.
"""
import base64, hashlib, json, os, sys, email.utils

out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/r9-native"
os.makedirs(os.path.join(out, "source"), exist_ok=True)

def pdf():
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"]
    stream = "BT /F1 16 Tf 20 50 Td (mailin R9 native) Tj ET"
    objs.append(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
    objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    s, offs = "%PDF-1.4\n", []
    for i, o in enumerate(objs):
        offs.append(len(s.encode())); s += f"{i+1} 0 obj\n{o}\nendobj\n"
    x = len(s.encode())
    s += f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offs)
    s += f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n"
    return s.encode()

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
CSV = "id,city,amount\r\n1,München,12.50\r\n2,東京,7.00\r\n3,दिल्ली,3.25\r\n".encode()
NOTE = "Notiz für die Ablage – R9.\n".encode()

def enc(s):
    return s if s.isascii() else "=?UTF-8?B?" + base64.b64encode(s.encode()).decode() + "?="

def message(n, subject, parts=(), html=None, reply_to=None):
    mid = f"<r9-native-{n:02d}@mailin.example.invalid>"
    date = f"Mon, 0{n} Nov 2026 09:{n:02d}:00 +0000"
    h = [f"From: Native Sender <native@r9.mailin.example.invalid>", "To: Archive Owner <owner@r9.mailin.example.invalid>",
         f"Subject: {enc(subject)}", f"Date: {date}", f"Message-ID: {mid}"]
    if reply_to:
        h += [f"In-Reply-To: {reply_to}", f"References: {reply_to}"]
    h.append("MIME-Version: 1.0")
    plain = f"Synthetic native-mail message {n} (R9). Ünïcödé: äöü – हिन्दी – 日本語.\r\n"
    text = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" + plain
    if html:
        text = ("Content-Type: multipart/alternative; boundary=\"R9ALT\"\r\n\r\n--R9ALT\r\n" + text +
                "--R9ALT\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" + html + "\r\n--R9ALT--\r\n")
    if not parts:
        body = text
    else:
        h.append("Content-Type: multipart/mixed; boundary=\"R9MIX\"")
        body = "--R9MIX\r\n" + text
        for name, mime, data in parts:
            fn = name if name.isascii() else "UTF-8''" + "".join(c if c.isascii() and c.isalnum() or c in ".-_" else "".join(f"%{b:02X}" for b in c.encode()) for c in name)
            disp = f'filename="{name}"' if name.isascii() else f"filename*={fn}"
            body += (f"--R9MIX\r\nContent-Type: {mime}; name=\"{enc(name)}\"\r\nContent-Transfer-Encoding: base64\r\n"
                     f"Content-Disposition: attachment; {disp}\r\n\r\n" + base64.encodebytes(data).decode().replace("\n", "\r\n"))
        body += "--R9MIX--\r\n"
    head = "\r\n".join(h) + "\r\n"
    # Without attachments the text part's own Content-Type headers continue the header block.
    raw = head + "\r\n" + body if parts else head + body
    entry = {"messageID": mid, "subject": subject, "date": date,
             "attachments": [{"name": nm, "mime": m, "bytes": len(d), "sha256": hashlib.sha256(d).hexdigest()} for nm, m, d in parts]}
    return raw, entry

msgs = [
    message(1, "R9 native: Grüße aus Köln", parts=[("r9-report.pdf", "application/pdf", pdf())]),
    message(2, "R9 native: 写真と表", parts=[("r9-photo.png", "image/png", PNG), ("r9-table.csv", "text/csv", CSV)]),
    message(3, "R9 native: HTML body", html="<html><body><p>R9 <b>HTML</b> – 日本語</p></body></html>"),
    message(4, "Re: R9 native: Grüße aus Köln", reply_to="<r9-native-01@mailin.example.invalid>"),
    message(5, "R9 native: नोट संलग्न", parts=[("Notiz-Ablage-ü.txt", "text/plain", NOTE)]),
    message(6, "R9 native: plain ASCII"),
]

with open(os.path.join(out, "source", "R9-native.mbox"), "wb") as f:
    for raw, e in msgs:
        when = email.utils.parsedate_to_datetime(e["date"]).strftime("%a %b %d %H:%M:%S %Y")
        f.write(f"From native@r9.mailin.example.invalid {when}\n".encode())
        data = raw.replace("\r\n", "\n").encode()
        lines = [(b">" + l) if l.lstrip(b">").startswith(b"From ") else l for l in data.split(b"\n")]
        f.write(b"\n".join(lines).rstrip(b"\n") + b"\n\n")
json.dump([e for _, e in msgs], open(os.path.join(out, "source-inventory.json"), "w"), ensure_ascii=False, indent=2)
print(f"{len(msgs)} messages -> {out}/source/R9-native.mbox")

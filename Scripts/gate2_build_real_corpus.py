#!/usr/bin/env python3
"""Gate 2: build a REAL >= 100 MB corpus from Enron custodian maildirs (CMU enron_mail_20150507),
in the formats the 100 MB matrix covers, with an independent manifest (Python only, no mailin code).

  Scripts/gate2_build_real_corpus.py <out dir> <custodian dir> [<custodian dir> ...]

Writes into <out dir>:
  eml/<custodian>/<folder...>/<file>  hard links to the original files (the bytes unchanged)
  enron.mbox                         every message, RFC 4155 mboxrd: a From_ line per record,
                                     lines matching ^>*From  gain one '>', CRLF kept as in the files
  enron-maildir.zip                  the eml/ tree, deflated (Python zipfile)
  manifest.json                      independent inventory: total, per-folder counts, Message-IDs,
                                     search phrases with the Message-IDs that contain them,
                                     content-equivalence groups (From/To/Cc/Bcc/Date/Subject/body)
Nothing in a message is modified; the only bytes added are mbox framing and >From quoting.
"""
import email, hashlib, json, os, re, sys, time, zipfile
from email import policy
from email.utils import parsedate_to_datetime, getaddresses

out, custodians = sys.argv[1], sys.argv[2:]
eml_root = os.path.join(out, "eml")
os.makedirs(eml_root, exist_ok=True)

files = []  # (relative path under eml/, absolute source)
for c in custodians:
    c = os.path.abspath(c)
    name = os.path.basename(c.rstrip("/"))
    for d, dirs, fs in os.walk(c):
        dirs.sort()
        for f in sorted(fs):
            if f.startswith("."):
                continue
            src = os.path.join(d, f)
            if not os.path.isfile(src):
                continue
            rel = os.path.join(name, os.path.relpath(src, c))
            files.append((rel, src))

# 1. eml/ as hard links (same inode, same bytes).
for rel, src in files:
    dst = os.path.join(eml_root, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(dst):
        os.link(src, dst)

FROM_LINE = re.compile(rb"^(>*)From ", re.M)
def addrs(v):
    return ";".join(sorted(a.lower() for _, a in getaddresses([v or ""]) if a))
def norm_body(b):
    return b.replace(b"\r\n", b"\n").strip()

per_folder, ids, by_content = {}, [], {}
records = []  # per message: id, folder, subject, body text (lower) for phrase search
mbox_path = os.path.join(out, "enron.mbox")
total_bytes = 0
with open(mbox_path, "wb") as mb:
    for rel, src in files:
        raw = open(src, "rb").read()
        total_bytes += len(raw)
        folder = os.path.dirname(rel)
        per_folder[folder] = per_folder.get(folder, 0) + 1
        m = email.message_from_bytes(raw, policy=policy.compat32)
        mid = (m.get("Message-ID") or "").strip()
        ids.append(mid)
        try:
            dt = parsedate_to_datetime(m.get("Date"))
            env_date = dt.strftime("%a %b %d %H:%M:%S %Y")
            date_key = str(int(dt.timestamp()))
        except Exception:
            env_date, date_key = "Thu Jan  1 00:00:00 1970", (m.get("Date") or "").strip()
        sender = (getaddresses([m.get("From") or ""]) or [("", "")])[0][1] or "MAILER-DAEMON"
        # mboxrd record: From_ line, the message with ^>*From  quoted, a blank line.
        body = FROM_LINE.sub(lambda x: b">" + x.group(1) + b"From ", raw)
        if not body.endswith(b"\n"):
            body += b"\r\n"
        mb.write(f"From {sender} {env_date}\r\n".encode() + body + b"\r\n")
        sep = raw.find(b"\r\n\r\n")
        payload = raw[sep + 4:] if sep >= 0 else b""
        key = "|".join([addrs(m.get("From")), addrs(m.get("To")), addrs(m.get("Cc")), addrs(m.get("Bcc")),
                        date_key, " ".join((m.get("Subject") or "").split()),
                        hashlib.sha256(norm_body(payload)).hexdigest()])
        by_content.setdefault(key, []).append(mid)
        # Search text = the body as a reader shows it: decoded per Content-Transfer-Encoding
        # (376 Enron messages are quoted-printable; "PG=\r\nE" is "PGE", not "PG E").
        text = b"".join((part.get_payload(decode=True) or b"") for part in m.walk()
                        if not part.is_multipart()).decode("latin-1")
        records.append((mid, folder, " ".join((m.get("Subject") or "").split()), text))

# 2. ZIP of the eml/ tree.
zip_path = os.path.join(out, "enron-maildir.zip")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    for rel, src in files:
        z.write(src, os.path.join("enron-maildir", rel))

# 3. Search phrases: chosen words and phrases from real messages; the expected set is every
#    message whose subject or body contains the phrase as whole words (case-insensitive).
phrases = ["Vince Kaminski", "weather derivatives", "value at risk", "California", "PG&E",
           "Black-Scholes", "Stinson Gibner", "Dabhol", "real options", "Wharton", "FERC", "Duffie"]
search = {}
for p in phrases:
    words = re.findall(r"[A-Za-z0-9]+", p)
    rx = re.compile(r"\b" + r"[^A-Za-z0-9]+".join(map(re.escape, words)) + r"\b", re.I)
    hit = sorted(mid for mid, _, subj, text in records if rx.search(subj) or rx.search(text))
    search[p] = hit

groups = [sorted(v) for v in by_content.values() if len(v) > 1]
manifest = {
    "source": "CMU Enron enron_mail_20150507, custodians " + ", ".join(os.path.basename(c.rstrip("/")) for c in custodians),
    "built": time.strftime("%Y-%m-%d %H:%M:%S %z"),
    "files": len(files), "sourceBytes": total_bytes,
    "mboxBytes": os.path.getsize(mbox_path), "zipBytes": os.path.getsize(zip_path),
    "distinctMessageIDs": len(set(ids)), "emptyMessageIDs": sum(1 for i in ids if not i),
    "folders": per_folder,
    "search": search,
    "contentGroups": groups,
    "contentGroupCopies": sum(len(g) for g in groups),
}
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
print(f"{len(files)} messages, {total_bytes:,} source bytes, {len(per_folder)} folders, "
      f"{len(set(ids))} distinct Message-IDs; mbox {manifest['mboxBytes']:,} B; zip {manifest['zipBytes']:,} B; "
      f"{len(groups)} content-equivalence groups ({manifest['contentGroupCopies']} copies)")
for p, hit in search.items():
    print(f"  search {p!r}: {len(hit)}")

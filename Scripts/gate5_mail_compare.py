#!/usr/bin/env python3
"""OUT-05 / gate 5: compare what Apple Mail holds after File > Import Mailboxes
with inventory.json.

Inputs (under the gate-5 folder, default /tmp/mailin-gate5):
  mail-readback.tsv  from gate5_mail_readback.applescript (Mail's dictionary:
                     message count, message id, subject, mail attachment names)
  mail-saved/        from gate5_mail_save_attachments.applescript (attachments
                     saved by Mail, and each message's source as Mail stores it)
Checks per imported mailbox: count, Message-ID set, subject, attachment names
and SHA-256 of the bytes Mail saved, HTML part and In-Reply-To in Mail's source.
"""
import email, glob, hashlib, json, os, sys
from email import policy

root = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mailin-gate5"
inv = json.load(open(os.path.join(root, "inventory.json")))
by_id = {e["messageID"].strip("<>"): e for e in inv}
expected = {"Inbox": {k for k, e in by_id.items() if e["folder"] == "Inbox"},
            "Projects": {k for k, e in by_id.items() if e["folder"] == "Projects"},
            "mailin-handoff-0001": set(by_id)}

boxes, rows = {}, {}
for line in open(os.path.join(root, "mail-readback.tsv"), encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if f[0] == "#MAILBOX":
        boxes[f[1]] = int(f[2]); rows[f[1]] = []
    elif len(f) >= 3:
        rows[f[0]].append(f)

ok = True
for box, ids in expected.items():
    problems = []
    if boxes.get(box) != len(ids):
        problems.append(f"Mail count {boxes.get(box)} != {len(ids)}")
    seen = set()
    for f in rows.get(box, []):
        mid, subject = f[1].strip("<>"), f[2]
        names = [n for n in (f[3].split("|") if len(f) > 3 and f[3] else [])]
        e = by_id.get(mid)
        if not e:
            problems.append(f"unknown id {mid}"); continue
        seen.add(mid)
        if subject != e["subject"]:
            problems.append(f"{mid} subject {subject!r} != {e['subject']!r}")
        want = {a["name"]: a["sha256"] for a in e["attachments"]}
        if sorted(names) != sorted(want):
            problems.append(f"{mid} attachment names {names} != {sorted(want)}")
        for n, sha in want.items():
            p = os.path.join(root, "mail-saved", box, f"{mid}__{n}")
            got = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else None
            if got != sha:
                problems.append(f"{mid} {n} sha256 {got} != {sha}")
        src = os.path.join(root, "mail-saved", box, f"{mid}.source.eml")
        with open(src, "rb") as fh:
            m = email.message_from_binary_file(fh, policy=policy.default)
        if e["html"] and not any(p.get_content_type() == "text/html" for p in m.walk()):
            problems.append(f"{mid} Mail's source has no text/html part")
        if e.get("inReplyTo") and (m["In-Reply-To"] or "").strip() != e["inReplyTo"]:
            problems.append(f"{mid} In-Reply-To {m['In-Reply-To']!r}")
    missing = sorted(ids - seen)
    good = not problems and not missing
    ok &= good
    print(f"Apple Mail Import/{box}: {boxes.get(box)} messages, {len(seen & ids)} of {len(ids)} matched; "
          f"missing={missing}; problems={problems} -> {'OK' if good else 'MISMATCH'}")
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)

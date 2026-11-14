#!/usr/bin/env python3
"""R9 (native half), independent of mailin: Python's mailbox/email read the Apple-Mail-written
mbox and the derived .eml set and compare Message-ID, decoded subject and attachment names +
SHA-256 with source/source-inventory.json.
  Scripts/r9_native_check.py [<fixture root>]   (default ~/Downloads/Mail/Fixtures)"""
import email, hashlib, json, mailbox, os, sys, glob
from email import policy

root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Downloads/Mail/Fixtures")
pack = os.path.join(root, "owner-pack", "native")
inv = {e["messageID"]: (e["subject"], sorted((a["name"], a["sha256"]) for a in e["attachments"]))
       for e in json.load(open(os.path.join(pack, "source", "source-inventory.json"), encoding="utf-8"))}

def summary(msg):
    atts = sorted((p.get_filename(), hashlib.sha256(p.get_payload(decode=True)).hexdigest())
                  for p in msg.walk() if p.get_filename())
    return msg["Message-ID"].strip(), (str(msg["Subject"]), atts)

def read_mbox(path):
    return dict(summary(email.message_from_bytes(m.as_bytes(), policy=policy.default))
                for m in mailbox.mbox(path))

def read_eml(d):
    return dict(summary(email.message_from_bytes(open(f, "rb").read(), policy=policy.default))
                for f in sorted(glob.glob(os.path.join(d, "*.eml"))))

ok = True
for label, got in [("Apple Mail mbox", read_mbox(os.path.join(pack, "apple-mail-export", "R9-native.mbox", "mbox"))),
                   (".eml set", read_eml(os.path.join(pack, "eml")))]:
    bad = [k for k in set(inv) | set(got) if inv.get(k) != got.get(k)]
    print(f"{label}: {len(got)} messages, {sum(len(v[1]) for v in got.values())} attachments, {len(bad)} mismatches")
    for k in bad:
        print("  ", k, inv.get(k), "!=", got.get(k)); ok = False
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)

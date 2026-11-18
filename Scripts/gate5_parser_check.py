#!/usr/bin/env python3
"""OUT-05 / gate 5 independent parser check.

Reads the export written by MailClientHandoffFixtureTests (MAILIN_GATE5_OUT,
default /tmp/mailin-gate5) with Python's own `mailbox` / `email` packages —
not mailin's parser — and compares every message with inventory.json:
Message-ID, decoded subject, attachment names + SHA-256 of the decoded bytes,
HTML part present, In-Reply-To. Exit 0 only when every file set matches.
"""
import email, glob, hashlib, json, mailbox, os, sys
from email import policy

root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("MAILIN_GATE5_OUT", "/tmp/mailin-gate5")
inv = json.load(open(os.path.join(root, "inventory.json")))
by_id = {e["messageID"]: e for e in inv}
normalised = []


def parse(fp):
    return email.message_from_binary_file(fp, policy=policy.default)


def check(msgs, label, ids):
    seen, problems = set(), []
    for m in msgs:
        mid = (m["Message-ID"] or "").strip()
        e = by_id.get(mid)
        if not e:
            problems.append(f"unknown Message-ID {mid!r}")
            continue
        if mid in seen:
            problems.append(f"{mid} twice")
        seen.add(mid)
        got_subject = "" if m["subject"] is None else str(m["subject"])
        if got_subject != e["subject"]:
            # 2026-11-18 (real mail): mailin's record keeps a subject with whitespace runs collapsed
            # and ends trimmed (RFC 5322 unfolding keeps the folding whitespace), and shows a missing
            # Subject as "(No Subject)". Those differences are counted, not hidden; anything else fails.
            norm = lambda x: " ".join(x.split())
            if norm(got_subject) == norm(e["subject"]) or (not got_subject and e["subject"] == "(No Subject)"):
                normalised.append(mid)
            else:
                problems.append(f"{mid} subject {got_subject!r} != {e['subject']!r}")
        # An attachment = a leaf part with a file name or an attachment disposition (real mail
        # names inline images and zips with Content-Disposition: inline; filename=…).
        atts = {p.get_filename(): hashlib.sha256(p.get_payload(decode=True) or b"").hexdigest()
                for p in m.walk() if not p.is_multipart()
                and (p.get_content_disposition() == "attachment" or p.get_filename())}
        want = {a["name"]: a["sha256"] for a in e["attachments"]}
        if atts != want:
            problems.append(f"{mid} attachments {atts} != {want}")
        if e["html"] and not any(p.get_content_type() == "text/html" for p in m.walk()):
            problems.append(f"{mid} has no text/html part")
        if e.get("inReplyTo") and (m["In-Reply-To"] or "").strip() != e["inReplyTo"]:
            problems.append(f"{mid} In-Reply-To {m['In-Reply-To']!r}")
    missing = sorted(ids - seen)
    ok = not problems and not missing and len(msgs) == len(ids)
    print(f"{label}: {len(msgs)} parsed, {len(seen & ids)} of {len(ids)} matched; "
          f"missing={missing}; problems={problems} -> {'OK' if ok else 'MISMATCH'}")
    return ok


def mbox(path):
    return list(mailbox.mbox(path, factory=parse, create=False))


all_ids = set(by_id)
ok = check([m for p in sorted(glob.glob(os.path.join(root, "mailin-handoff", "*.mbox"))) for m in mbox(p)],
           "mailin-handoff/*.mbox", all_ids)
for folder in sorted({e["folder"] for e in inv}):
    ok &= check(mbox(os.path.join(root, "folders", f"{folder}.mbox")), f"folders/{folder}.mbox",
                {e["messageID"] for e in inv if e["folder"] == folder})
emls = []
for p in sorted(glob.glob(os.path.join(root, "eml", "*.eml"))):
    with open(p, "rb") as f:
        emls.append(parse(f))
ok &= check(emls, "eml/*.eml", all_ids)
if normalised:
    print(f"subject normalisation only (whitespace collapsed / missing Subject shown as '(No Subject)'): "
          f"{len(set(normalised))} messages")
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)

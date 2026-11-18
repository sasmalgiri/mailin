#!/usr/bin/env python3
"""Gate 5, real-message run: select REAL messages for the Thunderbird hand-off (bytes unchanged).

  Scripts/gate5_real_source.py <out dir> [<fixture root>]      (root default ~/Downloads/Mail/Fixtures)

  <out>/enron-<custodian>-<folder>/<file>   hard links to Enron files (CMU enron_mail_20150507;
                                            that release carries no attachments)
  <out>/tbird-<mailbox>/<n>.eml             messages from Digital Corpora "filetypes1" Thunderbird
                                            mailboxes (real mail WITH attachments), each record
                                            written as it is in the mbox minus the From_ line, with
                                            mboxrd >From unquoting (the container's framing only)
Messages without a Message-ID, with a Message-ID already selected, or marked expunged by
Thunderbird (X-Mozilla-Status 0x0008) are left out, so every selected message is one distinct
row in every client. Prints what was selected.
"""
import email, os, re, sys
from email import policy

out = sys.argv[1]
root = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/Downloads/Mail/Fixtures")
os.makedirs(out, exist_ok=True)
seen = set()

def mid_of(raw):
    m = re.search(rb"^Message-ID:[ \t]*(.*?)\r?$", raw.split(b"\r\n\r\n", 1)[0].split(b"\n\n", 1)[0], re.I | re.M)
    return m.group(1).strip().decode("latin-1") if m else ""

enron = [("kaminski-v", "inbox", 120), ("kaminski-v", "discussion_threads", 90), ("dasovich-j", "sent", 90)]
for cust, folder, n in enron:
    src = os.path.join(root, "enron/maildir", cust, folder)
    dst = os.path.join(out, f"enron-{cust}-{folder}")
    os.makedirs(dst, exist_ok=True)
    picked = 0
    for f in sorted(os.listdir(src), key=lambda s: int(s.rstrip(".")) if s.rstrip(".").isdigit() else 1 << 30):
        p = os.path.join(src, f)
        if not os.path.isfile(p):
            continue
        mid = mid_of(open(p, "rb").read())
        if not mid or mid in seen:
            continue
        seen.add(mid)
        os.link(p, os.path.join(dst, f))
        picked += 1
        if picked == n:
            break
    print(f"enron {cust}/{folder}: {picked}")

FROM_ = re.compile(rb"^>(>*From )", re.M)
tb = ["Tbird_4483S2010G3_Rebecca_pop3live_inbox", "Tbird_M57_Charlie_inbox", "Tbird_M57_Charlie_sent",
      "Tbird_4483S2011G4_Administrator_imapmail_sent", "Tbird_4483S2010G2_Administrator_csdhbzq2_allmail2"]
for name in tb:
    data = open(os.path.join(root, "digitalcorpora/Tbird/Tbird", name), "rb").read()
    starts = [m.start() for m in re.finditer(rb"(?:^|\n)From [^\n]*\n", data)]
    dst = os.path.join(out, "tbird-" + name.replace("Tbird_", "").replace("_", "-").lower())
    os.makedirs(dst, exist_ok=True)
    picked = skipped = 0
    for i, s in enumerate(starts):
        rec = data[s:starts[i + 1] if i + 1 < len(starts) else len(data)].lstrip(b"\n")
        body = rec.split(b"\n", 1)[1]
        if body.endswith(b"\n\n"):
            body = body[:-1]  # the blank line before the next From_ belongs to the container
        body = FROM_.sub(rb"\1", body)
        msg = email.message_from_bytes(body, policy=policy.compat32)
        status = (msg.get("X-Mozilla-Status") or "").strip()
        expunged = bool(re.fullmatch(r"[0-9A-Fa-f]{4}", status)) and int(status, 16) & 0x0008
        mid = (msg.get("Message-ID") or "").strip()
        if expunged or not mid or mid in seen:
            skipped += 1
            continue
        seen.add(mid)
        picked += 1
        open(os.path.join(dst, f"{picked:03d}.eml"), "wb").write(body)
    print(f"tbird {name}: {picked} (left out {skipped}: expunged / no or repeated Message-ID)")
print(f"total {len(seen)} messages in {out}")

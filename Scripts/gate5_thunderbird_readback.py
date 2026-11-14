#!/usr/bin/env python3
"""OUT-05 / gate 5, second client: read back what THUNDERBIRD holds after mailin's export was
placed in a throwaway profile's Local Folders (Scripts/gate5_thunderbird_profile.sh), and compare
it with mailin's inventory.json.

Thunderbird is started by the caller with Marionette on localhost only:
  thunderbird -P mailin-test -no-remote -offline --marionette --remote-allow-system-access
This script talks the Marionette wire protocol (127.0.0.1:2828, no add-on installed) and runs
chrome-context JavaScript inside Thunderbird that uses Thunderbird's own code:
  - MailServices / nsIMsgFolder: folder message count, Message-ID, decoded subject (the summary
    database Thunderbird builds when it parses the mbox);
  - MimeMessage.sys.mjs MsgHdrToMimeMessage (Thunderbird's libmime): the attachments it shows,
    by name and content type;
  - each attachment's mailbox:// part URL fetched through Thunderbird's protocol handler and the
    bytes SAVED to <out>/tb-saved/<folder>/<message-id>__<name>, then hashed here.

  Scripts/gate5_thunderbird_readback.py [<gate5 dir>]     (default /tmp/mailin-gate5)
Writes <gate5>/thunderbird-readback.json and prints the comparison; exit 0 only on 0 mismatches.
"""
import hashlib, json, os, socket, sys, time

g5 = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mailin-gate5"
out_dir = os.path.join(g5, "tb-saved")
os.makedirs(out_dir, exist_ok=True)

class Marionette:
    def __init__(self, host="127.0.0.1", port=2828, wait=60):
        deadline = time.time() + wait
        while True:
            try:
                self.s = socket.create_connection((host, port), timeout=120); break
            except OSError:
                if time.time() > deadline: raise
                time.sleep(1)
        self.n = 0
        self.hello = self._recv()
    def _recv(self):
        buf = b""
        while b":" not in buf:
            buf += self.s.recv(1)
        length, rest = buf.split(b":", 1)
        length = int(length)
        while len(rest) < length:
            rest += self.s.recv(length - len(rest))
        return json.loads(rest.decode("utf-8"))
    def cmd(self, name, params=None):
        self.n += 1
        body = json.dumps([0, self.n, name, params or {}]).encode("utf-8")
        self.s.sendall(str(len(body)).encode() + b":" + body)
        while True:
            r = self._recv()
            if r[1] == self.n: break
        if r[2]: raise RuntimeError(f"{name}: {r[2]}")
        return r[3]

SCRIPT = r"""
const [outDir, resolve] = [arguments[0], arguments[arguments.length - 1]];
(async () => {
  const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
  const { MsgHdrToMimeMessage } = ChromeUtils.importESModule("resource:///modules/gloda/MimeMessage.sys.mjs");
  const { NetUtil } = ChromeUtils.importESModule("resource://gre/modules/NetUtil.sys.mjs");
  const root = MailServices.accounts.localFoldersServer.rootFolder;
  const result = { app: Services.appinfo.name + " " + Services.appinfo.version + " (" + Services.appinfo.appBuildID + ")",
                   offline: Services.io.offline, folders: [], notes: [] };
  // Thunderbird parses a new mbox into its summary database asynchronously: ask for the
  // database (starting the parse if needed) and wait until it is open.
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const { setTimeout } = ChromeUtils.importESModule("resource://gre/modules/Timer.sys.mjs");
  const win = Services.wm.getMostRecentWindow("mail:3pane");
  const reparse = async folder => {
    // Show the folder in the main window, as a person clicking it in the folder pane would.
    try { win.gTabmail.currentAbout3Pane.displayFolder(folder.URI); } catch (e) { result.notes.push("displayFolder: " + e); }
    for (let i = 0; i < 120; i++) {
      try { if (folder.msgDatabase && !folder.locked) return; } catch (e) { /* not open yet */ }
      if (i === 0) { try { folder.getDatabaseWithReparse(null, null); } catch (e) { /* parse started */ } }
      await sleep(500);
    }
    throw new Error("summary database never opened for " + folder.name);
  };
  const fetchBytes = url => new Promise((res, rej) => {
    NetUtil.asyncFetch({ uri: url, loadUsingSystemPrincipal: true }, (stream, status) => {
      if (!Components.isSuccessCode(status)) { rej(new Error("fetch " + status)); return; }
      const s = NetUtil.readInputStreamToString(stream, stream.available());
      const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff;
      res(b);
    });
  });
  const mime = hdr => new Promise(res => MsgHdrToMimeMessage(hdr, null, (h, m) => res(m), true, { partsOnDemand: false, examineEncryptedParts: true }));
  for (const folder of root.subFolders) {
    if (!folder.name.startsWith("mailin-")) continue;
    await reparse(folder);
    const db = folder.msgDatabase;
    const f = { name: folder.name, total: folder.getTotalMessages(false), messages: [] };
    for (const hdr of db.enumerateMessages()) {
      // Thunderbird's summary keeps a reply's subject without "Re:" plus the HasRe flag (0x10) and
      // shows "Re: " + subject in the message list; the shown form is what is compared.
      const hasRe = (hdr.flags & Ci.nsMsgMessageFlags.HasRe) != 0;
      const m = { messageId: hdr.messageId, storedSubject: hdr.mime2DecodedSubject, hasRe,
                  subject: (hasRe ? "Re: " : "") + hdr.mime2DecodedSubject, flags: hdr.flags, attachments: [] };
      const mm = await mime(hdr);
      m.inReplyTo = mm ? (mm.get("in-reply-to") || null) : null;
      const walk = p => (p.contentType || "").toLowerCase().startsWith("text/html") || (p.parts || []).some(walk);
      m.hasHTML = mm ? walk(mm) : false;
      for (const a of (mm ? mm.allUserAttachments : [])) {
        const bytes = await fetchBytes(a.url);
        const dir = PathUtils.join(outDir, folder.name);
        await IOUtils.makeDirectory(dir, { ignoreExisting: true });
        const path = PathUtils.join(dir, hdr.messageId + "__" + a.name);
        await IOUtils.write(path, bytes);
        m.attachments.push({ name: a.name, contentType: a.contentType, saved: path, bytes: bytes.length });
      }
      f.messages.push(m);
    }
    result.folders.push(f);
  }
  resolve(result);
})().catch(e => resolve({ error: String(e) + "\n" + e.stack }));
"""

mn = Marionette()
mn.cmd("WebDriver:NewSession", {"capabilities": {}})
mn.cmd("Marionette:SetContext", {"value": "chrome"})
mn.cmd("WebDriver:SetTimeouts", {"script": 300000})
res = mn.cmd("WebDriver:ExecuteAsyncScript", {"script": SCRIPT, "args": [out_dir]})
data = res.get("value", res)
if isinstance(data, dict) and data.get("error"):
    print(data["error"]); sys.exit(2)
json.dump(data, open(os.path.join(g5, "thunderbird-readback.json"), "w"), ensure_ascii=False, indent=2)

inv = json.load(open(os.path.join(g5, "inventory.json"), encoding="utf-8"))
by_id = {e["messageID"].strip("<>"): e for e in inv}
expected = {"mailin-Inbox": {k for k, e in by_id.items() if e["folder"] == "Inbox"},
            "mailin-Projects": {k for k, e in by_id.items() if e["folder"] == "Projects"},
            "mailin-handoff-0001": set(by_id)}
print(data["app"], "offline" if data["offline"] else "ONLINE")
ok, matched, total = True, 0, 0
for f in data["folders"]:
    want = expected.get(f["name"], set())
    problems = []
    if f["total"] != len(want): problems.append(f"Thunderbird count {f['total']} != {len(want)}")
    seen = set()
    for m in f["messages"]:
        mid = m["messageId"].strip("<>"); seen.add(mid)
        e = by_id.get(mid)
        if e is None: problems.append(f"unexpected {mid}"); continue
        bad = []
        if m["subject"] != e["subject"]: bad.append(f"subject {m['subject']!r} != {e['subject']!r}")
        got = sorted((a["name"], hashlib.sha256(open(a["saved"], "rb").read()).hexdigest()) for a in m["attachments"])
        exp = sorted((a["name"], a["sha256"]) for a in e["attachments"])
        if got != exp: bad.append(f"attachments {got} != {exp}")
        if bool(m.get("hasHTML")) != bool(e.get("html")): bad.append(f"HTML part {m.get('hasHTML')} != {e.get('html')}")
        if (e.get("inReplyTo") or None) and (m.get("inReplyTo") or "").strip() != e["inReplyTo"]:
            bad.append(f"In-Reply-To {m.get('inReplyTo')!r} != {e['inReplyTo']!r}")
        if bad: problems.append(f"{mid}: " + "; ".join(bad))
        else: matched += 1
    missing = want - seen
    if missing: problems.append(f"missing {sorted(missing)}")
    total += len(want)
    print(f"{f['name']}: Thunderbird shows {f['total']}, {len(f['messages'])} read, "
          f"{sum(len(m['attachments']) for m in f['messages'])} attachments saved; problems={problems}")
    ok = ok and not problems
if {f["name"] for f in data["folders"]} != set(expected):
    ok = False; print("folders seen:", [f["name"] for f in data["folders"]])
print(f"{matched} of {total} messages match")
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)

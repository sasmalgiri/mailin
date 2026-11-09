# Mail-client handoff tests (3.0 Phase D / H5)

Status legend: **EXECUTED** (date, numbers) · **WRITTEN, NOT RUN** · **NOT TESTED**.
Every row names what proved it; nothing is inferred from code inspection.

## What the handoff is

mailin writes standard mbox files (RFC 4155 framing, mboxrd `>From ` quoting,
a real `From ` envelope with sender and message date, stored raw MIME emitted
byte for byte; reconstructed MIME only when no raw source exists, marked
`X-Mailin-Reconstructed`). Files are partitioned at 2 GB so an exFAT drive
and Apple Mail's importer both cope. The export sheet reads the files back
before it shows the client's import steps.

## Automated rows

| Row | Test | Status |
|---|---|---|
| mboxrd quoting on LF / CRLF / CR and at record start; reversible; both engines unescape `>From ` on read; a bare .eml is left alone | `MBOXQuotingTests` (5 tests) | EXECUTED 2026-09-27 — green. The first run found the quoter walked Swift Characters and missed CRLF lines; now byte-level |
| Record shape: envelope, quoted body, blank separator | `MBOXQuotingTests.testRecordStartsWithEnvelopeAndEndsWithBlankLine` | EXECUTED 2026-09-27 — green |
| Real mailbox (Sent.mbox, 526 msgs, attachment-heavy) → archive → mbox → re-parse: identity set, attachment identity set, per-message SHA-256 of the message bytes (mbox framing excluded), counts | `HandoffRoundTripTests.testRealMailbox_roundTripsThroughMBOX` | **EXECUTED 2026-09-27 — 526 imported, 526 re-parsed, 0 identities missing, 235 attachments identical, 526 of 526 raw messages byte-identical, 126 s.** The first run had 526 raw mismatches: the exporter quoted the stored envelope line into the body as `>From …`, and neither engine undid the source's own mboxrd escaping (one message's `>From Bara jaguli` came back `>>From`). Both fixed |
| Same, split into 16 MB partitions | `HandoffRoundTripTests.testRealMailbox_partitionedRoundTrip` | **EXECUTED 2026-09-27 — 5–6 partitions, same 526 / 235 / 526 result.** The first run showed `exportMBOXPartitions` never actually split and left an empty trailing file that the re-import refused; fixed |
| 1.1 GB single message → mbox export streams the located bytes | `LargeMessageBlobTests` | **EXECUTED 2026-09-27 — export 1,153,445,255 bytes, exactly the fixture** (first pass wrote a 427-byte stub) |
| 1.5 GB fixture export → re-parse count | `ScaleFixtureImportTests.testScale_1_5GB_importThenExportRoundTrip` | EXECUTED 2026-09-26 — 8,416 written, 8,416 re-parsed, 0 failed |

## Executed client imports (H5) — run in Phase J

| Client | Route | What is compared | Status |
|---|---|---|---|
| Apple Mail (this Mac) | Export to Apple Mail… → File ▸ Import Mailboxes… (mbox) | message count per imported folder vs the sheet's number; a sample of 10 messages opened with attachments present | **EXECUTED 2026-11-08 (synthetic, Mail 16.0)** — 30 of 30, 0 mismatches; see the gate 5 section below. A real-archive run is still the owner's |
| Thunderbird 156 (installed 2026-09-27) | Export to Apple Mail or Thunderbird… → copy into Local Folders | folder count and message count vs the sheet's number; subjects, attachment bytes | **EXECUTED 2026-11-09 (synthetic, Thunderbird 156.0.1, throwaway profile)** — 30 of 30, 0 mismatches; see the Thunderbird section below |
| Apple Mail export → mailin | Mail: Mailbox ▸ Export Mailbox… → Import from Apple Mail… | count vs Mail's mailbox count; receipt Complete | **EXECUTED 2026-11-09 (synthetic, package level)** — six synthetic messages imported into Mail 16.0 and exported back with Mailbox ▸ Export Mailbox…; mailin's importer reads Mail's `R9-native.mbox` package and the .eml of the same messages as the same 6 (Message-ID, subject, 4 attachments by SHA-256) — `OwnerPackFixtureTests.testR9_native_*` (R9). A real mailbox stays the owner's |
| Thunderbird profile → mailin | Import from Apple Mail or Thunderbird… ▸ Detect | count vs Thunderbird folder count | NOT TESTED — no Thunderbird profile with mail on this Mac yet |

## Gate 5 / OUT-05 — Apple Mail import run, 2026-11-08 (agent, owner permission)

**EXECUTED 2026-11-08 on this Mac: macOS 27.0.1 (26A434), Apple Mail 16.0 (3901.100.1.1.12).**
Synthetic data only (owner permission 2026-11-08: 10–20 made-up messages, import, verify, delete).

**Export, produced by mailin's own code.** `MailClientHandoffFixtureTests.testGate5_buildsTheClientHandoffExport`
(package) builds 15 synthetic messages — RFC 2047 subjects in German, Hindi and Japanese, one
multipart/alternative HTML body, a PDF attachment (`report-q3.pdf`, 587 B, SHA-256 `745ff715…0276a`),
a PNG attachment (`site-photo.png`, 69 B, `b1ff9c8e…46640`), a three-message reply thread
(In-Reply-To / References), 15 distinct Message-IDs — as a nested .eml directory with two folders
(Inbox 8, Projects 7), imports it with `BulkImportCoordinator`, and exports with
`ArchiveExportService`:
- `mailin-handoff/mailin-handoff-0001.mbox` — `exportMBOXPartitions`, the exact call behind
  "Export to Apple Mail or Thunderbird…" (all 15);
- `folders/Inbox.mbox`, `folders/Projects.mbox` — `exportMBOXArchive` per imported folder
  (FOLD-02 `EmailQuery.folderID`), 8 + 7;
- `eml/*.eml` — `exportEMLFiles`, 15 files;
- `inventory.json` — subject, Message-ID, folder, attachment names + SHA-256.

Run: `MAILIN_GATE5_OUT=/tmp/mailin-gate5 xcrun swift test --filter MailClientHandoffFixtureTests`
(with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) — 1 test, 0 failures.

| Step | What proved it | Result |
|---|---|---|
| Independent parser (Python 3.9.6 `mailbox` / `email`, not mailin's parser) | `Scripts/gate5_parser_check.py` — Message-ID set, decoded subject, attachment names + SHA-256 of decoded bytes, HTML part, In-Reply-To | **PASS** — handoff mbox 15 of 15, Inbox.mbox 8 of 8, Projects.mbox 7 of 7, .eml 15 of 15; 0 mismatches |
| Apple Mail import | File ▸ Import Mailboxes… ▸ Files in mbox format ▸ folder holding `Inbox.mbox`, `Projects.mbox`, `mailin-handoff-0001.mbox` (GUI scripting via System Events; no prompt blocked) | Mail listed 3 items, all checked; created On My Mac ▸ Import ▸ Inbox / Projects / mailin-handoff-0001 |
| Apple Mail read-back | `Scripts/gate5_mail_readback.applescript` (Mail dictionary: count, `message id`, `subject`, `mail attachment` names) + `Scripts/gate5_mail_save_attachments.applescript` (Mail saves each attachment and message source) + `Scripts/gate5_mail_compare.py` | **PASS** — Import/Inbox 8 of 8, Import/Projects 7 of 7, Import/mailin-handoff-0001 15 of 15 (30 of 30); every subject identical (Unicode intact), both attachments by name and SHA-256 of the bytes Mail saved, HTML part present, thread In-Reply-To intact; 0 mismatches |
| Cleanup | Mailbox ▸ Delete Mailbox… on the selected "Import" (sheet: "Delete the mailbox “Import”? … permanently removes it"), Delete | On My Mac back to the pre-run list (SendLater, Outbox); 0 messages with a `gate5-` Message-ID in any account's Bin/Trash. Nothing else in Mail touched |
| Thunderbird | `/Applications/Thunderbird.app` present, version 156.0.1 | Not run on 2026-11-08 (no permission then); **executed 2026-11-09**, next section |

Findings (no mailin defect):
- Mail 16's AppleScript `delete mailbox` fails with -10000 (AppleEvent handler failed) on the imported
  mailbox and its children; the Mailbox menu route works.
- `.eml` filenames replace every non-ASCII character with `_` (e.g. `13_________3____.eml` for the
  Japanese subject); the files themselves are correct. Cosmetic; not changed here.
- Apple Mail's importer takes mbox only, so the .eml set was checked by the independent parser, not by Mail.

## Gate 5 / OUT-05 — Thunderbird run, 2026-11-09 (agent, owner permission)

**EXECUTED 2026-11-09 on this Mac: macOS 27.0.1, Mozilla Thunderbird 156.0.1 (build 20260922151802).**
Owner permission 2026-11-09: import mailin's synthetic export into a NEW Thunderbird profile made for
this test, check it, delete it; no account, no mail sent, nothing to the network; no add-on installed
(ImportExportTools NG is not installed and was not used). Thunderbird had never been started on this
Mac before (no `~/Library/Thunderbird`), so the owner has no Thunderbird profile that could be touched.

**Export.** The same 15 synthetic messages and code path as the Apple Mail run:
`MAILIN_GATE5_OUT=/tmp/mailin-gate5 xcrun swift test --filter MailClientHandoffFixtureTests` (1 test, 0
failures), then `Scripts/gate5_parser_check.py` — PASS (15/15, 8/8, 7/7, .eml 15/15).

| Step | What proved it | Result |
|---|---|---|
| Throwaway profile | `thunderbird -CreateProfile "mailin-test /tmp/tb-mailin-test"`; `Scripts/gate5_thunderbird_profile.sh` writes a `user.js` (Local Folders only, `network.online=false`, no account wizard, no updates / telemetry / safe-browsing) | profile `mailin-test` only; no account configured |
| Import route | The export sheet's "copy into Local Folders" route: `folders/Inbox.mbox` → `Local Folders/mailin-Inbox`, `folders/Projects.mbox` → `mailin-Projects`, `mailin-handoff/mailin-handoff-0001.mbox` → `mailin-handoff-0001` (Thunderbird reads an mbox file in that directory as a folder and builds its own `.msf` summary) | Thunderbird (started `-P mailin-test -no-remote -offline`) listed Local Folders ▸ mailin-handoff-0001 15, mailin-Inbox 8, mailin-Projects 7 in its folder pane; the reply thread shows "Project kickoff — 2 replies"; paper-clip on the PDF and PNG messages. No prompt blocked |
| Read-back | `Scripts/gate5_thunderbird_readback.py`: Marionette on 127.0.0.1:2828 (`--marionette --remote-allow-system-access`, localhost only), chrome-context script using Thunderbird's own `nsIMsgFolder` summary (count, Message-ID, decoded subject, HasRe flag), `MsgHdrToMimeMessage` (libmime: attachments shown, HTML part, In-Reply-To) and its `mailbox://` part URLs, each attachment's bytes **saved by Thunderbird** to `tb-saved/<folder>/` and hashed | **PASS — mailin-Inbox 8 of 8, mailin-Projects 7 of 7, mailin-handoff-0001 15 of 15 (30 of 30), 0 mismatches**: every subject identical as shown (Unicode intact), `report-q3.pdf` `745ff715…0276a` and `site-photo.png` `b1ff9c8e…46640` byte-identical in every folder, HTML part present on the newsletter only, thread In-Reply-To intact; Thunderbird reported `Services.io.offline = true` |
| Cleanup | `Scripts/gate5_thunderbird_cleanup.sh /tmp/tb-mailin-test --remove-registry`: Thunderbird quit, profile directory deleted, and — because none existed before this run — `~/Library/Thunderbird` (profiles.ini / installs.ini), `~/Library/Application Support/Thunderbird` (empty Crash Reports), `~/Library/Caches/Thunderbird` and `org.mozilla.thunderbird.plist` removed | nothing named Thunderbird left under `~/Library` except the app itself |

Findings (no mailin defect):
- Thunderbird's summary stores a reply's subject without "Re:" and sets the HasRe flag (0x10); the message
  list shows "Re: Project kickoff". The read-back compares the shown form (`Re: ` + stored subject when
  HasRe); the first comparison, on the stored form, reported the two replies as mismatches.
- A new mbox in Local Folders is parsed asynchronously when the folder is first shown; the read-back
  displays each folder and waits for the summary database before reading it.

## Known limits (stated, not hidden)

- Messages stored without raw MIME are exported as reconstructed MIME; their
  bytes cannot be compared to an original, and the round-trip report says how
  many there were.
- Thunderbird has no built-in mbox import; the sheet gives both the
  ImportExportTools NG route and the copy-into-Local-Folders route. The 2026-11-09 run used the
  copy-into-Local-Folders route only (no add-on).
- Both client runs used synthetic data; a real archive in a real client stays the owner's.

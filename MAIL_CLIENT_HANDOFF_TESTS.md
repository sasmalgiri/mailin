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
| Apple Mail (this Mac) | Export to Apple Mail… → File ▸ Import Mailboxes… (mbox) | message count per imported folder vs the sheet's number; a sample of 10 messages opened with attachments present | NOT TESTED — needs the interactive step |
| Thunderbird 156 (installed 2026-09-27) | Export to Apple Mail or Thunderbird… → copy into Local Folders | folder count and message count vs the sheet's number; sample of 10 | NOT TESTED — needs the interactive step |
| Apple Mail export → mailin | Mail: Mailbox ▸ Export Mailbox… → Import from Apple Mail… | count vs Mail's mailbox count; receipt Complete | NOT TESTED — owner's two-minute real export requested |
| Thunderbird profile → mailin | Import from Apple Mail or Thunderbird… ▸ Detect | count vs Thunderbird folder count | NOT TESTED — no Thunderbird profile with mail on this Mac yet |

## Known limits (stated, not hidden)

- Messages stored without raw MIME are exported as reconstructed MIME; their
  bytes cannot be compared to an original, and the round-trip report says how
  many there were.
- Thunderbird has no built-in mbox import; the sheet gives both the
  ImportExportTools NG route and the copy-into-Local-Folders route.

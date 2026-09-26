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
| mboxrd quoting on LF / CRLF / CR and at record start; reversible | `MBOXQuotingTests` | WRITTEN, NOT RUN |
| Record shape: envelope, quoted body, blank separator | `MBOXQuotingTests.testRecordStartsWithEnvelopeAndEndsWithBlankLine` | WRITTEN, NOT RUN |
| Real mailbox (Sent.mbox, 526 msgs, attachment-heavy) → archive → mbox → re-parse: identity set, attachment identity set, raw SHA-256 per message, counts | `HandoffRoundTripTests.testRealMailbox_roundTripsThroughMBOX` | WRITTEN, NOT RUN |
| Same, split into 16 MB partitions | `HandoffRoundTripTests.testRealMailbox_partitionedRoundTrip` | WRITTEN, NOT RUN |
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

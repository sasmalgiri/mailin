# App Store listing draft — mailin 3.0

Draft text for App Store Connect, written 2026-09-27 against what the code on `v3-architecture`
does and what has been executed. Only the owner can paste it in. Anything not executed is not
claimed.

## Name and subtitle

**mailin** — Your mail archive, on your Mac.

## Description

mailin opens your email archives — Gmail Takeout, Apple Mail, Thunderbird, Outlook (.pst, .msg),
Lotus Notes (.nsf), plain .mbox and .eml, or a ZIP of any of them — and turns them into a fast,
searchable, private archive that never leaves your Mac.

**The archive**
- A keyboard-first list: J/K move, Return opens, / focuses search, 1–5 tag and advance. Sort,
  filter, smart tags, sender/domain and saved-search filters over the whole archive, paged so it
  stays fast at any size.
- Search that says where it matched (From, Subject, Body, Attachment) and how much of the archive
  the index covered when it answered — a search that hasn't seen every message never reads as a
  bare zero.
- Import with a receipt: what was found, what was written, what was skipped and why, signed so it
  can be filed. Pause, resume, reorder and stop imports from the queue.
- Export to mbox, .eml, PDF, TIFF, .msg, CSV, Word, Markdown, JSON or a portable HTML viewer, with
  a pre-flight that shows the space needed and a receipt with the hash. An interrupted export
  resumes from its receipt.
- Move your archive to an external disk as a verified copy, and get it back if the disk is away.

**No built-in size limit.** Import streams from disk, so archive size is bounded by your storage,
not by mailin. Verified on real mail up to 1.5 GB; larger archives have not been tested.

**AI Insights (optional, off until you switch it on).** Ask questions and get answers with
citations that reopen the exact message; summaries; reports. Everything runs on your Mac with
Apple's on-device models. Cloud providers are used only if you add your own key and approve each
request when it is about to be sent.

**Professional Workflows (optional).** Custodians and legal holds, chain of custody, Bates
numbering, redaction, review batches, eDiscovery, investigation reports, five reasoning studios,
and a production window that writes a Bates-stamped set with a hash manifest and a numbered record.

mailin has no account, no sync and no telemetry. Your archive is a folder you own.

## What's new in 3.0

- Keyboard-first archive list: J/K, Return, /, 1–5 tagging; sort, filter, smart tags and saved searches over the whole archive.
- Import queue with pause, resume, stop-this-file and reorder; the import sheet lets you choose the
  duplicate policy, whether originals are copied, and whether attachment contents are indexed.
- Export pre-flight and resume. Every export ends in a receipt.
- Move the archive to another disk as a verified copy.
- Search results say where they matched and what the index covered.
- Import from and export to Apple Mail and Thunderbird, with the exact steps and a read-back check.
- AI Insights and Professional Workflows are separate pages you switch on; nothing they need
  runs until you do.
- Offset import engine is now the default: single messages over 100 MB are archived instead of
  reported as damaged.

## Privacy label (as built in this configuration)

**Data Not Collected.** mailin has no network capability in this configuration: the sandbox grants
no network entitlement, so no connection can be made.

If the Live Mail edition ships later, the label changes to disclose that email content is sent to
and received from the user's own mail providers at the user's request, and that cloud AI, when the
user enables it and approves a request, sends selected text to the provider the user chose.

## Review notes

- Test archive: the bundled `demo_emails.mbox` (Help ▸ Open sample) shows every surface.
- Nothing in the app requires an account or a network connection.
- Optional pages are off on a fresh install; the page switcher shows how to enable them and what
  each one needs.

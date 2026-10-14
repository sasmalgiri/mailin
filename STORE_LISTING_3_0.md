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
- A three-pane browser: mailboxes, sources and labels on the left, the list in the middle, the
  message on the right. Keyboard-first: J/K, Return, / to search.
- Search that says where it matched (From, Subject, Body, Attachment) and how much of the archive
  the index covered when it answered — a search that hasn't seen every message never reads as a
  bare zero.
- Import with a receipt: what was found, what was written, what was skipped and why, signed so it
  can be filed. Pause, resume, reorder and stop imports from the queue.
- Export to mbox, .eml, PDF, TIFF, .msg, CSV, Word, Markdown, JSON or a portable HTML viewer, with
  a pre-flight that shows the space needed and a receipt with the hash. An interrupted export
  resumes from its receipt.
- Move your archive to an external disk as a verified copy, and get it back if the disk is away.

> **Hold until M5 (do not paste before the 3.0 engines are promoted and V1 is published):**
> *Whole-archive tools.* Legal, analysis and AI tools work on every email in your archive in
> batches, with progress, Cancel and resume after an interruption, and a receipt that proves which
> emails were covered. Analyses that read message text say "based on N of M emails".

> **Hold until A4 (paste only for the switches the owner promotes):**
> *Find deleted mail.* mailin marks mail that was deleted but is still inside your mailbox files
> (Outlook, Thunderbird, Apple Mail, Gmail Takeout) and says how each message was found. Deep
> recovery searches the free space of Outlook files for messages no folder lists any more.
> *Scripts and Shortcuts.* Tag, set aside and note your own emails with small scripts that run on
> your Mac with no network access, after a dry run that shows every change. Or build the same rule
> from menus without writing code. Shortcuts can find, tag, hold, number and export emails.
> *Review together.* Send a set of emails to a reviewer as a Review Pack and merge their answers, or
> run a team case in a shared folder with signed logs, roles, second-level review and an audit you
> can verify. Reviewers need no purchase.
> *Hidden timestamps.* Read the time values Gmail and other systems hide in message headers, and
> check ARC and DKIM signatures.

**No built-in size limit.** Import streams from disk, so archive size is bounded by your storage,
not by mailin. Verified on real mail up to 1.5 GB; larger archives have not been tested.

**AI Insights (optional, off until you switch it on).** Ask questions and get answers with
citations that reopen the exact message; summaries; reports. Everything runs on your Mac with
Apple's on-device models. There is no cloud AI: the app has no network entitlement and cannot
contact any provider.

**Professional Workflows (optional).** Custodians and legal holds, chain of custody, Bates
numbering, redaction, review batches, eDiscovery, investigation reports, five reasoning studios,
and a production window that writes a Bates-stamped set with a hash manifest and a numbered record.

mailin has no account, no sync and no telemetry. Your archive is a folder you own.

## What's new in 3.0

- Three-pane archive shell; open an archive and you are in it.
- Import queue with pause, resume, stop-this-file and reorder; the import sheet lets you choose the
  duplicate policy and whether attachment contents are indexed.
- Export pre-flight and resume. Every export ends in a receipt.
- Move the archive to another disk as a verified copy.
- Search results say where they matched and what the index covered.
- Import from and export to Apple Mail and Thunderbird, with the exact steps and a read-back check.
- AI Insights and Professional Workflows are separate pages you switch on; nothing they need
  runs until you do.
- Offset import engine is now the default: single messages over 100 MB are archived instead of
  reported as damaged.
- Outlook PST and OST files are read by Microsoft's published format: every folder, message,
  recipient and attachment.
- Choose Apple Mail's own library folder and it imports directly.
- (Hold until A4) Deleted-email recovery, Scripts, Shortcuts actions, Review Packs, team cases and
  hidden timestamps: optional, off until you switch them on.

## Keywords (100 characters)

`email archive,mbox,pst,eml,ediscovery,legal hold,bates,recovery,forensic,offline,review,scripts`

Add `recovery`, `scripts` and `review` only once A4 has promoted those switches; until then use
`email archive,mbox,pst,eml,ediscovery,legal hold,bates,forensic,offline,thunderbird,apple mail`.

## Privacy label (as built in this configuration)

**Data Not Collected.** mailin has no network capability in this configuration: the sandbox grants
no network entitlement, so no connection can be made.

If a Live Mail edition ever ships, the label changes to disclose that email content is sent to and
received from the user's own mail providers at the user's request. There is no cloud AI in any
edition.

## Review notes

- Test archive: the bundled `demo_emails.mbox` (Help ▸ Open sample) shows every surface.
- Nothing in the app requires an account or a network connection.
- Optional pages are off on a fresh install; the page switcher shows how to enable them and what
  each one needs.

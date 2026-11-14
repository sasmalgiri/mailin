# mailin 3.0 — App Store Connect, ready to paste (2026-10-15)

Compared with the live listing (iOS 2.0, macOS 2.0.1; text from `main:docs/AppStoreConnect.md`) and checked
against the 3.0 code. Prices unchanged (owner): Personal $4.99 / $44.99 / $99.99, Professional $9.99 / $79.99 / $249.99.

## 2.0 → 3.0 comparison

| Area | Live 2.0 | 3.0 (build 801) | In What's New? |
|---|---|---|---|
| Formats in | mbox, eml, emlx, msg, pst, ost, nsf, zip | same; PST/OST read by Microsoft's published format (every folder, recipient, attachment); Apple Mail library folder directly | yes (reader) |
| Archive size | "up to 500 emails" free; no stated limit | streams from disk, memory flat; checked to 1.5 GB real files and 1M synthetic emails | yes |
| Layout | single list + panels | three-pane archive; AI Insights / Professional Workflows as pages you switch on | yes |
| Import | one-shot | queue with pause / resume / reorder, pre-flight, signed receipt | yes |
| Export | EML, JSON, CSV, PDF, MSG, PST, Bates PDF, Concordance | same formats plus TIFF, Word, Markdown, HTML viewer; pre-flight, receipt with hash, resume; **PST rebuilt — opens in Outlook** | yes (rebuilt PST, resume) |
| Search | Boolean, regex, NEAR, BM25 | same, plus where it matched and how much was searched; **text inside scanned attachments (OCR)** | yes (OCR, coverage) |
| Deleted mail | — | recovery center; deep recovery of Outlook free space | **new** |
| Automation | rule-based auto-tag | + Scripts (dry run, no network) and Shortcuts actions | **new** |
| Review | review batches | + Review Packs, team cases with signed logs, second-level review; reviewers free | **new** |
| Authentication | SPF / DKIM / DMARC, S/MIME | + hidden header timestamps (Gmail and others), ARC chain, DKIM signing dates | **new** |
| AI | assistant, digest, NLP | answers list their source emails; counts computed by the app; works without Apple Intelligence | yes |
| Other apps | — | Send to DEVONthink, `mailin://` email links (Mac) | **new** |
| Languages | 11 claimed | all 4,497 interface strings in 11 languages | yes ("complete") |
| Move archive | — | verified copy to an external disk | **new** |
| iCloud sync | **claimed, but the live app has no iCloud entitlement** — it never worked | not offered | do **not** claim |

Kept from 2.0 and still true in 3.0: analytics dashboard, sentiment/topics/language detection, PII scan, predictive
coding, near-duplicates, anomaly detection, Bates, Concordance, custodians, legal hold, chain of custody, email
comparison, smart alerts, biometric lock, Spotlight.

## Fields to leave as they are in the live listing

| Field | Keep |
|---|---|
| Name | mailin |
| Subtitle | Email Archive Analyzer (or change to "Your mail archive, on your Mac") |
| Category | Productivity, secondary Utilities |
| Support URL | https://sasmalgiri.github.io/mailin/support/ — only change if getmailin.app serves the same pages |
| Marketing URL | https://sasmalgiri.github.io/mailin/ |
| Privacy Policy URL | https://sasmalgiri.github.io/mailin/privacy |
| Copyright | © 2026 Shrabani Sasmal (the App Store seller and the developer named in the Terms of Use, since 3.0.2) |
| Age rating | 4+ (unchanged) |
| App Privacy | Data Not Collected (unchanged) |
| Sign-in | not required |
| Export compliance | answered in the build (`ITSAppUsesNonExemptEncryption = NO`) |
| Review notes | `docs/AppStoreConnect.md` ▸ App Review Notes (still accurate) |
| Terms of Use / EULA | link in the description (guideline 3.1.2); `docs/terms` updated for 3.0 — publish before submitting |

## Promotional Text (≤170)

Open Gmail, Outlook, Apple Mail and Thunderbird archives on your Mac. Search everything, find deleted mail, ask questions on-device. No account, nothing leaves your Mac.

## Keywords (96 of 100)

mbox,eml,pst,msg,email archive,takeout,forensic,ediscovery,bates,recovery,ocr,legal hold,offline

(2.0's mbox/eml/pst/msg/takeout/forensic kept for ranking; no company trademarks — guideline 2.3.7.)

## What's New in This Version

mailin 3.0 is the biggest update yet.
• Find deleted mail still inside Outlook, Thunderbird, Apple Mail and Gmail files.
• Search the text inside scanned PDFs and photos.
• New three-pane archive; AI Insights and Professional Workflows are pages you switch on.
• Import queue with pause and resume; every import and export ends in a receipt, and an interrupted export resumes.
• No preset archive-size or message-count cap: mail is streamed from disk. Capacity depends on your storage, memory and the archive format; see the tested-workload record.
• Outlook .pst export rebuilt — the files open in Outlook.
• Scripts and Shortcuts actions, Review Packs and team cases.
• Hidden header timestamps, ARC and DKIM checks.
• Mac: Send to DEVONthink and links to any email.
• AI answers list the emails they came from.
• The whole interface in 11 languages.

## Description

mailin is a private email archive analyzer for Mac, iPhone and iPad. Open .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf or .zip files from Gmail Takeout, Apple Mail, Thunderbird, Outlook or Lotus Notes — then search, analyze, recover and export your email history. Everything runs on your device. Nothing leaves it.

THE ARCHIVE
• Three panes: mailboxes, sources and labels; the list; the message. Keyboard-first.
• No built-in size limit: mail is streamed from disk. Checked on real mail files up to 1.5 GB.
• Import queue with pause, resume and reorder, and a receipt for every import.
• Move your archive to an external disk as a verified copy.

SEARCH
• Boolean AND / OR / NOT, "exact phrase", regex, NEAR proximity and relevance ranking.
• Results say where they matched and how much of the archive was searched.
• Finds words inside scanned PDFs and photos attached to emails, read on your device.

FIND DELETED MAIL
mailin marks mail that was deleted but is still inside your mailbox files, and says how each message was found. Deep recovery searches the free space of Outlook files for messages no folder lists any more.

ON-DEVICE AI
• Ask questions in plain language; every answer lists the emails it came from. Counts, dates and amounts are read from your archive by the app, not written by the model.
• Summaries, digests, sentiment, topics, language detection, priority scoring, anomaly detection.
• Runs with Apple's on-device models. No cloud AI.

ANALYTICS
Volume timeline, top contacts, activity heatmap, attachment and size breakdowns, contact network, exportable reports.

EXPORT
EML, mbox, JSON, CSV, PDF, TIFF, MSG, Outlook PST, Word, Markdown, a portable HTML viewer, Bates-stamped PDF and Concordance load files. A pre-flight shows the space needed; a receipt records the hash; an interrupted export resumes.

LEGAL & FORENSIC
• Custodians, legal holds, chain of custody, tamper-evident audit log, review batches, predictive coding, redaction.
• SPF, DKIM, DMARC and ARC checks, S/MIME, hidden header timestamps.
• Review Packs and team cases with signed logs and second-level review — reviewers need no purchase.
• Scripts and Shortcuts actions that tag, hold, number and export emails after a dry run.

WORKS WITH YOUR OTHER APPS (Mac)
Send emails to DEVONthink as standard .eml files; copy a mailin:// link that reopens any email from DEVONthink, Notes or any app.

PRIVATE
No account, no tracking, no telemetry. The app has no network access; your archive is a folder you own. Biometric lock available. Interface in 11 languages.

PLANS
• Free: the newest 500 emails of your archive, with search, analytics and a daily allowance of AI questions.
• Personal: the whole archive, unlimited exports, the AI assistant, deleted-mail recovery.
• Professional: adds the legal, forensic, review, scripting and deep-recovery tools.

SUBSCRIPTIONS
mailin Personal and mailin Professional are available as auto-renewable subscriptions (1 month or 1 year) or as a one-time lifetime purchase. Prices are shown in the app in your local currency. Payment is charged to your Apple Account when you confirm the purchase. A subscription renews automatically unless it is cancelled at least 24 hours before the end of the current period; your account is charged for renewal within 24 hours before the period ends. Manage or cancel subscriptions in your Apple Account settings at any time.

Terms of Use: https://sasmalgiri.github.io/mailin/terms
Privacy Policy: https://sasmalgiri.github.io/mailin/privacy

DISCLAIMER
mailin is not a certified forensic tool and does not give legal advice. AI analysis, deleted-mail recovery, text read from scanned attachments, header timestamps and signature checks can be incomplete or wrong; verify results independently before relying on them in legal or business decisions.

DEVONthink is a trademark of DEVONtechnologies, LLC. Outlook is a trademark of Microsoft Corporation. mailin is not affiliated with either company.

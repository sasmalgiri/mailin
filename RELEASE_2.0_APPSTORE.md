# mailin 2.0 — App Store Metadata (draft)

Copy‑ready text for App Store Connect. Everything here is a **draft for your review** —
adjust names/URLs/claims before submitting. Bundle id: `com.ecosanskriti.mailin`.
Version: **2.0.0 (200)**. Category: **Productivity**.

---

## App name (30 char max)
```
mailin
```
> This ships as **version 2.0 of the existing "mailin" App Store app** — an
> UPDATE, not a new listing. What makes it an update is the **bundle identifier
> matching the live app exactly**. Current config: `com.ecosanskriti.mailin`,
> display name `mailin`.
>
> ⚠️ CONFIRM before submitting: the live App Store app's bundle id is
> `com.ecosanskriti.mailin`. If it differs, change `PRODUCT_BUNDLE_IDENTIFIER`
> to match — otherwise App Store Connect treats this as a brand‑new app.
> (Internal target name `maxmailin` / `CFBundleName` don't affect the store
> listing; only the bundle id + App Store Connect name + `CFBundleDisplayName`
> do. Optionally align `CFBundleName` to "mailin" for tidiness.)

## Subtitle (30 char max)
```
Analyze mail offline, on device
```

## Promotional text (170 char max — editable without review)
```
Import mbox, eml, emlx, msg or PST and investigate it entirely on your Mac — search, dedupe, PII, timelines, redaction and forensic workflows. Nothing leaves your device.
```

## Keywords (100 char max, comma‑separated, no spaces after commas)
```
email,mbox,eml,pst,archive,ediscovery,forensic,redaction,pii,dedupe,timeline,investigation,offline
```

---

## Description
```
mailin turns a pile of exported email into an organized, searchable, and
defensible case file — entirely on your Mac. Nothing is uploaded. There is no
account, no cloud, no tracking. Your archive never leaves your device.

Import what you already have — Gmail Takeout (.mbox), Apple Mail (.emlx),
Outlook (.msg / .pst / .ost), or individual .eml files — and mailin builds a
fast, structured archive you can actually work with.

WORK THE WAY YOU THINK
mailin adapts to who you are:
• Personal — declutter, find and export receipts, back up contacts and attachments.
• Journalist — build a cited story file, map who talks to whom, chase FOIA threads.
• IT / Admin — triage alerts, quarantine, rules and blocklists, DLP checks.
• Legal — legal holds, ECA, first‑pass review, privilege logs, DSAR/GDPR reports.
• Forensic — evidence intake, hashing and chain of custody, IOC extraction, expert reports.

GUIDED JOBS, NOT JUST TOOLS
Pick the job you came to do and mailin walks you through it step by step — each
step opens the right tool, saves your work as you go, and produces a numbered
document you can reopen, export to CSV, and pull into custom reports. Attach the
exact emails and files each step relies on, right inside the job.

POWERFUL ANALYSIS
• Full‑text and structured search (sender, date range, subject, tags, attachments).
• Duplicate and near‑duplicate detection.
• PII detection (emails, phone numbers, cards, SSNs and more) with a review pass.
• Timelines, communication patterns, entity and relationship graphs.
• Anomaly detection, keyword monitoring, executive dashboards.
• Redaction, Bates numbering, chain of custody, and signed exports.

PRIVATE BY DESIGN
• 100% on‑device. No network access — by design, not by promise.
• Optional biometric lock.
• Export to CSV, Word, Markdown, EML, MBOX and PDF whenever you choose.

On Apple silicon, optional on‑device Apple Intelligence features summarize and
narrate — still without sending your mail anywhere.

mailin is a single‑examiner tool that augments your judgment. It does not make
legal determinations for you.
```

---

## What's New in 2.0
```
mailin 2.0 is a ground‑up rebuild.

• New SQLite engine — faster, bounded memory, handles large archives.
• Guided workflows for every role — run a whole job step by step, with a
  progress rail, inline forms, auto‑save and optional sign‑off.
• Attach the exact emails and files each step relies on.
• Calendar date pickers for date ranges everywhere.
• Universal document numbering — every job is saved, reopenable, and exportable.
• Duplicate Manager, redaction, chain of custody, PII and reporting, refined.
• Every tool opens in its own window on Mac.
• Fixes throughout, including a Duplicate Manager crash on removal.
```

---

## Privacy — App Store "nutrition label"
Answer in App Store Connect ▸ App Privacy:
- **Data collection:** *Data Not Collected.* mailin has no analytics, no accounts,
  and no network capability (no `com.apple.security.network.client` entitlement).
- No data is linked to the user; no tracking.
- **Privacy policy URL:** required — host a short page stating the app collects
  and transmits nothing. (Placeholder: `https://<your-domain>/mailin/privacy`)

## Export compliance
- `ITSAppUsesNonExemptEncryption = NO` is set in Info.plist. The app uses only
  standard Apple‑provided encryption for local data protection (exempt). Confirm
  this answer in App Store Connect. If you ever add non‑exempt crypto, revisit.

## URLs (fill in before submit)
- Support URL: `https://<your-domain>/mailin/support`
- Marketing URL (optional): `https://<your-domain>/mailin`
- Copyright: `© 2025–2026 mailin. All rights reserved.`

## Age rating
- Expected **4+** — no objectionable content. (User‑imported mail content is
  user‑generated and not part of the rating.)

---

## App Review notes (paste into "Notes" for the reviewer)
```
mailin is a 100% offline, on‑device email‑archive analysis app. It has no
network capability and no account.

To evaluate without your own data: launch the app and choose to load the bundled
sample archive (demo_emails), or import any .mbox/.eml file. Then open the
navigation hub, pick a persona, and run a "Start a job" workflow (e.g. Personal ▸
Find & Export). Tools also open individually from the sidebar.

No login is required. No sign‑in credentials are needed.
```

## Screenshots to capture (owner)
Required sizes: Mac (2880×1800), iPad 13", iPhone 6.9" & 6.5". Suggested shots:
1. Navigation hub with persona + "Start a job" cards.
2. A workflow running (roadmap rail + a step open with fields).
3. Search + results over a large archive.
4. Duplicate Manager.
5. A report / document (Work Center ▸ Documents) or Timeline.

## In‑App Purchases (if using the tiered pricing)
Configure in App Store Connect and gate in `StoreManager`:
- Personal — one‑time non‑consumable.
- Professional — auto‑renewing subscription (monthly + annual).
(See the pricing discussion; final numbers are your call.)
```

# App Store Connect — Copy/Paste Guide for mailin

Everything below is ready to paste into App Store Connect.

---

## Build to upload (3.0 public update, 2026-09-30)

- Bundle ID: `com.ecosanskriti.mailin` (the record the installed 1.0 (10) belongs to)
- Version 3.0, build 300 — set in the `maxmailin` target; both are above 1.0 (10)
- Configuration: Release, scheme `maxmailin`, destination My Mac. Product ▸ Archive, then Distribute App ▸ App Store Connect ▸ Upload
- Compile flags: `NO_NETWORK_BUILD` only (no `ENTERPRISE_EDITION`): purchases and the free tier are in, cloud AI and Live Mail connectors are out, no network entitlement
- Entitlements: app sandbox, user-selected files read/write, security-scoped bookmarks, print — identical to the installed 1.0
- Screenshots for the Mac listing (2880 × 1800): `~/Downloads/AppStoreScreenshots-3.0/`

## App Name
```
mailin
```

## Subtitle (30 characters max)
```
Email Archive Analyzer
```

## App Category
```
Primary: Productivity
Secondary: Utilities
```

## App Description (4000 characters max)

```
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
```

## Keywords (100 characters max, comma-separated)

```
mbox,eml,pst,msg,email,archive,analyzer,gmail,takeout,forensic,nlp,sentiment,export,privacy,search
```

## Promotional Text (170 characters max, can be updated without new version)

```
Analyze email archives privately on Mac, iPhone, and iPad. Import Gmail, Outlook, Thunderbird, or Apple Mail — on-device AI insights, forensic tools, 11 languages.
```

---

## Support URL
```
https://sasmalgiri.github.io/mailin/support/
```

## Marketing URL (optional)
```
https://sasmalgiri.github.io/mailin/
```

## Privacy Policy URL
```
https://sasmalgiri.github.io/mailin/privacy
```

---

## Age Rating Questionnaire Answers

| Question | Answer |
|----------|--------|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Simulated Gambling | None |
| Sexual Content or Nudity | None |
| Unrestricted Web Access | No |
| Gambling and Contests | No |

**Result: Rated 4+**

---

## App Privacy — Privacy Nutrition Label

In App Store Connect → App Privacy:

**1. Do you or your third-party partners collect data from this app?**
→ Select: **No, we do not collect data from this app.**

That's it. Since mailin collects zero user data, no further questions apply.

---

## App Review Notes (for the reviewer)

```
mailin is an email archive analyzer that opens .mbox, .eml, .emlx, .msg, .pst, .ost, .nsf and .zip files locally on the user's device. It runs on Mac, iPhone and iPad.

TESTING:
- Help > Open sample loads the bundled demo_emails.mbox; it shows every surface. Or drag any supported file onto the window.
- The archive page is always on. AI Insights and Professional Workflows are optional pages, off on a fresh install; the page switcher (top of the window) explains what each needs and turns it on.
- Free tier: import up to 100 MB of archives and browse the first 500 results of any list or search. Personal and Professional features need a subscription or one-time purchase (StoreKit 2; cancel via Apple's Subscriptions UI).

NETWORK:
- No account, no login, no developer server. The archive never leaves the device.
- No cloud AI. The app has no network entitlement and cannot contact any server.
- The Live Mail page is a placeholder in 3.0: no account can be added and no mail server is contacted; the page says so.
- StoreKit is the only other network use.

PRIVACY:
- PrivacyInfo.xcprivacy declares no tracking and no collected data. No third-party SDKs.

No demo account is needed.
```

---

## What's New (Version 3.0)

```
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
```

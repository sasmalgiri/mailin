# mailin 3.0 — what is left before the App Store (updated 2026-10-14)

Everything that can be built and tested without you is done and committed on `v3-architecture`
(nothing pushed). Trackers: `SCALE_TODO_3_0.md` (whole-archive engines) and `FINAL_TODO_3_0_MAJOR.md`
(recovery, scripting and team review, moved into 3.0). Results: `SCALE_RESULTS.md`.

## Done (verified)

- **Unit suites (2026-10-14, evening):** app 878 tests: 859 pass, 18 skipped (opt-in scale and owner-bound runs), 1
  failed — a race between two tests over a shared value, fixed (`549b25f`) and the affected suites re-run green.
  ArchiveCore 122, 0 failures; the 10 real-file tests run with `MAILIN_REAL_FIXTURES` and pass. StoreKit 9/9 on the
  iPhone simulator (2026-10-12).
- **Mac accessibility audit (D1):** passed with you present — no accessibility issues.
- **UI (V5):** every iPhone UI test passes (accessibility audit, click-through, every-button crawl, real-mailbox
  crawl, exports, every Professional tool, AI questions, purchases buy/restore/lifetime). Mac: 10 UI tests pass,
  0 fail; 5 Apple-sandbox purchase tests skip (they need a person to sign a sandbox tester in).
- **Correctness at scale:** 27 tools have golden tests; every Legal tool passes at 100,000 emails with exact
  answers, flat memory and a time limit; the 1M run passed earlier.
- **Recovery, scripting, team review (in 3.0, promoted 2026-10-15, on by default):** A1–A3, A5, B1, B2, B4–B8, C1–C7 done:
  - A5: a real v19 archive upgrades to v20 with a snapshot first and every row kept.
  - B8: the new PST writer is read back exactly by libpff and libpst.
  - C5 and C6: real Outlook, Thunderbird and Apple Mail files.

  Defects found by those runs and fixed:
  - Apple Mail's library imported 0 messages.
  - PST attachments came in with no content.
  - The PST reader read 0–1 messages per real Outlook file.
  - Sent copies were flagged as missing DKIM.
  - A team-case reload took 6.5 s.

  Details: `RELEASE_NOTES_3_0.md` (top section).

## Left — in this order

| # | Step | Who | How |
|---|---|---|---|
| 1 | ~~Accessibility confirming run (D1)~~ | done 2026-10-14 | Passed on the Mac with you present: no accessibility issues (`ACCESSIBILITY_3_0.md`) |
| 2 | ~~Promotion decision (A4)~~ — done 2026-10-15: "promote all" | you | For each preview switch — Deleted-email recovery, Deep recovery, Shortcuts actions, mailin Scripts, Review Packs, Team case, Hidden timestamps, Outlook PST writer — say "promote" or "keep preview". I then set it stable and update the matrix test. My evidence per switch is in `FINAL_TODO_3_0_MAJOR.md` § Progress. I recommend keeping the PST writer a preview until step 5 |
| 3 | **Screenshots (A7)** | you | You are providing the store set. Mine (iPhone 6.9", sample data) are in `Screenshots/3.0/iphone-6.9/` if useful |
| 4 | **Upload the build** (your pbxproj is at build 700, uncommitted) | you or me | Tell me "upload 700" (`Scripts/testflight.sh --build 700 --upload`), or Xcode ▸ Organizer ▸ Distribute ▸ TestFlight |
| 5 | **Owner-only checks** | you | ~~B8 Outlook~~ done 2026-10-15 (v9 opens in Outlook). D2 Shortcuts on a device; D3 on a network share / second Mac (the Mail-folder run passed 5/5); D5 the script assistant on an Apple Intelligence Mac. B3 is done on synthetic files; a real HCL Notes database would confirm it |
| 6 | **TestFlight period (D6)** 1–2 weeks on your real archives | you | TestFlight builds turn the preview engines on; any engine the app stops inside switches itself off (Settings ▸ Archive Health) |
| 7 | **App Store submission (V8)** — Mac first | you | `STORE_LISTING_3_0.md` (the A4 text is now to be pasted: all switches promoted), `AppReviewNotes.md`, privacy "Data Not Collected", accessibility answers from `ACCESSIBILITY_3_0.md`, price; submit |

## Open, stated

- **Mac accessibility audit:** findings on framework-drawn parts remain (split-view panes, SwiftUI menu buttons,
  the menu bar) — named advisories in `ACCESSIBILITY_3_0.md`.
- **Launch time on a 1M archive (V7):** not measured (you chose 1k-scale testing); the app logs
  "first page shown after X s" at every launch (Console ▸ category `launch`), so TestFlight use shows it.
- **No real device:** lock/suspend (S3), iPad background jobs (S4), MetricKit (S5) — simulator only.
- **Lotus Notes deletion stubs (B3):** built and verified on mailin's own synthetic NSF files; not yet on a database
  written by HCL Notes (the stub layout is undocumented) — stated in the limits doc.
- **Mac UI tests open your real archive** (they seed the demo mailbox only when the archive is empty). The audit only
  reads, but a separate test archive for UI tests is still to be built.
- **Outlook PST writer:** opens in Outlook (owner, 2026-10-15, v9 file; `PST_EXPORT_VALIDATION.md`); promoted with the rest (A4).

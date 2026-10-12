# mailin 3.0 — what is left before the App Store (updated 2026-10-12, evening)

Everything that can be built and tested without you is done and committed on `v3-architecture`
(nothing pushed). Tracker: `SCALE_TODO_3_0.md`, results: `SCALE_RESULTS.md`.

## Done (verified)

- **Unit suites:** app 594 XCTest + 239 Swift Testing, 0 failures, 0 warnings; ArchiveCore 59, 0 failures;
  StoreKit 9/9 on the iPhone simulator.
- **UI (V5):** every iPhone UI test passes (accessibility audit, click-through, every-button crawl, real-mailbox
  crawl, exports, every Professional tool, AI questions, purchases buy/restore/lifetime). Mac: 10 UI tests pass,
  0 fail; 5 Apple-sandbox purchase tests skip (they need a person to sign a sandbox tester in).
- **Correctness at scale:** 27 tools have golden tests; every Legal tool passes at 100,000 emails with exact
  answers, flat memory and a time limit; the 1M run passed earlier.
- **Fixed today:** Custodians ▸ Assign to all (3,691 s → 0.2 s), Verify & seal (317 s → 31 s), Safe Mode
  tripped by test launches, page-switcher contrast / text size / clipping, unlabelled buttons (VoiceOver),
  collect-to-preserve, PII export on iPhone, export-policy gaps, StoreKit test leak.
- **Build 603 is built:** iOS archive and Mac package (sandboxed, no network — verify-no-network PASS) in
  `build-testflight/603/`.

## Left — in this order

| # | Step | Who | How |
|---|---|---|---|
| 1 | **Sign in to Xcode** (the upload was refused: "Invalid credentials in keychain") | you | Xcode ▸ Settings ▸ Accounts ▸ sign in again with the developer Apple Account |
| 2 | **Upload build 603** | you or me | Tell me "upload 603" (I run `Scripts/testflight.sh --build 603 --upload`), or in Xcode ▸ Window ▸ Organizer pick the two 603 archives ▸ Distribute ▸ TestFlight |
| 3 | **TestFlight period** 1–2 weeks on your real archives | you | TestFlight builds turn the 3.0 engines on; any engine the app stops inside switches itself off (Settings ▸ Archive Health) |
| 4 | **Promote the engines (M5)** | me | Set the engines to stable in `EngineSpec.swift`, log the date, update the M1 test |
| 5 | **App Store submission (V8)** — Mac first | you | Description, screenshots (the iPhone screenshot test already captures them), privacy "Data Not Collected", accessibility answers from `ACCESSIBILITY_3_0.md`, price; submit |
| 6 | iPhone / iPad | you | After TestFlight testers with real devices report back |

## Open, stated

- **Mac accessibility audit:** findings on framework-drawn parts remain (split-view panes, SwiftUI menu buttons,
  the menu bar, one small text) — `ACCESSIBILITY_3_0.md`; a short VoiceOver pass on the Mac decides.
- **Launch time on a 1M archive (V7):** not measured (needs ~3 GB and ~20 min); the app logs
  "first page shown after X s" at every launch (Console ▸ category `launch`), so TestFlight use shows it.
- **No real device:** lock/suspend (S3), iPad background jobs (S4), MetricKit (S5) — simulator only.

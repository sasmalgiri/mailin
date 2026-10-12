# mailin 3.0 — what is left before the App Store (2026-10-12)

Everything that can be built and tested without you is done and committed on `v3-architecture`
(nothing pushed). Tracker: `SCALE_TODO_3_0.md`, results: `SCALE_RESULTS.md`.

## Done (verified)

- Every 3.0 tool has a golden test (27 tools, answers equal what was planted) and every Legal tool passes
  at 100,000 emails with exact answers, flat memory and a time limit; the 1M run passed earlier.
- The 100k run found and fixed two real defects: Custodians ▸ Assign to all (3,691 s → 0.2 s) and
  Verify & seal (317 s → 31 s).
- Crash protection: an engine the app stops inside is switched off at the next launch (tested).
- Release build: no network (verify-no-network PASS), idle CPU 0 %.
- Enterprise: roles, export/print policy, MDM configuration + feedback, schema files, deployment guide.
- All interface text in 10 languages.

## Left — in this order

| # | Step | Who | How |
|---|---|---|---|
| 1 | **V5 session at the Mac** (one sitting): Mac UI suites, press-every-button crawl, accessibility audit, StoreKit suite | you + me | Open the project in Xcode, set the scheme's StoreKit configuration to None, tell me "start V5"; approve the "allow automation" prompt once when it appears |
| 2 | **TestFlight build** (603) with the 3.0 engines on | you | `Scripts/testflight.sh` (TestFlight builds turn the 3.0 engines on automatically). Use it on your real archives for 1–2 weeks; any engine the app stops inside switches itself off and is listed in Settings ▸ Archive Health |
| 3 | **Promote the engines (M5)** | me | After the TestFlight period with no switch-offs: each engine is set to stable in `EngineSpec.swift`, logged with its date in the plan, and the M1 test updated. Old engines stay one switch away |
| 4 | **Launch time on a 1M archive** (V7) | me | Optional: needs ~3 GB of disk and ~20 min; the app now logs "first page shown after X s" at every launch (Console ▸ category `launch`), so it can also be read from your TestFlight use |
| 5 | **App Store submission (V8)** — Mac first | you | Description, screenshots, privacy answers ("Data Not Collected"), accessibility answers from `ACCESSIBILITY_3_0.md`, price; upload the build from step 3; submit |
| 6 | iPhone / iPad version | you | After TestFlight testers with real iPhones/iPads report back (no real device has run it yet; simulator only) |

## Not possible without hardware (stated, not hidden)

Real-device lock/suspend (S3), iPad background jobs (S4), MetricKit crash reports (S5) — they are covered
on the simulator and arrive through TestFlight.

# Yearly platform checklist (every WWDC / new SDK) — SCALE_TODO_3_0.md §3-P5

Run this each June when a new SDK ships, and again before the first release built with it.

## 1. Build
- [ ] Build `maxmailin` (macOS + iOS) and `ArchiveCore` against the new SDK with **zero new warnings**.
- [ ] Read Apple's "What's new" for SwiftUI, FoundationModels, CoreSpotlight, BackgroundTasks, SQLite/Foundation; apply documented fixes (e.g. SDK 27: `@State` macro, `@ContentBuilder`).
- [ ] Clear new deprecations (search the build log for `deprecated`).
- [ ] `xcrun swift build -Xswiftc -strict-concurrency=complete` in `Packages/ArchiveCore` — count must not grow.

## 2. On-device model (rule 8; §3-I5)
- [ ] Settings ▸ Health shows "the on-device model changed" after the OS update → re-run the typed-question AI checks; when they pass, record them (`ModelVersionWatch.recordChecksPassed()`).
- [ ] Re-check `SystemLanguageModel.contextSize` (the window parts are sized to) and `tokenCount` availability.
- [ ] Re-read Apple's "Updating prompts for new model versions"; bump `ModelVersionWatch.promptVersion` when prompts change.

## 3. Background work
- [ ] `BGContinuedProcessingTask` / `BGTaskScheduler` rules unchanged (wildcard identifier in Info.plist, registration once at launch).
- [ ] iPad: lock the device mid-job → the job stops at a batch boundary and resumes.

## 4. Privacy and network (rule 7)
- [ ] Release build: verify-no-network (opening HTML mail, AI, search, exports).
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption = NO` is right only while the app signs/hashes and does not encrypt data itself — re-check if case bundles or exports change (§3-P7).
- [ ] Spotlight: protected index class still accepted; `CSUserQuery` behaviour unchanged.

## 5. Scale (Phase V)
- [ ] V1 100k / 1M tables re-run; memory flat; Cancel and resume.
- [ ] V3 chaos run (kill mid-job, disk full, drive unplugged, iPad locked).
- [ ] V7 launch / resume time with a 1M archive without the debugger.

## 6. Record
- [ ] Add a dated line to SCALE_TODO_3_0.md §8 with what changed and what was fixed.

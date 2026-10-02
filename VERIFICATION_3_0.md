# mailin 3.0 — verification record for the release candidate

Tree verified: the working tree committed as `f600335` (identical files; the run was launched before the commit was recorded, so the log header names its parent `e662a46`). Machine: owner's Mac, Xcode 27, 2026-10-02 IST.

| Check | Command | Result |
|---|---|---|
| Full regression suite (macOS) | `xcodebuild test -scheme maxmailin -only-testing:maxmailinTests` | XCTest: 510 executed, 12 skipped, 0 failures (257.5 s). Swift Testing: 184 tests in 23 suites passed. `** TEST SUCCEEDED **` |
| Production-path scale test | `V2VerificationTests.testProductionPathScale_boundedEnginesOverLargeStore` | passed (9.887 s). The CancellationError recorded by an earlier review did not reproduce in this run or in the 2026-10-02 run on `63120b2`. |
| Purchase-gate + localization suites | `~/mailin-loc-work/run-gate-tests.sh` (7 suites) | 58 tests passed, including `exportCapFollowsCurrentTier` and `exportWithoutATierIsRefused`. |
| macOS Release build | `xcodebuild build -configuration Release -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` (started 19:36, finished 19:47 IST). |

Logs: `~/mailin-loc-work/alltests.log`, `~/mailin-loc-work/release-build.log`, `~/mailin-loc-work/gatetest.log`; xcresult bundle `/Users/shirshendusasmal/Library/Developer/Xcode/DerivedData/maxmailin-dmngwemvevtzxtchxuazqxexjxfj/Logs/Test/Test-maxmailin-2026.10.02_19-31-43-+0530.xcresult`.

Not covered by this record (owner-side): sandbox purchase, restore, pending and revocation flows on macOS and iOS; the Release archive and hands-on smoke test; a per-language click-through of the paywall and Settings on a device (the iPad simulator pass of 2026-10-02 covered de, ja, hi, zh-Hans on the archive page, sidebar, Settings ▸ Modules and the page-activation sheet).

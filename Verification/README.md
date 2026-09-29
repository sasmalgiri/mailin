# Verification logs

Native test output for reviewed commits of `v3-architecture`, kept so a source review can be
matched to a runtime result on the supported platform. Each log names the commit it was run
against, the date, the host, and the exact command or Xcode test plan.

| File | What | Result |
|---|---|---|
| `2026-09-29-c7220fa-package-tests.log` | `xcrun swift test` over `Packages/ArchiveCore` (fault-volume and throughput classes skipped: they need the mounted disk image and the 95 MB fixture) | 49 tests, 0 failures |
| `2026-09-29-c7220fa-app-tests.txt` | Xcode test plan `maxmailin`, target `maxmailinTests`, macOS Debug | 662 tests: 649 passed, 0 failed, 13 skipped |

The 13 skipped rows are the 1 GB per-format, 1.5 GB scale and fault-volume tests, which run only
with the dedicated disk image and fixtures (`SCALE_RESULTS.md` records their executed results).

# Verification logs

Native test output for reviewed commits of `v3-architecture`, kept so a source review can be
matched to a runtime result on the supported platform. Each log names the commit it was run
against, the date, the host, and the exact command or Xcode test plan.

| File | What | Result |
|---|---|---|
| `2026-09-29-c7220fa-package-tests.log` | `xcrun swift test` over `Packages/ArchiveCore` (fault-volume and throughput classes skipped: they need the mounted disk image and the 95 MB fixture) | 49 tests, 0 failures |
| `2026-09-29-c7220fa-app-tests.txt` | Xcode test plan `maxmailin`, target `maxmailinTests`, macOS Debug | 662 tests: 649 passed, 0 failed, 13 skipped |

Skipped rows, by name, and why (eighth review asked for the exact list):

- 11 hardware-bound rows that run only with the dedicated disk image and fixtures
  (`SCALE_RESULTS.md` records their executed results; those are historical runs, not reruns at
  this commit): `DiskImageFaultTests/testENOSPC_onFaultVolume_isNamedAndLeavesAConsistentStore`,
  `FormatMatrixScaleTests` (EML folder, Maildir, Apple Mail package, EMLX folder, gzip, mixed four
  formats — all 1 GB), `LargeMessageBlobTests/testMessageAboveRowCeiling_importsReadsBackAndExports`,
  `ScaleFixtureImportTests` (1.5 GB round trip, offset engine, inside ZIP).
- `V2VerificationTests/testStressHarnessSweep` — opt-in stress harness, triggered only by a config
  file or `MAILIN_STRESS_SCALES` in the environment.
- Up to and including c7220fa, `V2VerificationTests/testPrivacyAudit_boundedLayerIsOnDevice` was
  ALSO skipped: it looked for the bounded-core files under `maxmailin/` after they had moved into
  `Packages/ArchiveCore`, and its missing-file guard skipped instead of failing. Fixed in the commit
  after ed579a4: both trees are resolved, a missing file fails, and the whole package is scanned.
  The log for that commit shows the test as passed and 12 skipped.

The package command excludes `FaultVolumeTests` and `ImportThroughputTests` explicitly (mounted
fault image and the 95 MB throughput fixture); it is not the full unfiltered package suite.

# Whole-codebase review — 2026-11-16 (read-only; nothing changed)

## Status 2026-11-16 (fix pass on `v3-architecture`, a177c8b..4d056c1; closeout of the open items 40cae41..b34d6c4)

**Closeout 2026-11-17 (open items 1–10, owner decisions D-1…D-6).** Every open item below now has a
resolution and a commit; the merged tree (package API change in ab4cd27 + parallel app changes) was
verified on b34d6c4, MacBook Air arm64, macOS 27.0.1:
- Debug-Connected (scheme "maxmailin Connected", My Mac), build for testing green. Five-jobs gate
  V2CutoverTests 202 + ConnectedFiveJobsTests 10 + ConnectedFiveJobsFixPassTests 4: **214 passed,
  2 skipped (COMP14 S/MIME keychain identity, TYPE05 speech permission — owner-bound), 0 failed**.
  Review1116C 26, InterfaceLocalization 6 (incl. the new package-texts German test), V3Lint 2,
  ConnectedLifecycleAudit 19, ConnectedFixIntegration 9, AppLimitsReconciliation 4, WhatsNewGate 4,
  SearchMatchFields 13, V2Search 26, V2Export 13, V3Compatibility 53, ProfessionalGating 7,
  SMIMEGoldCase 7, T02HostileHTMLZeroNetwork 3, V2ForensicPersistence 9, V31Shortcuts 4:
  **205 passed, 0 skipped, 0 failed**.
- Offline scheme "maxmailin": Review1116C + AppLimitsReconciliation + WhatsNewGate + V414Claims
  **39 passed, 1 skipped (T47 Release-only), 0 failed**.
- Package (`swift test --skip LargeSingleMessageTests`): **890 run — MailConnectivity 179 (2 skipped),
  ArchiveCore 711 (22 skipped), 0 failed**.
- Builds: macOS connected, iPhone 17 and iPad Pro 11-inch (M5) simulators — all succeed. App-target
  warnings: only the two known ones (SpeechPermissionSection `@State` macro, ContentViewModel.swift:313
  Sendable). The test target also shows 10 pre-existing "no 'async' operations occur within 'await'"
  warnings in V2CutoverTests.swift (lines from 2026-11-05/06, MainActor test calling the MainActor
  ArchiveDataService); none from this pass.
- No failure found; nothing needed fixing in the merge.

**Review of a177c8b..dd0c10d (2026-11-17), five findings fixed:** #1 CAB reader decodes each block once
for members read in folder order (87b853e); #2 snapshot-restore alert answer is one-shot, the tapped
button wins (bef6638); #3 D-6 in ArchiveQueryCompiler — NOT only in capitals (1e3265a); #4 TIFF export
streams page by page (f39003c); #5 PST spec reader reads lcbTotal 0xFFFFFFFF as "not stated" (39e34ef).

**Closeout 2026-11-18 (five items after the CLOSE-06 five-journey run; 3a2a2ea..15954eb).** Owner rule
2026-11-18: no Mac UI tests run unattended. Mac UI tests are compiled only and listed as pending below.
1. Back-translation corrections: 117 translations in 54 keys from
   `~/mailin-loc-work/backtranslation-fixes-2026-11-18.py` (FIXES only; the Apple Mail / Thunderbird
   menu labels in NEEDS_UI_CHECK are not applied). This includes the two errors, where ja and ko had
   weakened "Integrity: DOES NOT VERIFY" into "could not check" (8ef698c). The test is
   InterfaceLocalizationTests.backTranslationCorrections (failed before). Review1116C's German
   receipt test now expects "mailin-Importquittung" (15954eb).
2. Live Mail accessibility. The page now has named columns, a quick-filter label, one element per
   row and a contrast-safe placeholder and risk badge, and a new Live Mail page audit was added
   (3a2a2ea). The row label is now the pure function `MailOrganize.rowAccessibilityLabel`. It uses
   the display name and "(no sender)" / "(no subject)", never a bare comma (77333d9). The test is
   MailWorkspaceTests.testLiveMailRowAccessibilityLabel… (failed with the old logic).
3. Restore from the Trash is a true undo of a duplicate merge: provenance is kept in
   `duplicate_merge_additions` and J4 shows Inbox 3, not 4 (02081c3). A value that something else
   adds to the kept copy after the merge (the person, an import, a sync) now claims the record
   through a BEFORE INSERT trigger, so restore leaves it. The merge's own copies do not claim
   (47006d0). The tests are package DuplicateRestoreUndoTests, 5 in total; the new tag test failed
   before.
4. Zero build warnings: the Speech import for the `@State` macro, the `@MainActor @Sendable` batch
   callback, and the 10 sync `await`s in V2CutoverTests (661f914). A full recompile of the app, unit
   and UI test targets (every source touched, build for testing) on 15954eb gave **0 warnings**.
5. 160 stale catalog keys removed and a test keeps it that way (9e798b6). Re-checked against the
   app and package sources: no removed key is named in the code (one appears only in a package test
   comment). The 40 keys still marked stale are all still referenced.

Verified on 15954eb, Debug-Connected, My Mac:
- Five-jobs gate (V2Cutover + ConnectedFiveJobs + FixPass): **215 passed, 2 skipped (COMP14, TYPE05;
  owner-bound), 0 failed**.
- Touched classes: InterfaceLocalization 8/8, V3Lint 2/2, RunningJobLifecycle 5/5, Review1116C 27/27,
  MailWorkspace 16 passed and 1 skipped (offline-only).
- Package (`--skip LargeSingleMessageTests`): **898 run (MailConnectivity 179 / 2 skipped, ArchiveCore
  719 / 22 skipped), 0 failed**, 0 warnings.

**Closeout 2026-11-18, gate 1 walk follow-up (fa72e0a..4dc5191).** The six items GATE1_UI_WALK_2026-11-18.md
left open, one commit each with a test that fails without it: identifiers (hashes, addresses, Message-IDs)
drawn by `IdentifierText` — iOS 27 no longer inserts hyphens and Copy returns the exact value (354c3ff);
v1 "Inbox" bucket renamed "Received" (0d9834d); Subjects panel re-reads after Trash / restore / import
(439834f); iPad / iPhone sidebar actions pinned (04188c7); home subtitle built from the supported-format
list, 5 keys x 10 languages (9e2fda7) and the chips no longer squeezed on a narrow iPhone (53cea1f); the
ordering-dependent testIPAD04 traced to the host app's launch `applyAll` landing after the test set
`SearchChunkPolicy.isEnabled`, V2SearchTests now wait for it (fa72e0a); the stale key 38d658d left removed
(4dc5191). Verified on 53cea1f, Debug-Connected My Mac: five-jobs gate **217 passed, 2 skipped (COMP14,
TYPE05), 0 failed**; IPadGate1Fix 17/17, V2Search 28/28, Review1116C 27/27, V3Lint 2/2,
InterfaceLocalization 8/8 (on 4dc5191). Builds iPhone 17, iPad Pro 11" (M5), My Mac build-for-testing:
no new warnings. Package not touched. Simulator re-checks and screenshots in the walk record.

**Pending Mac UI runs (owner present):**
- AccessibilityAuditUITests.testAccessibilityAudit_liveMailPage
- AccessibilityAuditUITests.testAccessibilityAudit_mainWindowAndModules (after the Live Mail page change)
- MailinClickThroughUITests.testFiveJourneys_release (J4 Inbox 3, J5 "3 of 3"; the restore change
  in 47006d0 has not been through it)
Gate check: OPEN-02 PST streaming test had started failing ("footprint grew 160 MB while streaming a
204 MB file") with the old and new PST reader sources alike. Per-batch measurement found no retention —
footprint +147, +157, then +109 MB flat to batch 20, live heap +51 then +60 MB flat; 4,000 messages /
409 MB: same plateau (+133 MB footprint, +60 MB live); the same per-message work with every result
discarded is flat on the main thread and rises ~150 MB on the cooperative pool (allocator regions, not
messages). The test now checks the live heap (< half the file) and the plateau after batch 5 (live heap
< one batch's share, footprint < a quarter of the file), and was shown to fail when the reader keeps each
message body (04e145d). Five-jobs gate on 04e145d: **214 passed, 2 skipped (COMP14, TYPE05 — owner-bound),
0 failed**.

Remaining, owner only: open the B13 `.msg` output in real Outlook; native-speaker review of the machine
translations (~150 keys from this review); the two skipped owner-bound tests (S/MIME keychain identity,
speech permission); review and push `v3-architecture`; a signed release candidate.

Every item below was fixed with a test that failed before the fix (or, for the
refactor-only items, a source check that failed on the old code / did not
compile against it), the touched classes run, build green, one commit per item.
Release check on 4d056c1 (Debug-Connected, My Mac): five-jobs gate
(V2CutoverTests + ConnectedFiveJobsTests + ConnectedFiveJobsFixPassTests)
**213 passed, 2 skipped (COMP14 S/MIME keychain identity, TYPE05 speech
permission — owner-bound), 0 failed**; every class touched or added today
(19 classes + the 2 new ProfessionalGating tests) 237 passed, 2 skipped
(T47 Release-only, offline-only workspace test), 0 failed; offline scheme
Review1116CTests + MailPolicyTests 34/34; package suite 883 run (MailConnectivity
178, 2 skipped; ArchiveCore 705, 22 skipped), 0 failed, with LargeSingleMessageTests
(11 tests, multi-GB files, 193 s) run on its own: 11/11. Builds: macOS, iPhone 17
simulator, iPad Air 11-inch (M4) simulator, offline macOS — all succeed; warnings
unchanged (the pre-existing SpeechPermissionSection macro warning and
ContentViewModel.swift:312 Sendable warning; none from this pass).

| ID | State | Commit(s) |
|---|---|---|
| A1, A4, A14 | Fixed | 68070e0 |
| A2, A3, A12, A15, A20 | Fixed (A2's TAR case is real: a PAX `size=9223372036854775807` or a base-256 size reached the overflow; now `size > fileSize - dataOffset`, a negative PAX size refused) | 8b3ce88 |
| A5–A10, A16, A17 | Fixed | ce3a457 |
| A11, A13, A18, A19 | Fixed (A18: NSF item placement has a step limit, 1<<24) | beada60 |
| B1 | Fixed | a36495b |
| B2, B7 | Fixed | c25f88c |
| B3, B10 | Fixed | 0de9dd7 |
| B4 | Fixed | f5a0e0b |
| B5 | Fixed | 857ef55 |
| B6 | Fixed (Spotlight Apple Intelligence summarisation off by default behind a setting; deletes reach both indexes) | 1c397c2, 215202a |
| B8, B9 | Fixed — B9 only for literals that end at a word boundary; mid-word literal a stated limit (D-1) | 1a00bc5, ade94be |
| B11 | Fixed | e87e5a9 |
| B12 | Fixed | 0de9dd7, 102d4a3 |
| B13 | Fixed in code (MS-OXMSG/MS-CFB structure, DIFAT, named reasons) — **Owner run**: not yet opened in real Outlook | f6ef254, 4a1ce38 |
| C1, C2, C3 | Fixed | 541cffb; 15194f2, 1e3e936; ac70905 |
| C4 | Fixed | df030e9 |
| C5, C6 | Fixed | 7f63f2f; 10011cf |
| C7, C8 | Fixed (app and package: "Deleted X of Y", package text through the catalog) | 7c0edeb, 2bced96, d172d13 |
| C9, C10, C11, C12, C13, C14 | Fixed | 3c9be7b, b03e614, 0b69ccd, f8802d6, 92949cd, 7e6122f |
| C15 | Fixed | bbfbf02 |
| C16 | Fixed | dd795b1 |
| C17 | Fixed | 7c0edeb |
| C18, C19, C20, C21 | Fixed | e9eabc5, 601190e, f739543, a0e97f4 |
| C22 | Fixed | 1a00bc5 |
| C23 | Fixed | 5145c6e, fe2bf4d |
| C24, C25 | Fixed | 2139f7f, 7cfba19 |
| D1 | Fixed | 34d9d3b |
| D2 | Fixed — `--uitest` honoured only in Debug builds (`UITestLaunch.isHonoured`, also Safe Mode's test-launch check). Note: the "maxmailin Release Tests" scheme also lists maxmailinUITests; UI tests that rely on `--uitest` now run only in Debug / Debug-Connected. D-4 (owner): stays Debug-only — the 24 UI tests cannot pass under "maxmailin Release Tests"; run them on Debug-Connected | 9486ee3 |
| D3 | Fixed — managed lock fails closed with a translated reason | bcfd95b |
| D4 | Fixed — `OSAllocatedUnfairLock` | 7d4e45c |
| D5 | Fixed — summary says this build contains no cloud AI. Kept in English like every legal text (Terms, both privacy summaries); translating the legal texts was an owner decision — D-3: they stay English, with a translated line saying so | 87c3973, a3a9835 |
| Rule 7 (latent connectors, token transport) | Fixed — token exchanges go through `MailNetworkPolicy.permitTokenExchange` per account (counted in Health; account-less refused; session built in init); legacy Gmail/Outlook/IMAP/SMTP connectors (reachable from no view, menu or intent) ask `LegacyMailTransportGate` before every socket/request and are refused (no policy account); legacy SMTP refuses AUTH without TLS/STARTTLS, a failing QUIT after 250 is "sent", a lost answer to DATA is "may have been sent" and compose never resends it. Still open in that dead code: its STARTTLS opens a new TLS connection instead of upgrading the socket (it cannot work; unreachable and blocked by the gate — **accepted**, owner 2026-11-16) | 430adc6 |
| Rule 8 | Fixed — every expert's findings (enhanceWithAI, digest narration, consults) and the structured triage pass the figures gate with the code-computed data as allowed source | 94ce6a1 |
| Rule 10 | Fixed (listed strings; saved/printed import receipt; package texts through the catalog) | 049c93a, 4d056c1, d172d13, b34d6c4 |
| Rule 11 (OCR fallback) | Fixed | 023ded2 |
| E registry SQL interpolation | Fixed | 7c0edeb |
| E FTS `clear()` | Fixed | 1a00bc5 |
| E `deleteReportingHeld` | Fixed (email_folders, message/part locators, attachment_children, search_docs/chunks; D-2: custom values, recovery, coverage, search registry; audit tables kept by decision) | 7c0edeb, b19f652 |
| E SearchSpecCompiler LIKE / confirmOperation | Fixed | 7c0edeb |
| E ArchiveDataService store error read as "no files inside" / "no text" | Fixed — the store error is thrown and stated (Contents list, recipe file search, unlock row, Show text) | ab4cd27 |
| E duplicate survivors across overlapping groups | Fixed | 72a216c |
| E AttachmentTextIndexJob whole-file load | Fixed | ea32b19 |
| E ExportRunCenter restoreAfterLaunch | Fixed | b1f6d62 |
| E IMAP UID MOVE with VANISHED, OAUTHBEARER escaping | Fixed | f6ef254 |
| E IMAPAdapter `after + 1` at UID 4294967295 | Fixed | beada60 |
| E MailLifecycleText server greeting | Fixed | a002158 |
| E ExportSigner silent new key | Fixed | f6ef254, 8e075af |
| E PSTSpecWriter preconditions | Fixed (thrown errors; 4 GiB item size a stated limit) | f6ef254 |
| E FoundationModelEngine state | Fixed — mutations were already inside `fmStateQueue`; the one read outside it and the answer-cache copy-then-write-back fixed | 142d2a3 |
| E HexViewerView | Fixed | 5d475bc |
| E `try! Regex` in loops | Fixed | 5d475bc |
| E PluginManager timeout | Fixed — cancelled, switched off, stated on the card; never started again while the abandoned call runs (in-process code cannot be killed) | f3d8f40 |

**Open / owner decisions** (resolutions 2026-11-16/17; the owner's decisions D-1…D-6)

1. Regex search pre-filter: a literal inside a word (`voice\s` in "invoice") cannot be pre-filtered — there is no unstemmed index. The filter now drops such literals (correct, slower). An unstemmed (trigram) index is an **owner decision** (index size, migration).
   **Resolved (D-1, stated limit):** no trigram index in this release; "a pattern's fixed text must start a word" is stated on the Limits page and in the search help — ade94be.
2. `deleteReportingHeld` still leaves rows in `email_custom_values`, `email_recovery`, coverage, `indexed_message`, `review_coding`, `custodian_assignments` and the forensic/custody tables. Some may be meant as audit trails — **owner decision** which are evidence and which are orphans.
   **Resolved (D-2):** custom values, recovery rows, attachment coverage and search registry rows go with a really deleted email; a held email keeps everything; forensic, custody, evidence seal, review_coding and custodian rows are kept as the audit record — b19f652.
3. MSG output (B13) not yet opened in real Outlook — **owner run**. **Still owner-only.**
4. 112 machine translations from the earlier review-fix commits, plus 29 keys added in this pass (D3, E login text, plugin stop, import receipt), not reviewed by a native speaker.
   **Still owner-only:** native-speaker review of ~150 keys (these plus the D-3/D-6/D-1 and package-text keys added in the closeout).
5. `.msg` attachment Content-IDs are not written — needs an ExportReconciliation rule change.
   **Resolved (D-5):** the writer writes PR_ATTACH_CONTENT_ID, PR_ATTACHMENT_HIDDEN and ATT_MHTML_REF; the reader and ExportReconciliation check them — d916f62.
6. NSF ODS reader's step-limit reason is logged, not shown on screen.
   **Resolved:** its own import category, named with the limit in the import summary and receipt — de60ff3.
7. Package error texts are English (IMAP limit messages, C7 "Deleted X of Y" inside the package).
   **Resolved:** looked up in the app's string catalog through `PackageLocalization.bundle` — d172d13; the eight new keys translated in 10 languages with a German resolve test — b34d6c4.
8. ArchiveDataService: a store error while listing an attachment's children or text still reads as "no files inside" / "no text" (see table).
   **Resolved:** thrown and stated — ab4cd27.
9. Test-target finding: `maxmailinTests` has no `MAILIN_CONNECTED_MAIL` condition in Debug-Connected / Release-Connected (the app target does), so the `#if MAILIN_CONNECTED_MAIL && !NO_NETWORK_BUILD` blocks inside V2VerificationTests (around the ConnectedMailProductionTransports / IMAPActionExecutor / sentLookup checks) never compile or run. Adding the condition to the test target needs a build-setting change (owner, Xcode).
   **Resolved:** the test target defines `MAILIN_TEST_CONFIGURATION_$(CONFIGURATION:identifier)`; the blocks compile and pass in Debug-Connected / Release-Connected, guarded by a test — d213d6b.
10. Owner decisions on the remaining rows:
    - **D-3 legal texts:** stay English; a translated line says so in every other interface language — a3a9835.
    - **D-4 UI tests:** `--uitest` stays Debug-only (D2, 9486ee3). The 24 UI tests that rely on it cannot pass under the "maxmailin Release Tests" scheme and must be run on Debug-Connected.
    - **D-6 search operators / Spotlight:** AND, OR, NOT are operators only in capitals on the search model too — 46aab88; What's New 4.0 explains it and that Spotlight summaries are off by default — 7d95199.
    - **Legacy SMTP STARTTLS** (Rule 7 row): its STARTTLS cannot work, but the connector is unreachable and blocked by `LegacyMailTransportGate` — **accepted** as is.


Scope: app target `maxmailin/` (365 files, 172,850 lines), package `Packages/ArchiveCore` (223 files, 88,016 lines),
on `v3-architecture` at f2ba312. Eight area reviews, every finding re-verified against the source and its callers
before listing; the headline items were spot-checked a second time by hand. Tests (142 files, 75,553 lines) were
read for coverage only; nothing was run.

Severity: **P0** crash / data loss / security bypass · **P1** wrong result or a broken never-broken rule ·
**P2** robustness, accounting, hardening. "Test" names the covering test or says none.

---

## A. Crashes reachable from a file, an attachment or a server (P0)

Swift traps on integer overflow and out-of-range subscripts, so each of these is a hard crash of the app.
Common cause: bounds checks written as `a + b <= count`, `Int(u64)`, or `first...min(last, cap)` that trap
*before* the comparison runs. One sweep with `Int(exactly:)` / `addingReportingOverflow` / explicit
`first <= cap` guards, plus one hostile-header test per format, closes the whole group.

| # | Where | Defect | Trigger | Test |
|---|---|---|---|---|
| A1 | `Packages/ArchiveCore/Sources/ArchiveCore/PSTSpecReader.swift:179, 213, 652`; `PSTParser.swift:429, 498, 552, 567, 618, 782` | `Int(ib)` on a file-supplied UInt64 traps when bit 63 is set; the `o >= 0` guard after it never runs | a PST whose root NBT child BREF has `ib = 0x8000_0000_0000_0000` → crash on open; `try?` does not catch a trap; the heuristic fallback reader has the same conversions | V3ParserFuzzTests cannot build a B-tree page: none |
| A2 | `ZIPArchiveReader.swift:280`, `TARReader.swift:131/153/176`, `SevenZipReader.swift:846`, `RARReader.swift:733`, `RARExtractor.swift:178` | `declaredSize + diskMarginBytes` (64 MiB) overflows when the declared size is near `Int64.max`, which each reader deliberately accepts | ZIP64 extra, TAR base-256 size, PAX `size=9223372036854775807`, 7z / RAR5 sizes → trap before the disk check | AuditWave1Tests F10 covers ZIP64 *offset* only: none |
| A3 | `CabinetReader.swift:241-245` | `cString` slices `b[pos...]` with no `pos <= b.count` guard (`name()` at :248 has it) | 60-byte `.onepkg` with `cbCFHeader = 0xFFFF` | none |
| A4 | `PSTSpecReader.swift:137,143` | guards 512 bytes then reads byte 513 | 512/513-byte `!BDN` file reached via `EmailParserProtocol.swift:78/577` and archive members (`ContainerReconciliation.swift:66`) which skip SourcePreflight | none |
| A5 | `OfficeTextExtractor.swift:685`, `XLSBReader.swift:336` | `first...min(last, maxColumn)` with `first > maxColumn` → "Range requires lowerBound <= upperBound" | any `.xlsx` with `<col min="20000" max="30000" hidden="1"/>` while indexing attachments | OfficeRevisionsAndCellsTests in-range only |
| A6 | `DocumentTextExtractors.swift:654-665, 681-682, 559-560`; `IWATableDecoder.swift:356-357, 363` | protobuf varint can produce `Int.min` / `Int.max`; `n + length <= count` passes then the range traps or overflows | any `.pages/.numbers/.key` IWA chunk starting `80×9 01` or `FF×8 7F` | IWATableDecoderTests well-formed only |
| A7 | `IWATableDecoder.swift:127, 269` | `tileID * tileSize + rowInTile` unchecked; `Int64(n)` of a raw f64 (`1e300`, `+inf`) traps (`number()` guards finiteness, `duration` does not) | crafted Numbers tile | none |
| A8 | `OneNoteTextExtractor.swift:525 (→589/771/786), 1114, 258` | `stp + cb` overflows inside the guard; `Int(clamping:)` → `Int.max` then `pos + n` traps | header bytes 172–179 = `FF…7F` | OneNoteReaderTests well-formed only |
| A9 | `XLSBFormulaDecoder.swift:571` | `cols * rows <= 1 << 20` overflows before comparing | PtgArray rgcb `FF×8` | none |
| A10 | `ExcelCellFormats.swift:328, 348`; `ExcelNumberFormatRenderer.swift:569` | `row + rowDelta` before the range guard; `Int(pow(10, 19+))` | shared formula with `r="9223372036854775807"`; `formatCode="0/0000000000000000000"` | none |
| A11 | `ForensicSignals.swift:375, 464, 480, 612-613` | `1...n` with n=0; `prefix(-1)` from `DKIM l=-1`; DER `bitLen == 0` slice | one hostile header, examiner opens Forensic Signals | none |
| A12 | `DocumentTextExtractors.swift:1298` | unchecked Int64 sum on a ZIP64 local-header offset, runs before the file-size check whenever a `.z01` sibling exists | split zip with offset `0x7FFF_FFFF_FFFF_FFFF` | none |
| A13 | `Packages/ArchiveCore/Sources/MailConnectivity/IMAP/IMAPResponseReader.swift:468` | `":".split(separator: ":")` is `[]`, then `ends[0]` traps | server sends `* ESEARCH … UID ALL :`, a `VANISHED :`, or `COPYUID … :` (`IMAPSession.swift:547, 570`, `IMAPActionExecutor.swift:276`); also persisted change tokens (`IMAPAdapter.swift:214`) | IMAPProtocolTests.testUIDSet covers `""` and `"1:*"` only |

Resource exhaustion (hang / memory) from one file, all **P1**, no stated budget (rule 6):

- A14 `PSTSpecReader.swift:231-244, 305-322`; `PSTParser.swift:761-779` — data-tree expansion has no visited set: an XBLOCK listing the same child 8,000× under an XXBLOCK → multi-TB append; `bth` recursion b^levels with no cancellation.
- A15 `CabinetReader.swift:133-172` — whole CAB folder inflated and cached (65,535 × 32 KiB = 2 GiB from a 3 MB `.onepkg`); `OneNoteTextExtractor.swift:172-195` checks input size but `extract` still builds the whole folder.
- A16 `OfficeTextExtractor.swift:348-370` → `DocumentTextExtractors.swift:1176` — each `/embeddings/` member re-enters the public extractor at `depth: 1` with a fresh byte budget: docx-in-docx chains recurse without bound (stack overflow on a worker thread); an embedded zip bomb skips `archiveDepth` / `totalArchiveBytes`.
- A17 `OneNoteTextExtractor.swift:828-837` — `walk` dedups by path only; 60 objects each referencing the next twice → 2^60 walks (the FSSHTTPB path at :1297 has the right permanent `visited` set).
- A18 `NSFODSReader.swift:643-661` — item placement O(n³–n⁴) over up to 65,535 items, no cancellation.
- A19 `IMAPResponseReader.swift:162, 172, 227, 339`; `GmailRawStreamDecoder.swift:138` — literal `{n}` accepted to 18 digits and buffered whole; `line` grows until LF; `value()` recurses per `(`; `metadataJSON` grows despite the "never held whole" contract.
- A20 `ZIPArchiveReader.swift:180` — whole central directory read in one `read` (bounded only by file size).

## B. Data loss, wrong data, security (P0/P1)

- **B1 P0 — Restore swaps the database under a connection that can be reopened mid-restore.** `maxmailin/ArchiveBackups.swift:209-213` calls `reopenConnection()` (sets `db = nil`) then runs the long synchronous `ArchiveBackup.restore` *off the store actor*. Any store call in that window (attachment indexer, list refresh, Health, Spotlight) lazily reopens on the OLD file (`SQLiteEmailStore.swift:515-516`); `replaceItemAt` then swaps the inode under the open handle and `schemaVersion()` does not reopen because the handle is cached. Every write until relaunch goes to an unlinked file and is lost. (The in-actor `SQLiteEmailStore.restore(from:)` at :679 is safe.) Test: `testRestoreIntoRunningArchive_…` has no concurrent store user.
- **B2 P0 — Orphan-blob GC can delete a connected capture's bytes before its row commits.** `SQLiteEmailStore.swift:167-173` ("safe to call at any time") → `BlobStore.swift:236-248` (no age grace). `ConnectedArchiveSink.swift:461` publishes the blob, then several actor hops, then `commitConnectedCapture` at :498. A file import finishing in between (`BulkImportCoordinator.swift:1271`) unlinks the digest; the row then points at nothing, the item is `stored`, staging removed. Test: none interleaves GC. Fix: age grace on GC, or register in-flight digests.
- **B3 P1 — 8-bit bodies with no Content-Transfer-Encoding header are double-decoded.** `MIMEParser.swift:239-246` `default:` branch (the RFC 2045 default when the header is absent) skips the `latin1DecodedBytes` recovery the explicit `7bit/8bit/binary` case does (:226-238). `caf\xE9` with `charset=iso-8859-1` and no CTE → stored and indexed as "cafÃ©". Same family as a86d2c9. Test: none on this path.
- **B4 P1 — S/MIME "Valid — Trusted Signer" without an S/MIME policy or a From match.** `maxmailin/SMIMEHandler.swift:167` (and `SMIMEPortable.swift:82`) use `SecPolicyCreateBasicX509()`; `signerEmail` is never compared with `From`; `EmailDetailView.swift:2310-2327` shows the seal from status alone. A mail `From: ceo@bank.com` signed with any publicly trusted cert (even a TLS cert for someone else) shows Trusted Signer. Test: SMIMEGoldCaseTests assert the extracted address only.
- **B5 P1 — T02 zero-network gap in the sanitiser.** `maxmailin/SafeHTMLRenderer.swift:150-152` exempts any attribute value starting `data:`/`cid:`, so `srcset="data:…, https://t.example/px.gif 2x"` survives; the WebKit path is saved by the CSP meta but the print/PDF importer sites (`EmailDetailView.swift:1870, 2032`) have no backstop. Test: `V2VerificationTests:10554` relative-first only.
- **B6 P1 — Spotlight hands every body to Apple Intelligence with no switch.** `maxmailin/SpotlightIndexer.swift:78, 149` sets `updateListenerOptions = [.summarization, .priority]` unconditionally; callers `ContentView.swift:4910`, `ArchiveLifecycleService.swift:133` check no toggle. CLAUDE.md names Spotlight PCC mode an online feature off by default; no toggle exists. Also :156 vs :246/:257 use different index objects, so flipping `v3SemanticSearch` mid-session leaves deleted mail searchable. Test: none.
- **B7 P1 — Folder backfill (v21) drops memberships at every 20,000-row page boundary.** `FolderModel.swift:85-113` combines a `(email_id, tag)` keyset cursor with `NOT EXISTS (… ef.email_id = t.email_id)`; after page N inserts `(X, Inbox)`, page N+1 excludes X, so `(X, Work)` is never backfilled. Also used by `rebuildFoldersFromTags` (:207). `email_tags` is intact (rule 16 holds) but the folder tree / `folder:` filter is wrong. Test: `V2CutoverTests:1585-1603` one email.
- **B8 P1 — FTS query loops treat any non-ROW step result as end of results, and the free-text builder emits invalid FTS5.** `FTSSearchIndex.swift:443, 564, 656, 707, 855, 911, 946` (`while sqlite3_step == SQLITE_ROW`); builder :56-66: `"not guilty"` → `NOT "guilty"*`, `"report and"` → `"report" AND`, `-spam budget` → `NOT "-spam" "budget"*`. A syntax error (or a busy/corrupt shard) is shown as "No results". The store's own `stepRow` throws on this; the index does not. Reached from `EmailRepository.swift:330/416`, `ArchiveDataService.swift:109`, `ParsedEmailListViewModel.swift:1269/1377`. Test: single-word only.
- **B9 P1 — Regex search's literal pre-filter goes through the porter tokenizer and misses true matches.** `FTSSearchIndex.swift:1728-1729`: `runn\w+` → `"runn"*` → porter("runn") is not a prefix of indexed `run` → zero candidates, `truncated == false`. The comment "a missing literal only costs speed, never correctness" is false. Test uses `invoice` (stem-stable).
- **B10 P1 — Gmail-over-IMAP retry marks a still-present message `unavailable`.** `IMAPAdapter.swift:703-705, 737` with `SyncEngine.swift:706, 743-744, 774`: retried items carry `folder: nil`; when All Mail is hidden `places` is empty, `fetchGmail` throws `.itemUnavailable`, recorded as terminal "Deleted or moved on the server"; its UID is already in `known`, so it is never re-listed until UIDVALIDITY changes. Fix: `UID SEARCH X-GM-MSGID` in any listed folder. Test: the stated-limit test only.
- **B11 P1 — iOS per-message PDF export clips to one page; iOS "TIFF" writes PNG bytes with a `.tiff` name.** `maxmailin/ExportManager.swift:889-902` (PDF, single `beginPage()` into a 692-pt rect), `:191-208` (TIFF), reached from `ArchiveExportService+Renderers.swift:25, 40`; `UnifiedExportMenu.swift:93-100` offers both on iPhone/iPad. Receipt says complete; reconciliation marks rendered formats unverifiable so Verify cannot catch it. Test: none references `exportPDFFiles` / `exportTIFFFiles`.
- **B12 P1 — "Also save attachments" saves nothing for imported mail and is receipted complete.** `ArchiveExportService.swift:1173` `guard let source = att.fileURL else { continue }`; store-loaded attachments never carry `fileURL` (`SQLiteEmailStore.swift:4408, 5358`), and unlike the PST/MSG/EML writers this path does not use `AttachmentHydrator`; failures only logged (:1185-1187); `ExportPreflight.swift:579` discards the result. Test: none.
- **B13 P1 — `.msg` writer is not MS-OXMSG-consistent and is verified only against mailin's own reader.** `MSGWriter.swift`: no `__nameid_version1.0` storage, no recipient storages, properties stream lacks entries for the variable-length properties written, PR_MESSAGE_CLASS has an entry but no `__substg1.0_001A001F` stream; `write(email:)` returns nil on any error (:13-20) so `exportMSGFiles` counts `skipped` with the reason only in the log; `fatSectorCount <= 109` (:363, ≈457 MB, no DIFAT) is an undisclosed cap. Tests round-trip through `MSGParser` (verify-vs-self).

## C. Never-broken rules (P1 unless noted)

**Rule 3 — never renumber Bates:**
- C1 `maxmailin/ProductionWindowView.swift:216, 272-274, 318` — `produce` numbers from the raw "Start at" stepper (`1...`), not `nextFreeNumber()`, assigns to every included email without checking `bates.assignments[email.id]`, and `merge` overwrites. A second production over an overlapping scope renumbers; lowering the stepper reuses ranges. Test: none for `produce`.
- C2 `maxmailin/BatesNumberingManager.swift:229` creates a second live `BatesNumberingManager` (`@StateObject`) beside `.shared` (used by `ProductionWindowView.swift:49`, `ParsedEmailListView.swift:2564`, `MailinAppEntities.swift:316`, `ForensicReviewManager.swift:299`); both persist to the same UserDefaults key from their own dictionary, so the last writer wins and numbers get reissued after relaunch. Test: none.
- C3 `maxmailin/BatesEngine.swift:93-95`, `BatesNumberingManager.swift:509-513` — v3 `number()` commits per 2,000-row batch; a later batch failing → `manager.merge` never runs, the legacy fallback assigns from a `nextFreeNumber()` that ignores committed DB numbers → two emails per number on the next v3 run. Test: none.

**Rule 4 — affected count before whole-archive actions:**
- C4 `maxmailin/ArchiveMaintenance.swift:141-148` (from `ArchiveHealthView.swift:206-212`, `CrashSafety.swift:201-207`) — `restoreLatestInteractively()` confirms only inside `#if os(macOS)`; on iOS one tap replaces the live database with no count. Test: none.
- C5 `maxmailin/AgenticPlanner.swift:160-181` — when `onConfirmAction` is `nil` (the default at `FoundationModelEngine.swift:5474, 5542`) a destructive step prints "Confirmation needed" then runs anyway; today's only caller passes a handler, so latent. Also :699-703 tags per email through `ForensicManager.tag` → one audit row and one team auto-export per email (2,000 at once) where `BatchOperationsEngine.apply` pages and logs once. Test: none (0 files reference `AgenticPlanner`).

**Rule 5 — audit/receipt only after the action; partial says X of Y:**
- C6 `maxmailin/WatchFolderManager.swift:182-183, 209-218` — "N imported", `lastImportDate` and `knownFiles.insert` recorded when the file *parses*; the archive write happens later via `.newEmailsImported` → `TriageQueueService.swift:83-89`. Failure = log says imported, nothing stored, never retried. Log silently capped at 50 (:53, :215).
- C7 `SQLiteEmailStore+ConnectedLifecycle.swift:313-330` with `MailWorkspaceBackend.swift:509-517` — account-archive deletion is per-page transactional; FTS is purged for all ids *before* the store delete; a page-3-of-7 failure leaves pages 3–7 in the archive but unsearchable, with no "X of Y". Test: happy path only.
- C8 `ChildHashRepair.swift:178-182, 203-217, 284-286` — a throwing repair is counted `failed` but the cursor advances and the run is marked `completed`; `reportText` omits failures.
- C9 `maxmailin/PreservationExporter.swift:81` — `try? rawBytes` turns a transient read error into a permanent PREMIS `noOriginalAvailable` event.
- C10 `maxmailin/MailClientHandoffViews.swift:374-379` — receipt built with `requested: records, written: records` (can never read X of Y), `startedAt: Date()` at the end.
- C11 `maxmailin/MailOrganize.swift:388-420` — bulk server actions: thrown / `.rejected` / `.conflict` / `.uncertain` rows are not counted; "Changed 7 of 10" explains only ineligible rows.
- C12 (P2) `maxmailin/ForensicManager.swift:537-548, 593-596` — chain root saved synchronously, the row appended in a detached Task; termination between them → false "TAMPERED" verdict until the next action.
- C13 (P2) `maxmailin/ArchiveWideLists.swift:178-183` — `catch {}` then `onSelect(ids)` with the pages that arrived.
- C14 (P2) `maxmailin/DuplicateManagerView.swift:670-675` — any store error → empty list, `archiveDupChecked = true`; user concludes no archive-wide duplicates.

**Rule 6 — no hidden caps, real limits on screen:**
- C15 `maxmailin/AuditTrailView.swift:88-105, 147` — filters, counts and the header read the 500-entry memory window (`ForensicManager.swift:62, 535`); `auditTotalCount` exists but is unused; a search for an older action says "No entries match".
- C16 `maxmailin/AppIntentShortcuts.swift:34, 152-156, 186-198, 222-227, 268-270` — legacy intents (`AskAIAboutEmails`, `GetDigest`, `AnalyzeSentiment`, `GetSecurityReport`) skip `modules.isEnabled`, `ShortcutsPolicy.requireEnabled()` and `freeAIQueryCount`; `recentEmails` uses `if acc.count >= limit { break }`. Siri runs the on-device model on a Page-1-only Free install, unlimited.
- C17 `SQLiteEmailStore.swift:2993-2995` — `instance(wf:)` = `instances(limit: 10000).first { … }`: beyond 10,000 workflow runs an older WF silently resumes as nothing (`WorkflowRunnerView.swift:1172, 1224`, both `try?`).
- C18 `maxmailin/AppLimits.swift:71-72` says Free import size is "Per import" while `StoreManager.swift:129-133` is cumulative; `MailinMoreEntities.swift:159` says "up to 10,000 per run" while the code returns everything; Free import truncation at `maxEmails: 500` (`ContentView.swift:4045`) is described on the Limits page as a reading/search rule.
- C19 `maxmailin/PracticalRecipesView.swift:66` `recent.prefix(5)` with no "more exist"; `RecipeRunAdapters.swift:128`, `PracticalRecipes.swift:462` `lookupDocuments(limit: 5)` → once five newer documents mention the number, `verify` reports a finished clean-up `.unverifiable`.
- C20 `maxmailin/FoundationModelEngine.swift:4801, 4814-4815` — "Overall tone shifted" computed on `emails.prefix(100)`; dead today (`precomputeOnImport` has no callers) but ships as-is if re-wired.
- C21 `PersonalEmailOrganizerView.swift:343, 1729`, `JournalistInvestigationView.swift:1601` — the disclosed 2,000 working set is labelled "Total Emails" / "N total emails" in stat cards and report text.
- C22 `FTSSearchIndex.swift:1230-1234` — `partiallyIndexedCountSnapshot` reads shards from the hard-coded default root, not `ArchiveLayout.productionRoot`; after a relocation Search Coverage counts the retired copy or 0 (`SearchCoverage.swift:154`, `SearchCoverageBadge.swift:160`, `ImportReceiptView.swift:128`).

**Rule 7 — offline-first:** B6 above. Latent: `GmailConnector.swift:92`, `OutlookConnector.swift:262, 291`, `IMAPClient.swift:110`, `SMTPClient.swift:116, 186` open `URLSession.shared` / `NWConnection` without `MailNetworkPolicy`; `SMTPClient.swift:85-90 → 217-220` falls back to plaintext `AUTH PLAIN` when STARTTLS is absent; `ComposeEmailView.swift:177-193` resends the whole message if `QUIT` throws after 250. Unreachable from any view/menu/intent today, but they are the only network code outside the policy. `ConnectedMailRuntime.swift:1029-1034` `PolicyCheckedTokenTransport.postForm` checks a policy snapshot, not `policy.permit`, so token exchanges are neither counted in Health nor checked per account; `lazy var session` on an `@unchecked Sendable` class races.

**Rule 8 — counts in code:** `FoundationModelEngine.swift:5532` is the sole caller of `AIGroundingGate.removingUnsupportedFigures`; `enhanceWithAI` (:2023), `triageStructured` (:2894), expert consults and digest narration return model prose unfiltered.

**Rule 10 — every user-facing string localized** (English-only on all 10 languages; catalog has 0 entries for the ones checked):
`ExportPreflight.swift:138-141, 260-264, 593-619, 649`; `ExportRunCenter.swift:632`; `UnifiedExportMenu.swift:154-156`; `GuidedImportSheet.swift:206, 268, 318, 373, 403-419`; `ImportReceiptView.swift:132, 178, 215-224, 271, 317, 335, 518`; `ParsedEmailListViewModel.swift:729, 1328, 1342, 1363, 1369, 1374`; `SearchCoverageBadge.swift:117-119`; `MailClientHandoffViews.swift:88-102, 183-185, 273, 318-331, 341-342, 357, 362`; `PracticalRecipesView.swift:288`; `SpotlightIndexer.swift:63, 219` ("(No Subject)").

**Rule 11 — every change ships with a failing-then-passing test:** the 2026-11-16 OCR fallback (`maxmailin/AttachmentOCR.swift:121-132`) shipped with no test; the fallback flag is sticky for the process after one error on every Mac, interacts with the 11-15 retry so accurate never gets its second try, and the downgrade is recorded nowhere (Outcome, Health languages list).

**Rule 14/15 — switches and crash trips:**
- C23 `maxmailin/EngineGuard.swift:80`, `CapabilityWiring.swift:250-254`, `ScopeJob.swift:390, 475` — breadcrumbs exist for ~17 of the engines; none for `v3SQLiteHygiene`, `v3Snapshots`, `v3PagedLists`, `v3SemanticSearch`, `v3SearchOperators`, `v3Threads`, `v3AIAnswers`, `v3LegalReview`, `v3EvidenceReceipts`, `v3PSTSpecReader`, `v3PSTSpecWriter`, all `v31*`, `streamingBinaryParsers`, `selfContainedArchive`, `searchQueryModel`, `notesODSReader`, `attachmentOCR`, `attachmentSpeech`, `protectedMessageDecrypt`; the package has no equivalent. `applyStoreLevelEarly()` arms store-level engines from raw `isCapabilitySet` before `checkAtLaunch` / Safe Mode. A PST that crashes the spec reader crashes again on every launch with no banner. Test: trip/restore for one engine only.
- C24 `maxmailin/CapabilityMatrixView.swift:263-270` — `noteUserChoice` runs before the switch-off is confirmed; cancelling still blocks the new-version restore.
- C25 `maxmailin/EngineGuard.swift:144-155` — sync `withFallback` treats `CancellationError` as an engine failure (no callers today).

## D. Tier / purchase / lock

- D1 P1 — Professional tools are gated per button, not in the tool or in `setOpen`. `mailinApp.swift:785-808`, `ContentView+Modifiers.swift:941`, `PersonaManager.swift:551`, `ContentView.swift:1313, 1331-1334, 2549-2556, 3439-3444`: Mac menu items (Bates, E-Discovery, PII Redaction, GDPR, Chain of Custody, Custodian Manager, Review Batches) are enabled by `forensicManager.isEnabled` alone; forensic mode turns on without a purchase via the Forensic persona (`showForensicByDefault`) or ⌘K "Toggle Forensic Mode"; "Generate Investigation Report…" has no gate on any path; tool views contain zero tier checks. A lapsed subscriber keeps every tool. Test: ProfessionalGatingTests covers page switches only.
- D2 P2 — `maxmailin/UITestSupport.swift:18-35, 48-69`, `mailinApp.swift:268-271`: `--uitest` honoured in Release (pre-accepts Terms, completes persona, imports demo mbox, can turn on connected mail via env).
- D3 P2 — `maxmailin/BiometricLockManager.swift:103-109`: with no device-owner policy the managed HARD lock sets `isLocked = false`, `isEnabled = false` and returns true.
- D4 P2 — `TierAccess.swift:21`, `MailinAppEntities.swift:24`: `nonisolated(unsafe)` tier/switch statics written on main, read from nonisolated intent code.
- D5 P2 — `maxmailin/LegalComplianceManager.swift:89, 93` (shown at `AboutView.swift:246`): privacy summary describes Cloud AI "to OpenAI or Anthropic"; `MAILIN_CLOUD_AI` is set in no configuration.

## E. Other robustness (P2)

- `SQLiteEmailStore.swift:2837, 2855, 2919-2922, 3087-3088, 3103, 3106` — the old workflow/document registry interpolates app-generated strings into SQL (every other query binds); a `'` from `reverseDocument` / `instance(wf:)` UI input fails the statement.
- `FTSSearchIndex.swift:724-728` — `clear()` not transactional: crash between the two DELETEs leaves the registry saying indexed with no content; the reconciler never re-indexes those.
- `SQLiteEmailStore.swift:5889-5899` — `deleteReportingHeld` leaves `email_folders`, `message_locators`, `part_locators`, `search_docs`/`search_chunks`, `attachment_children` rows (FKs off); backup inventory counts locators of deleted mail.
- `SearchSpecCompiler.swift:369` — user extension bound into `LIKE` without escaping `%`/`_`. `ArchiveDataService.swift:218-233` — store error rendered as "no files inside"/"no text". `confirmOperation` (:2903-2933) three statements outside a transaction, history insert result ignored.
- `maxmailin/DuplicateVerification.swift:174-188` with `DuplicateCleanup.swift:49-65` — survivors chosen per group independently; overlapping exact/near groups can merge C's tags into B that plan 1 trashes.
- `maxmailin/AttachmentTextIndexJob.swift:1653, 1697-1698, 1765` — `Data(contentsOf:)` loads the whole attachment after the streamed path decoded it to a temp file; 1.5 GB video on iPhone → jetsam, pass restarts on the same email.
- `maxmailin/ExportRunCenter.swift:192-199` — `restoreAfterLaunch` looks at `list().first` only; an interrupted export followed by a completed one is never offered for resume.
- `IMAPActionExecutor.swift:168-169` — `UID MOVE` without COPYUID inferred only from `EXPUNGE`; with QRESYNC servers send `VANISHED`, so a completed move is recorded `.conflict`. `IMAPAdapter.swift:608, 622` — `after + 1` traps at UID 4294967295 with no UIDNEXT. `IMAPSession.swift:434` — OAUTHBEARER login not saslname-escaped (`,` `=`).
- `MailLifecycleText.swift:83, 89` — server greeting interpolated into UI without `isPresentable`.
- `ExportSigner.swift:157` — `try?` silently generates a new signing key when the keychain blob fails to parse; older `.sig` files unverifiable with the published key, no notice. `PSTSpecWriter.swift:421, 498, 532, 547, 552, 683` — `precondition` where a thrown error belongs.
- `FoundationModelEngine.swift:3535-3536, 3568-3580` — `conversationHistory` / `semanticFacts` mutated outside `fmStateQueue` (verify call sites). `HexViewerView.swift:9-12` — whole raw source copied twice per redraw. `AIAssistantView.swift:2646`, `AIGroundingGate.swift:570, 584` — `try! Regex` on constants inside loops (hoist to `static let`). `PluginManager.swift:110-131` — timeout abandons, does not stop, a plugin.

## F. Checked and found sound

Migrations additive, each in one EXCLUSIVE transaction with snapshot first and refuse-newer guard (rules 1/2). `insertBatch` commits rows, locators, folders, chunks and the checkpoint per chunk with rollback; blob fsync before row. All `EmailQuery` filters bind; keyset paging predicates match ORDER BY in every sort. `DuplicateCleanup` merges memberships/tags/notes before trashing, never deletes, checks holds regardless of gate. `StreamingZIPWriter` (ZIP64, EOCD64, all-or-nothing rename), `exportTextDocument`/`exportMessageFiles` (truncate-to-checkpoint, length+hash resume gate, manifest before receipt), `ExportReconciliation` (independent re-parse against archive records). CMS/OpenPGP verifiers: no bypass found; Argon2 bounds; PBKDF2 ≤ 10M. OLE2, LZMA/LZMA2, 7z headers, RAR 1.5–5, TNEF, QP, Offset MBOX scanner/engine, `pendingRange` resume math, EMLX, NotesCX. Connected mail: Keychain-only secrets, redacted protocol log, PKCE S256 + constant-time state, no client secret, no pre-TLS credentials, quoted/literal astrings (no injection), UID-only actions with UIDVALIDITY re-check, journal executing-before/outcome-after, every page token followed, checkpoints advance only when every item is terminal, outbox persists `submitting` before the irreversible step and never auto-resends an uncertain outcome. `MailNetworkPolicy` is the single live gate; offline build compiles no transport; BYOK AI scaffolding has no button/menu/intent. Licence verification (Ed25519, clock high-water mark), HMAC chain external anchor, `effectiveTier` used where a gate exists, no Release-reachable debug tier override. Script sandbox (no eval, watchdog, 64 KB cap, batched proposals). All 40 `Task.detached` sites hop back to MainActor. No `fatalError`/`as!` reachable from data anywhere; 3 `try!` on constant regexes.

## G. Recommended order

1. **A1–A13 + A14–A17** as one sweep (checked arithmetic, visited sets, depth passed through), with one hostile-header fixture test per reader; these are the only things that crash the app on a file.
2. **B1, B2** (restore in-actor or hold the actor for the swap; GC grace / in-flight registry) — the two data-loss paths.
3. **B4, B5, B6** — security/privacy claims the app makes on screen.
4. **C1–C3** Bates (one authority for "next free number"; `produce` consults assignments), **D1** (gate in `setOpen` or the tool view), **C16** intents.
5. **B3, B7, B8, B9, B10, B11, B12** — wrong data / silent "no results" / silent empty export.
6. Rule 5/6/10 accounting and strings (C4–C22), then rule 15 coverage (C23) with a test asserting every `Capability.v3Engines` member has a breadcrumb.

Each fix: failing test first, five-jobs tests + touched classes, build green, commit, tracker row.

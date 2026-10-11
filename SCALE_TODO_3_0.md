# mailin 3.0 — Master Plan (single source of truth)

Owner decision 2026-10-10: go all out in 3.0 so the app does not need structural revision for a long time.
This file is the plan **and** the progress tracker. Every session: read §1–§2, pick the next unchecked item
in §4 order, do it to its "done means", tick it here with the commit hash, commit.

Status: `[ ]` to do · `[~]` in progress · `[x]` done (commit) · `[-]` dropped (reason)

**Working mode (owner, 2026-10-10): implement first, test after.** Implement the whole plan behind OFF
switches, keeping the build compiling, without per-item test runs; then one full test-and-fix pass writes the
tests each item's "done means" calls for, runs everything and fixes. Items are `[~]` (implemented, untested)
until that pass, `[x]` after it. Gates in §4 are checked in the test pass, not between steps.

---

## 0. The promise we are building

> **Every tool works on the whole archive, at any size, on every supported device. Memory stays flat. Work
> survives interruptions. Every legal result can be proven and reproduced. Nothing claims more than it did.**

The only limits left are real ones, each stated on screen where it applies: disk space; time (grows in a
straight line with size); the on-device AI model reads **4,096 tokens per session** (Apple docs); display
pages and "top N of M"; file-format limits (PST 50 GB per file, FAT32 4 GB per file — exports split); the
Free plan's newest-500 rule (a pricing decision). SQLite itself allows ~17.5 TB per database at the default
page size — far beyond any email archive.

**3.0 is "complete" when:** every item in §3 is `[x]` or `[-]` with a reason; every gate in §4 passed; §3-V
verification passed and recorded; all strings translated; App Store metadata, privacy labels and
Accessibility Nutrition Labels match what the app really does; `SUPPORTED_FORMATS_AND_LIMITS.md` lists only
real limits.

## 1. Non-negotiable rules (apply to every change, every session)

1. **Never destroy old data in 3.0.** Migrations copy, verify one-for-one, and keep the old files read-only.
2. **Snapshot before every schema migration** (S1). No snapshot → no migration.
3. **Never renumber Bates.** Existing assignments are permanent; new emails only continue the sequence.
4. **Count before acting.** Every whole-archive action shows "This will affect N emails" first.
5. **Honest outcomes.** Audit entries and numbered documents are written only *after* the thing happened;
   saves report saved / shared / cancelled / failed (`PlatformExport`, `ExportOutcome`); partial work says
   "X of Y". No `try?` on writes the user asked for. No `_ =` on a save result.
6. **No hidden caps.** Stream in batches (`streamFullEmails` / `streamSelected`); never `workingSet(cap:)`,
   never `if acc.count >= N { break }`. A real limit is shown on screen.
7. **Offline-first.** Nothing leaves the device unless an online feature's toggle is on. Apple's Private Cloud
   Compute model, RFC 3161 time-stamping and Spotlight's PCC search mode are **online** features: off by default.
8. **Counts in code, the model narrates.** The AI never counts; tools/SQL count, the model words the answer.
9. **Minimum touch.** Fewest clicks; sensible defaults; progress visible; resumes by itself.
10. **Every new user-facing string is translated into all 10 languages** before the step is called done
    (`~/mailin-loc-work/keys-*.py` pattern; write the catalog with `json.dumps(indent=2, separators=(',', ' : '))`,
    no `sort_keys`).
11. **Tests first-class:** each item ships with a test that fails without it. Suite green before commit.
12. **Never edit `project.pbxproj` by hand while Xcode is open** (new files are picked up by synchronized groups).
13. **Commit after each step** with the suite green, so any step is a safe place to stop and ship.
14. **Old code is switched off, never ripped out, in 3.0.** Every rebuilt engine or tool ships as a new
    capability in the matrix (`Capability.swift`) next to the old code path. The old path is left untouched
    (bug fixes only) and runs whenever the new capability is off. New code goes in new files; one dispatch seam
    per tool chooses old or new. More code is accepted in exchange for a rollback switch on everything.
15. **New engines default OFF** (`maturity: .preview`) until their gate passes; promotion to on-by-default is
    a deliberate, recorded step (§3-M5). A crash while a new engine runs switches it off automatically (§3-M2).
16. **Both engines see the same data.** State the new code moves (holds, seals, coding…) stays readable by
    the old path for the whole of 3.0 (dual-write or a read adapter), so switching back loses nothing.

## 2. Target architecture (what everything converges on)

```
            ┌────────────────────────────────────────────────────────────────┐
 Import ──▶ │ Archive store (SQLite, WAL, checkpoint_fullfsync on macOS,      │
            │ snapshots, explicit file protection)                            │
            │  ├─ emails / blobs / FTS                                        │
            │  ├─ feature index  (extends `derived`: once per email, versioned)│
            │  ├─ legal state    (holds, seals, custodians, custody, coding)  │
            │  └─ fingerprint tree (Merkle over per-email hashes)             │
            └───────────────┬────────────────────────────────────────────────┘
                            │
      ┌─────────────────────┼──────────────────────────┐
      ▼                     ▼                          ▼
 Scope engine          Queries                     AI layer
 (batches, progress,   (SQL over feature index:    (FoundationModels Tools that call
  cancel, resume,       counts, top-K with totals,  the queries; 4,096-token budget;
  receipts, iOS         paging)                     retrieval for narrative; prompts
  BGContinuedProcessing)                            versioned)
      │                     │                          │
      └──────────▶  Tools = small recipes / queries  ◀──┘
                            │
                 Receipt: scope + revision + fingerprint of the exact email set
```

## 2b. What we already have, and what changes (checked against the code 2026-10-10)

**Keep and build on (already in the code):**

| Have | Where | Used by plan items |
|---|---|---|
| Capability matrix: per-capability on/off, maturity (stable/preview/experimental), `requires`, "off never destroys", page gating | `Capability.swift`, `ModuleRegistry.isOn`, `CapabilityWiring`, `CapabilityMatrixView` | M1–M5 (engine switches), every rebuilt tool |
| Old-engine fallback precedent: offset parser ↔ streaming parser, locator reads ↔ stored MIME | `Capability.offsetParser`, `.locatorReads` | pattern for every M switch |
| Streamed exports with progress, cancel, receipts, signatures | `ArchiveExportService`, `ExportRunCenter`, `ExportReceiptStore`, `ExportSigner` | F1 scope engine, L5, E1 |
| Import checkpoints / resume | `ImportCheckpointStore` | F2 resumable jobs |
| Per-email results table, versioned + incremental, background job | `derived` table, `ArchiveDerivedAnalysis` | F6 feature index |
| Adaptive batch sizing + memory pressure handling | `AdaptiveBatchController`, `MemoryPressureHandler` | F1, C7 |
| Tamper-evident audit chain; sealed numbered documents | `HMACChainAuditLog`, `DocumentRegistry` (Ed25519 receipts) | E1, F5 |
| Per-email hashes (store keeps first seal); evidence seals (set once since 2026-10-09) | `ForensicManager`, `CustodianManager` | F5 fingerprint tree |
| Integrity check at storage activation; ENOSPC/fault tests; 1 GB format fixtures; stress harness | `StorageActivationCoordinator`, `DiskImageFaultTests`, `FormatMatrixScaleTests`, `StressHarness` | S1, V2, V3, F7 |
| Parser safety: MIME depth limit 20, disk-aware streaming ZIP reader | `MIMEParser`, `EmailBodyExtractor`, `ZIPArchiveReader` | P3 (prove with fuzzing) |
| Honest export helpers; RFC 4180 CSV | `PlatformExport`, `ExportOutcome`, `csvRow` (2026-10-09) | rule 5, every export |
| Workspace persistence (JSON) | `ReviewWorkspaceStore` (2026-10-09) | F4 moves it to SQLite |
| Spotlight indexing | `SpotlightIndexer` | Q1 |
| Privacy manifest; 10-language catalog + tests; press-every-button UI crawl | `PrivacyInfo.xcprivacy`, `Localizable.xcstrings`, `MailinClickThroughUITests` | V5, V8, rule 10 |
| On-device AI with grounding gate ("counts in code") | `AIGroundingGate`, `AIGroundedAnswer`, `FoundationModelEngine` | I1–I5 |

**Changes (new code, behind switches):** scope engine + resume (F1–F2), feature index columns (F6), legal state
in SQLite with dual-write (F4), fingerprint tree (F5), every L/A/I/Q/H tool's new engine, safe HTML renderer (S8),
SQLite hygiene (S9), snapshots / fullfsync / iOS lock safety / continued-processing (S1–S4), MetricKit + Safe Mode +
Health page (S5–S7), evidence exports (E1–E7), accessibility (X4), SDK 27 + Swift 6 (P1–P7).

**Stays exactly as is in 3.0 (switched off when its replacement is on):** the 2,000-email working-set host
and the 8 per-tool loaders, the in-process HTML importer, JSON/UserDefaults legal state, the in-memory analysis
loops, the current AI context building. Deleted only in a later release after a release with zero trips (§3-R).

## 3. Workstreams (the complete inventory)

### M — Engine switches and crash isolation (do before anything else changes behaviour)
| ID | Item | Done means | Status |
|---|---|---|---|
| M1 | **One capability per rebuilt engine/tool** (e.g. `v3ScopeEngine`, `v3FeatureIndex`, `v3LegalState`, `v3SafeHTML`, `v3EDiscovery`, `v3Bates`, … one per L/A/I/Q tool), raw values permanent, `maturity: .preview`, `requires` the foundations they use, `whenOff` = "the previous engine is used; nothing is lost"; grouped under "3.0 engines" in the matrix | matrix lists every engine; a test asserts each L/A/I/Q/S8 item has a switch and defaults off |  (11ecfe4) [~] |
| M2 | **Crash breadcrumbs → automatic switch-off ("trip")**: before a new engine runs a job or render, write a durable "running X" marker; clear it on finish. On launch, a marker left behind means the app stopped inside X → X is switched off, the old engine is used, a banner explains it and offers "Copy diagnostics" (S5). Tripped switches stay off until a new app version or the user re-enables them | kill-inside-engine test: next launch has X off, banner shown, old path works |  (11ecfe4) [~] |
| M3 | **Error fallback**: a new engine that *throws* (not crashes) falls back to the old path for that call, logs it, and says so in the receipt | fault-injection test per seam |  (11ecfe4) [~] |
| M4 | **Shadow comparison** (debug and TestFlight builds only): run old and new on the same scope (where the old one is capped, on a ≤ 2,000 subset) and record any difference in the result | report per tool before promotion | Implemented: `ShadowComparison.swift` — Debug and TestFlight/Xcode builds only (`AppTransaction` environment ≠ production); the newest ≤ 2,000 emails go to the 3.0 engine as `newestLimit` and to the previous engine as the same array; 5 read-only pairs (PII, NLP classification, indicators, keyword sweep, exact duplicates) with declared expected differences (indicator de-dup across batches; MIH duplicates); reports appended to `ShadowComparison.jsonl`; panel in Settings ▸ Modules. Tests in `V3CompatibilityTests` (run in the test pass). Pairs for tools with side effects (holds, tags, Bates) are covered by M6 flip-flop tests instead — [~] |
| M5 | **Promotion rule**: preview → stable (default on) only after golden + 100k + chaos tests pass, shadow comparison matches, and a TestFlight period with zero trips; recorded here with date. Demotion is automatic on a trip | promotion log in this file | — test-and-fix pass — [ ] |
| M6 | **Data compatibility** for rule 16: dual-write / read adapters for every moved piece of state, with a test that flips the switch back and forth and loses nothing | flip-flop test per moved state | Inventory: moved state = legal data (holds, seals, custodians, custody events → database, files kept) and Bates numbers (database + manager). Shared, not moved: tags (`email_user_tags`), review batches, predictive scores, privilege flags. Implemented (fd41796): per-manager `LegalStateMirror`; pending-write marker + launch-time recovery whatever the switch (union, never removes); `deactivate()` on switch-off; database hold check on delete only while the copy is live (`setEnforcesDatabaseLegalHolds`; `deleteReportingHeld` returns what it refused); re-sealed-while-off seals replace the database row; markers beside the legal files, not in app settings. Tests written: `V3CompatibilityTests` (legal flip-flop, crash recovery with engine off, re-seal, Bates flip-flop, privilege scan scope) — to run in the test pass — [~] |

### S — Safety and recovery (right after M)
| ID | Item | Done means | Status |
|---|---|---|---|
| S1 | **Snapshots**: `VACUUM INTO`/`sqlite3_backup` before every migration + rolling schedule; free-space check; one rolling copy; external location option; restore screen | corrupt-file test restores; migration leaves a snapshot |  (11ecfe4) external folder (Health ▸ Choose snapshot folder…, bookmark, falls back beside the store when detached); fixed: manual snapshots were pruned as rolling, a failed before-restore copy no longer lets the restore replace the database, a failed upgrade snapshot is shown on Health; tests `testSnapshots_*`, `testMigration_leavesASnapshotBeforeTheUpgrade` — [~] until the test pass |
| S2 | **`PRAGMA checkpoint_fullfsync = ON`** on macOS for every archive connection (keep WAL + NORMAL); measure import speed before/after | pragma read back in test; import timing recorded |  (11ecfe4) [~] |
| S3 | **iOS suspend/lock safety**: background-task assertions around writes; store + `-wal`/`-shm` + folder set to `completeUntilFirstUserAuthentication`; background work checks `isProtectedDataAvailable`; never repair in background | device test: lock + background during import → no kill (0xdead10cc), resumes |  (11ecfe4; see §8 #2 — the main store already had busy_timeout and file protection) [~] |
| S4 | **Long jobs on iPhone/iPad via `BGContinuedProcessingTask`** (starts from a tap, continues in background, system Live Activity shows progress, user can cancel; report progress or the system ends it) — used by the scope engine | whole-archive job survives backgrounding on iPad |  (11ecfe4) [~] |
| S5 | **MetricKit** crash/hang/disk-write diagnostics kept on device; Settings ▸ "Copy diagnostics"; symbolicate with archived dSYMs | forced test crash appears after relaunch |  (11ecfe4) [~] |
| S6 | **Safe Mode**: two launch crashes → read-only archive, no background jobs, "Restore snapshot / Rebuild search index / Copy diagnostics" (user-initiated, foreground only) | crash-loop test lands in Safe Mode |  (11ecfe4; see §8 #3 — Safe Mode stops background work and 3.0 engines; it does not make the archive read-only) [~] |
| S7 | **Archive Health page**: last integrity check, snapshot age, feature-index coverage, fingerprint status, free disk, recent diagnostics, "Run full check" | UI test |  (11ecfe4) [~] |
| S8 | **Safe HTML email rendering** (found 2026-10-10): `EmailHTMLView` uses the synchronous in-process `NSAttributedString` HTML importer, which Apple discourages, and whose default loader **fetches remote resources** — on iPhone/iPad (no network sandbox) opening an email can load tracking pixels (breaks offline-first; tells a phishing sender the evidence was opened) and can block the main thread (watchdog). Replace with out-of-process rendering (`loadFromHTML…` or a `WKWebView` with JavaScript off, CSP `default-src 'none'`, a block-all `WKContentRuleList`, only `cid:`/`data:` images); remote images never load; render off the main thread | test email with a remote pixel → zero network requests on iOS; 5 MB HTML email does not block the main thread |  (11ecfe4) [~] |
| S9 | **SQLite connection hygiene** (GRDB guidance): `busy_timeout` on every connection (none set today, several connections open), one writer per file, `BEGIN IMMEDIATE` writes, checkpoints only when idle | concurrency stress test: no SQLITE_BUSY |  (11ecfe4; see §8 #2 — the main store already had busy_timeout and file protection) [~] |

### F — Foundations
| ID | Item | Done means | Status |
|---|---|---|---|
| F1 | **Scope engine** `ScopeJob(scope) → step per batch → combine`: progress, Cancel, "X of Y", audit-after-success, receipt; adaptive batch size from `os_proc_available_memory`; generalise `ExportRunCenter` | cancel / partial-read / memory tests | [~] |
| F2 | **Resumable jobs**: checkpoint per batch (reuse import checkpoint store); resume after quit/crash/kill; receipt says "resumed" | kill-at-random-batch test resumes to the same result | [~] |
| F3 | **Streaming aggregates** (counters, histograms, top-K-with-total, distinct) | equal to in-memory results on fixtures | [~] |
| F4 | **Legal state into SQLite** (schema bump): holds, evidence seals, custodians (today JSON rewritten per insert), custody events (today UserDefaults), Legal Review + Journalist workspaces (today JSON); batch upserts; seals set once | 100k holds in one transaction in seconds; old files migrated, verified, kept read-only | [~] |
| F5 | **Fingerprint tree** (Merkle over per-email SHA-256, built at import, incremental) replacing the two seal systems as the verification path; old seals and signatures keep verifying | tamper test pinpoints the email; old bundles still verify | [~] |
| F6 | **Feature index** — extend `derived` (versioned, incremental, per email): PII flags, IOC rows, SPF/DKIM/DMARC, privilege flags, language, entities, MinHash bands, threat score, **EDRM Message Identification Hash (MIH)**, sentence embedding (Q2) | coverage shown on Health page; backfill resumable, low priority, pauses on battery/heat | [~] |
| F7 | **Test tiers**: synthetic 100k (every run), 1M (before release), 10M headers-only (store/index/paging); memory ceiling sized for the smallest supported iPhone; "result == SQL count" | harness runs per tool; `SCALE_RESULTS.md` table | Implemented: `maxmailinTests/V3ScaleTests.swift` — synthetic archive generated in batches with facts at fixed rates (answers are arithmetic), footprint sampled every 250 ms during each tool, ceiling 700 MB growth (smallest supported iPhone). Tiers via `MAILIN_SCALE_TIER`: 100k (default, every run), 1m (before release), 10m headers-only (store, counts, keyset paging), off. Prints `SCALE …` lines for SCALE_RESULTS.md. To run in the test pass (100k duration to be measured; if too slow for every run, the owner decides) — [~] |
| F8 | **Golden archive**: fixed corpus with expected answers for every tool (Swift Testing parameterized) | every tool has a golden test | Implemented: `maxmailinTests/V3GoldenTests.swift` — 40-email golden archive built from specs (answers known by construction: SSNs, IPs, URLs, a hash, keywords, privilege phrases, SPF/DKIM/DMARC, content duplicates, two senders over four months); Swift Testing parameterized over 11 checks (search, exclusions, PII, keywords, privilege, indicators, IT stats, duplicates, Bates, fingerprint tree, shadow comparison). To run in the test pass — [~] |
| F9 | **Audit lessons as build-failing lints**: `_ = PlatformFileSaver…`, `try?` on user-chosen writes, `DocumentRegistry.post/capture` before its save, `workingSet(query:cap:)`, `acc.count >= N { break }`, new `as!`/`try!`, "all" in UI text next to a bounded loop | lint test fails today, passes at the end | Implemented: `maxmailinTests/V3LintTests.swift` (fails the suite) + `Scripts/lint_v3.py` (same rules, CLI report, writes `Scripts/lint_v3_baseline.json`). 8 rules: discarded save outcome, `workingSet(…cap:)`, `count >= N { break }`, `as!`, `try!`, `try?` on a write to the user-chosen `url`, document captured before its save, "All…" next to `.prefix(N)`. New files: zero (3 private-file writes carry `lint:allow` with the reason). A build phase needs a pbxproj edit (not while Xcode is open) — the failing test gates every commit instead (rule 11). To run in the test pass — [~] |

### L — Legal / forensic actions (whole archive, no exceptions; built as F1 recipes with E1 receipts)
| ID | Tool ▸ button | Status |
|---|---|---|
| L1 | E-Discovery ▸ Run Search (SQL/FTS over scope) | [~] |
| L2 | E-Discovery ▸ Apply / Release Legal Hold (id query → F4 batch) | [~] |
| L3 | E-Discovery ▸ Verify & Seal Collection (F5) | [~] |
| L4 | E-Discovery ▸ Run NLP Analysis / Create Review Batches (F6 / all ids) | [~] |
| L5 | E-Discovery ▸ Load File / Production CSV / Privilege Log (streamed exporters with scope) | [~] |
| L6 | Bates ▸ Assign / Export Index (never renumber — rule 3) | [~] |
| L7 | Chain of Custody ▸ Verify / exports (F5, F4) | [~] |
| L8 | Custodians ▸ Place All on Hold / Assign to All Visible / Verify Seals / Report | [~] |
| L9 | Privilege scan (Forensic Review, Legal Review, list) → F6 flags | [~] |
| L10 | Automation Rules ▸ Run Rules Now (count first — rule 4) | [~] |
| L11 | Batch Operations ▸ Tag / Classify (store bulk by ids/scope) | [~] |
| L12 | Review Batches ▸ Create (all ids) | [~] |
| L13 | Investigation Report (scope or ids; F3 sections) | [~] |
| L14 | Legal Review workspace stats (F3) on F4 coding | [~] |
| L15 | PII Report (F6 flags; today `scanCap = 2_000`) | [~] |
| L16 | IOC Extractor (F6 rows) | [~] |
| L17 | Keyword Monitor (FTS whole archive) | [~] |
| L18 | Evidence Desks ▸ Seed (F3 top sources with totals) | [~] |
| L19 | Duplicates ▸ groups from SQL, paged (today 5,000 loader) | — the 3.0 path still found near-duplicates in a newest-5,000 window (rule 6); now runs the whole-archive near-duplicate engine and points to Near-Duplicates; lint ceiling lowered — [~] |
| — | GDPR data-subject report, Triage IOC blocklist, Redact & Export — already whole-archive (2026-10-09); keep, add to F7/F8 | [x] (uncommitted) |

### A — Analysis tools (become F6 queries)
| ID | Tool | Status |
|---|---|---|
| A1 | Smart Alerts, Anomaly Detection, Background Findings |  [~] |
| A2 | Predictive Coding (train on all labelled, score all; scores persist) |  [~] |
| A3 | Predictive Insights |  [~] |
| A4 | Near-Duplicates: MinHash + LSH bands in SQLite, verify with exact Jaccard, record thresholds/shingle settings in the receipt (defensible), group never delete |  [~] |
| A5 | Topic Clusters (incremental, or stated sample with whole-archive assignment) |  [~] |
| A6 | Thread Summarizer / Story (page all members — today 200; summarise in chunks within 4,096 tokens) |  [~] |
| A7 | Attachments grid / gallery (paged) |  [~] |
| A8 | Subjects list (SQL group-by) |  [~] |
| A9 | IT Admin (auth stats from F6; threat scores persisted) |  [~] |
| A10 | Personal Organizer, Smart Auto-Tagger (tags persisted per batch) |  [~] |
| A11 | General Analysis, Forensic Review, Journalist stats (F3) |  [~] |
| A12 | Communication Patterns ("recent 500" block) |  — streaming analysis was already whole-archive; its AI context (newest 500) moves to I4 — [~] |
| A13 | Full Analytics (`defaultNLPCap = 5000`) |  [~] |
| A14 | Archive Comparison (pass the scope, not a 2,000 array) |  — already compares the whole current archive (v2.1 #3); verify only — [~] |
| A15 | Knowledge / Relationship graphs, AI Visualization (build from all; show top-N with totals) |  — path search no longer stops after 500 nodes and reports "no path" for connected people (linear BFS; test `testKnowledgeGraph_findsAPathPastFiveHundredNodes`) — [~] |
| A16 | Plugin Manager: plugin API v2 takes a batch stream; plugins run isolated with timeouts so a plugin cannot crash the app |  [~] |
| A17 | **AI Digest** (added 2026-10-11 — the plan had missed it: it read the newest 1,000 of the scope and filtered to the period in memory, so long periods were understated and old archives empty): period as a query bound, every email streamed into running totals, lists "N of M", new contacts checked against the archive before the period, predictions from A3, AI narrates code-computed figures | `DigestEngine.swift` (switch `v3AnalysisQueries`, fallback to the previous digest); test `testDigest_wholePeriod_*` — [~] |

### I — AI (designed around the 4,096-token reading window)
| ID | Item | Status |
|---|---|---|
| I1 | **AI answers via FoundationModels `Tool`s** that call our queries (count, top-K, find, timeline) — the model decides which question to ask, our code counts; ≤ 3–5 tools per request, short descriptions (Apple guidance) | [~] |
| I2 | **Token budget**: measure with `tokenCount(for:)`/`contextSize`; handle `contextSizeExceeded` by condensing the transcript; long material map-reduced across sessions | [~] |
| I3 | **Retrieval for narrative answers** from the whole archive (FTS + Q1/Q2), answers state "based on N of M emails" | [~] |
| I4 | **"Enhance with AI" buttons** pick the most relevant emails by retrieval (today newest 500) and say how many | [~] |
| I5 | **Prompt versioning** per model version (Apple "Updating prompts for new model versions") + the existing typed-question checks re-run on each OS update | [~] |
| I6 | Optional **Private Cloud Compute** model for larger context — online feature, off by default, behind the cloud-AI consent toggle | — **not in 3.0 (owner, 2026-10-10)**: 3.0 is the Private edition — no network. Long inputs are handled on device (measured parts, `TokenBudget`, `ThreadStoryEngine`). For a future online edition: needs the `com.apple.developer.private-cloud-compute` entitlement — n/a |

### Q — Search and similarity
| ID | Item | Status |
|---|---|---|
| Q1 | **Core Spotlight custom index** (protection class set) + **`SpotlightSearchTool`** for natural-language search inside the AI layer — configured with a `focused` guide and compact format for the on-device model; its default PCC mode is online → off unless the toggle is on | [~] |
| Q2 | **Semantic search**: NaturalLanguage sentence embeddings stored in F6; vector search in SQLite (evaluate sqlite.org **vec1** ANN vs `sqlite-vec`, which is pre-1.0) — decision gate before adopting an extension | [~] |
| Q3 | **EDRM MIH** in load files and duplicate matching (cross-party, cross-matter dedup) | [~] |
| Q4 | Search operators: "has-not" label/tag, and negation for every filter (ePADD feature) | every filter negates (from, to, subject, domain, tag/label, source, type, evidence, filename, before, after, has:attachment, is:pinned); receipts state what was left out; tests `testExclusions_*` — [~] until the test pass |

### E — Evidence and defensibility
| ID | Item | Status |
|---|---|---|
| E1 | **Job receipts** record scope query, archive revision, counts and the **fingerprint of the exact email set**; "Re-run and prove" button |  [~] |
| E2 | **Long-term evidence records** in RFC 4998 style (hash tree + timestamps) exported with productions and case bundles |  [~] |
| E3 | **Time-stamping**: optional RFC 3161 token on fingerprint-tree heads (online toggle; token never part of the digest); offline alternative: print/email the tree root (linked time-stamping) | offline alternative done (archive root shown in Health and in every evidence record; linked time-stamping by printing/sending the root). **RFC 3161 not in 3.0 (owner, 2026-10-10)**: 3.0 Private makes no network calls; for a future online edition (TSA + online toggle) | [x] offline / n/a online |
| E4 | Collection receipts at import state custodian, source, tool, settings, hashes (EDRM processing guidance) |  — receipt fields written; show them in ImportReceiptView in the test pass — [~] |
| E5 | **Preservation export**: BagIt bag with PREMIS metadata (original, processed copy, sidecars) — the archival standard ePADD uses; opens the library/archives market |  [~] |
| E6 | **Redaction completeness**: redacted exports never carry the unredacted HTML part or attachments (ePADD lesson); test checks every part of a redacted export |  — already structural (RedactedEmail carries no HTML part or attachment bytes); test to write — [~] |
| E7 | **Collect-to-preserve** option: a matter can auto-hold and seal everything as it is imported (2026 e-discovery practice) |  [~] |

### H — Other hidden limits
| ID | Where | Status |
|---|---|---|
| H1 | Documents list / search (200) → paged | [~] |
| H2 | Workflow runs (200) → paged | [~] |
| H3 | Attachment text search (2,000) → paged | [~] |
| H4 | Search results (FTS 50 / ranked 100) → paged or "N of M" everywhere shown | [~] |
| H5 | Sender rollups (200) → paged | [~] |
| H6 | Tag vocabulary (2,000) → paged | [~] |
| H7 | IMAP fetch/search → chunked "All" option | — n/a in 3.0: screens kept dormant, no network (owner, 2026-10-10; finding #9) — n/a |
| H8 | Gmail / Outlook fetch (5,000 stepper) → paged "All" option | — n/a in 3.0: screens kept dormant, no network (owner, 2026-10-10; finding #9) — n/a |
| H9 | PST export splits below 50 GB; FAT32 targets split below 4 GB | [~] |

### X — Experience
| ID | Item | Status |
|---|---|---|
| X1 | **One tool, one host** (~70 entry points → ~35 tools) | — inventory and proposal in X1_TOOL_HOSTS.md; **owner decision** which entry points go (not reversible by a switch) — [~] |
| X2 | Confirmation-with-count component (rule 4) used by every whole-archive action | — `ScopeConfirmation` (ArchiveScope.swift) used by the whole-scope L actions — [~] |
| X3 | Release note + in-app note: "results now cover your whole archive" | — What's New 3.0 entries (preview wording; App Store text is the owner's) — [~] |
| X4 | **Accessibility to Apple's Nutrition Label standard**: VoiceOver, Voice Control, Larger Text, Sufficient Contrast, Dark Interface, Differentiate Without Color, Reduced Motion; automated accessibility audits in UI tests; declare the labels in App Store Connect | Implemented: 3.0 views swept (decorative icons hidden, progress bars labelled with "X of Y emails", Cancel names its job + Voice Control input labels, list rows read as one element, status = shape + text); no fixed sizes or animations in 3.0 views. `maxmailinUITests/AccessibilityAuditUITests.swift` runs `performAccessibilityAudit(for: .all)` on the main window and Settings ▸ Modules (owner present). Declaration evidence per feature in `ACCESSIBILITY_3_0.md` (V10 decides what to declare) — [~] |

### P — Platform future-proofing
| ID | Item | Status |
|---|---|---|
| P1 | Strict concurrency **complete**, then **Swift 6 language mode**, module by module (ArchiveCore first); consider default MainActor isolation for the app target; Thread Sanitizer run |  — measured 2026-10-10: ArchiveCore has ~50 strict-concurrency diagnostics (34 mutable statics, 8 sending, 2 deinit, 2 async conformance); fix in the test pass, then `swiftLanguageModes: [.v6]` [~] |
| P2 | **`SWIFT_STRICT_MEMORY_SAFETY`** for ArchiveCore parsers (28 unsafe-pointer sites today); move parser buffers to bounds-checked `Span` where possible |  — measured: 2,686 warnings package-wide, 2,147 are SQLite C calls in SQLiteEmailStore (expected unsafe API). Scope P2 to the parsers (~80 sites: ZIP 31, MIME 14, FileUtils 13, ExportFolderManifest 12, BodyExtractor 11, QP 9) with `unsafe`/Span, not a package-wide flag [~] |
| P3 | Parser hardening: property-based tests + coverage-guided fuzzing of every format parser (damaged/hostile files → named error, never a crash), including the known attack classes from recent CVEs: deeply nested multiparts and nested `message/rfc822` (depth limit 20 exists — prove it), unbounded per-part headers, huge address lists, decompression bombs (ZIP reader is disk-aware — prove it) | Property-based part implemented: `maxmailinTests/V3ParserFuzzTests.swift` — deterministic mutation fuzzing (SplitMix64, `MAILIN_FUZZ_SEED` / `MAILIN_FUZZ_ITERATIONS`) of every routed format (mbox, eml, emlx, msg, pst, nsf, zip, with signatures so noise passes the sniff) plus the MIME parser; CVE attack shapes (600-deep multiparts, 400-deep message/rfc822, header/line floods, broken base64/QP/encoded-words, boundary tricks, NUL bytes, bare CR, truncation); 20 s per-file deadline = hang. **Coverage-guided fuzzing (libFuzzer) not done**: needs a fuzzer runtime in the toolchain and a separate fuzz target — to be decided in the test pass — [~] |
| P4 | Replace 5 `as!` in `CaseBundleService.swift:360-364`; F9 lint stops new ones |  — done: 5 `as! T` replaced with conditional casts (behaviour unchanged) [~] |
| P5 | Yearly WWDC checklist: new SDK build, deprecations, prompt re-check (I5), Phase V re-run |  — WWDC_CHECKLIST.md written [~] |
| P6 | **SDK 27 readiness**: `@State` becomes a macro (views with custom `init`s — 96 here, 4 assign `State(...)` directly — can stop compiling; use Apple's documented fix, not reordering assignments) and result builders unify under `@ContentBuilder` (ambiguous overlay/background overloads); build against the new SDK and fix per Apple's reference |  — builds clean against macOS SDK 27.0; iOS SDK build to confirm in the test pass [~] |
| P7 | Export-compliance check: `ITSAppUsesNonExemptEncryption = NO` is right only while the app signs/hashes but does not encrypt data itself — re-verify whenever case bundles or exports change |  — verified: no code encrypts data (hash/sign only) → NO is correct; recheck kept in WWDC_CHECKLIST.md [~] |

### R — Remove the old path
| ID | Item | Status |
|---|---|---|
| R1 | **Not in 3.0.** Old engines stay behind their switches through 3.0. Delete `ArchiveWorkingSetView` / `workingSet(query:cap:)`, the 8 per-tool loaders and the in-process HTML importer only in a later release, after one full release with each replacement stable and zero trips | [ ] |
| R2 | F9 lints fail the build for **new** code (old files allow-listed until R1) | New files must be clean; old files (tree at 21679da) have per-rule ceilings that may only go down (32 sites in 24 files at baseline) — [~] |
| R3 | Update `SUPPORTED_FORMATS_AND_LIMITS.md`, `SIZE_LIMITS_DESIGN.md`, store copy, help: real limits only | — SUPPORTED_FORMATS_AND_LIMITS.md "Tool scope" section added; SIZE_LIMITS_DESIGN.md, help and store copy in the test pass — [~] |

### V — Verification before shipping
| ID | Item | Who | Status |
|---|---|---|---|
| V1 | Every tool on 100k and 1M: result == SQL count, memory flat, Cancel, resume; 10M store/paging; publish table | me | [ ] |
| V2 | 1 GB real-format fixtures (mbox, PST, EML folder, Maildir, Apple Mail, gzip, mixed) | me | [ ] |
| V3 | Chaos run: kill mid-job, disk full, drive unplugged, iPad locked → relaunch, resume, answers match golden set | me | [ ] |
| V4 | Full unit + package suites; Thread Sanitizer run | me | 2026-10-11 (54bf349): app unit suite 801 passed / 0 failed (13 opt-in scale/fixture tests skipped, 9 StoreKit tests not run — need the StoreKit config); ArchiveCore 59 / 0 failed, and 0 ThreadSanitizer reports. Still open: Thread Sanitizer on the app target (scheme diagnostic), StoreKit suite — [~] |
| V5 | Mac UI suites + press-every-button crawl (needs the owner present to approve automation) | owner + me | [ ] |
| V6 | iPad simulator + real-device lock/suspend checks | me + owner | [ ] |
| V7 | Release build: verify-no-network, idle CPU, launch/resume time with a 1M archive **without the debugger** (watchdog) | me | [ ] |
| V8 | Localization complete; build 603+; TestFlight; App Store | owner | [ ] |
| V9 | Release build on a real iPhone/iPad: opening HTML mail, AI, search, exports make **zero network requests** unless an online toggle is on | me + owner | [ ] |
| V10 | Accessibility audit pass (X4) and App Store Accessibility Nutrition Labels filled in | me + owner | [ ] |

## 4. Order of work (gates between steps)

0. [ ] Commit the 2026-10-09 button-audit fixes (suite green today).
0.5 **Switches first:** M1 (matrix entries) → M2 (trip) → M3 (fallback) → M6 (data compatibility pattern).  *Gate: kill-inside-engine test green — from here on, a crash in new code cannot take the app down twice.*
1. **Safety:** S1 → S2 → S9 → S3 → S8 → S5 → S6.  *Gate: snapshot restore test green; zero-network HTML test green.*
2. **Engine:** F1 + F2 + S4 → F3.  *Gate: kill-and-resume test green.*
3. **Storage:** F4 (needs S1) → F5.  *Gate: migration verified one-for-one on real old files; old bundles verify.*
4. **Index & tests:** F6 → F7 → F8 → F9 (report-only).  *Gate: golden answers recorded.*
5. **Legal:** L1–L19 with E1 receipts, X2 confirmations.  *Gate: golden + 100k green for every L row.*
6. **Analysis & AI & search:** A1–A16, I1–I5, Q1–Q3, H1–H9.
7. **Experience & cleanup:** X1, X4, S7, E2–E7, Q4, R1–R3 (F9 → fail build).
8. **Platform:** P1–P4, P6, P7 run alongside steps 2–7, module by module; P1 may slip to 3.0.1 if risky (warnings mode).
9. **Promotion & verification:** M4 shadow reports → M5 promote engines one by one → V1–V10, then ship with promoted engines on and every old engine one switch away.

## 5. Risks and safeguards

| Risk | Safeguard |
|---|---|
| Migration loses holds/seals/coding | rules 1–2; one-for-one verify; fallback to old files with a warning |
| Old evidence stops verifying after F5 | tree is additive; old seals/signatures verified by tests on current-build bundles |
| Whole-archive actions surprise users (hold 100k, rules touch everything) | rule 4 confirmation with count |
| Bates renumbering | rule 3 + test |
| First-launch backfill (CPU, battery, heat, +10–30% DB size) | low priority, pauses on battery/heat, resumable, progress on Health page; tools show coverage meanwhile |
| Snapshots fill the disk | one rolling copy, free-space check, skip with warning, external option |
| Numbers change vs. before; rewrite computes wrong | golden archive (F8); release note (X3) |
| `checkpoint_fullfsync` slows writes | measure (S2); checkpoint-only setting |
| Swift 6 adds runtime isolation crashes | module by module, TSan, real devices; may slip to 3.0.1 |
| Self-repair causes damage | repairs only user-initiated, foreground, after a snapshot |
| Big-bang release | commit + TestFlight per step; any step shippable |
| New engine crashes in the field | M2 trips it off on next launch; old engine takes over; diagnostics captured (S5) |
| Two engines diverge on shared data | rule 16 + M6 flip-flop tests |
| More code to maintain during 3.0 | accepted (owner, 2026-10-10); old code frozen except bug fixes; removed in a later release (R1) |
| `v3-architecture` drifts from `main` | note merge cost; owner decides per release |
| Can't test power cut / yanked drive / UI tests alone | owner sessions planned in V5/V6 |
| Third-party SQLite extensions (vec) are pre-1.0 | decision gate in Q2; prefer sqlite.org's own or a small in-house scan |

## 6. How an agent works on this plan (every session)

1. Read `CLAUDE.md`, then this file §0–§2 and §4. Find the first unchecked item in §4 order.
2. Re-verify the item against the code (line numbers move). If the plan is wrong, fix the plan first and say so.
3. Implement to its "done means", following §1. Add the test that fails without the change.
4. Build with zero new warnings; run the suite; translate new strings.
5. Tick the item here (`[x]` + short commit hash + date), commit, and report what was done and verified,
   what was not, and the next item.
6. Never skip a gate. Never start a later step while an earlier gate is red.

## 7. Sources (checked 2026-10-10)

Apple documentation (Xcode documentation search): BackgroundTasks — `BGContinuedProcessingTask`,
"Performing long-running tasks on iOS and iPadOS"; FoundationModels — "Managing the context window"
(4,096 tokens), `contextSize`, `Tool`, "Updating prompts for new model versions"; Core Spotlight —
`SpotlightSearchTool`, "Making your indexed content available to Foundation Models"; NaturalLanguage —
`NLEmbedding` sentence embeddings; Xcode build settings — Strict Concurrency, Strict Memory Safety; Swift — `Span`.

Web: [SQLite limits](https://www.sqlite.org/limits.html) ·
[How to corrupt an SQLite database](https://www.sqlite.org/howtocorrupt.html) ·
[macOS fsync / F_FULLFSYNC report](https://github.com/pingdotgg/t3code/issues/13544) ·
[sqlite.org vec1](https://sqlite.org/vec1) · [sqlite-vec overview](https://ai-tldr.dev/learn/embeddings-vector-databases/vector-database-guides/sqlite-vec-explained/) ·
[TN2434 memory footprint](https://developer.apple.com/library/archive/technotes/tn2434/_index.html) ·
[QA1592 launch watchdog](https://developer.apple.com/library/archive/qa/qa1592/_index.html) ·
[File protection & SQLite on lock](https://github.com/wjdavis5/lunarlog/pull/953) ·
[GRDB 0xdead10cc](https://github.com/groue/GRDB.swift/issues/302) ·
[MetricKit crash reporting](https://www.chimehq.com/blog/metrickit-crash-reporting-part-2) ·
[WWDC24 Migrate to Swift 6](https://developer.apple.com/videos/play/wwdc2024/10169/) ·
[EDRM Message Identification Hash](https://edrm.net/2023/02/introducing-the-edrm-e-mail-duplicate-identification-specification-and-message-identification-hash-mih/) ·
[EDRM processing guidelines](https://edrm.net/wp-content/uploads/2022/01/Final-1-23-22-EDRM-Guidelines-for-E-Discovery-Processing-Draft-for-Public-Comment-12_01_2021.pdf) ·
[Local RFC 3161 TSA design (offline evidence)](https://stella-ops.org/docs/architecture/decisions/adr-036-local-rfc3161-timestamp-authority/index.html) ·
[Linked time-stamping](https://en.wikipedia.org/wiki/Linked_timestamping) ·
[Near-duplicate detection with MinHash/LSH](https://yorko.github.io/2023/practical-near-dup-detection/) ·
[swift-property-based](https://github.com/x-sheep/swift-property-based) ·
[PropertyTestingKit fuzzer](https://forums.swift.org/t/introducing-propertytestingkit-a-swift-testing-friendly-coverage-guided-fuzzer/86705)

Added 2026-10-10 (second sweep): [ePADD](https://github.com/ePADD/epadd) and [ePADD releases](https://github.com/ePADD/epadd/releases) ·
[libratom](https://github.com/libratom/libratom) · [email-processing-resources](https://github.com/libratom/email-processing-resources) ·
[GRDB concurrency guide](https://www.mintlify.com/groue/GRDB.swift/advanced/concurrency) ·
[GRDB checkpoint caveat](https://github.com/groue/GRDB.swift/issues/793) ·
[Nested message/rfc822 recursion DoS](https://github.com/GOVCERT-LU/eml_parser/security/advisories/GHSA-g47v-rwmh-r9f8) ·
[Outlook nested S/MIME recursion crash](https://michaelbommarito.com/blog/outlook-smime-pkcs7-recursion-dos/) ·
[Multipart unbounded headers DoS](https://github.com/rack/rack/security/advisories/GHSA-wpv5-97wm-hp9c) ·
[CSS in email privacy/security](https://roots.ec/blog/spy-sheets/) ·
[Safe HTML email rendering design](https://github.com/joeblau/mail/issues/16) ·
[WKWebView content blocking pre-warm](https://github.com/henrikogaard/brev/pull/98) ·
[Privacy manifest requirements](https://vburojevic.dev/blog/ios-privacy-manifest-requirements/) ·
[EDRM best practices 2026](https://www.cloudficient.com/blog/ediscovery-best-practices-2026) ·
Apple docs: `NSAttributedString` persistence note (synchronous HTML import discouraged; use out-of-process
`loadFromHTML`), `webResourceLoadDelegate` (default loads subsidiary resources), Accessibility Nutrition Labels,
"Performing accessibility testing for your app", SwiftUI SDK 27 notes (`@State` macro, `@ContentBuilder`).

Background audits: `BUTTON_AUDIT_3_0.md` (1,083 buttons, 2026-10-09).

## 7b. Clause-by-clause gaps (audit 2026-10-10) — implement before the test pass

Every `[~]` row was checked against its own wording. A row is not done until every clause below is.

| Row | Missing clause | Status |
|---|---|---|
| F1 | adaptive batch size from `os_proc_available_memory`; generalise `ExportRunCenter` | [x] code cdf4795 |
| F4 | Legal Review + Journalist workspaces into SQLite | [x] code 2f8a230 |
| F5 | fingerprint tree as THE verification path (Verify buttons); old seals keep verifying | [x] code 2853911 |
| F6 | named entities in the feature index (`entity_rows`, `entityTop`, extractor v2). **Plan corrected:** the sentence embedding is NOT duplicated into `features` — it lives in the existing on-device semantic index (`SemanticIndex.swift`, `embeddings.db`, its own resumable job), which Q2's fusion reads; the `features.embedding` column stays NULL | [x] code |
| M2 | tripped switches come back with a new app version (unless the user switched them off) | [x] code 18304e7 |
| M3 | a fallback is stated in the job receipt — and every 3.0 seam really falls back (withFallback had no callers; 9 silent catches fixed) | [x] code 18304e7 |
| S6 | Safe Mode makes the archive read-only (plan) + help text says exactly what it does (#3) | [x] code 75dd04d |
| E2 | evidence record included in productions and case bundles | [x] code cafd4bb |
| E4 | collection fields shown in ImportReceiptView | [x] code e50b4d1 |
| E6 | test that checks every part of a redacted export | [x] test e50b4d1 |
| A12/I4 | Communication Patterns AI context by retrieval, stating how many — and a user's scope is never swapped for an archive sample (finding #19) | [x] code ddd095a |
| Q2 | written decision gate: vec1 vs sqlite-vec (before any extension) — SEMANTIC_SEARCH_DECISION.md | [x] 16b3df0 |
| P1 | ArchiveCore strict-concurrency diagnostics fixed; Swift 6 mode — 24 diagnostics fixed (locked settings, main-actor sinks for the import engines' callbacks, deinit handle, Sendable progress), ArchiveCore in Swift 6 language mode, app + package tests zero warnings. Next modules (app target, test targets) and the Thread Sanitizer run are in the test pass (V4) | [x] code (this commit) |
| P2 | parser unsafe sites marked / moved to Span — ZIP/gzip reader: sinks moved to `Data`, zlib `compression_stream` code marked with a SAFETY note; MIME, body extractor, quoted-printable, mbox filter/parser/record builder, EMLX, FileUtils, ExportFolderManifest: every raw-buffer read marked `unsafe` (137 sites) with SAFETY notes. Under `-strict-memory-safety` these files report 0 (SQLite/FTS C calls stay out of scope by design). `Span` not used: needs OS 26, the package supports macOS 14 / iOS 17 | [x] code (this commit) |
| P3 | coverage-guided fuzzing (libFuzzer) — or the toolchain limit stated. **Toolchain limit confirmed:** Apple's Xcode toolchain rejects `-sanitize=fuzzer` on macOS; Linux is out (Apple frameworks). Harness implemented and type-checked: `Fuzz/` package (MIME parser + every routed format via the parser factory, ASan on), `Scripts/fuzz.sh` (seed corpus from the demo mailbox, 30 min, findings saved for regression tests). **Running it needs the swift.org macOS toolchain — owner decision (a download)** | [x] harness / owner: toolchain |
| P6 | iOS SDK 27 build confirmed — it was BROKEN (S8 used the AppKit-only `.timeout` option); fixed with an own 10 s deadline; 8 Swift-6 warnings in new code fixed; iOS and macOS build with zero warnings | [x] (this commit) |
| R3 | SIZE_LIMITS_DESIGN.md, help, store copy | [x] 16b3df0 |
| X1 | owner decision on which entry points go | owner |
| §8 #1, #5, #6, #7 | old-path bug fixes | [x] code 18304e7, be0829d |

## 8. Findings during the implementation pass (fix in the test-and-fix pass)

| # | Where | Finding | Status |
|---|---|---|---|
| 1 | `ForensicManager.exportPrivilegeLog` (old path) | `String(format: "%-12s …", swiftString)` — `%s` reads a C pointer from a Swift `String`: garbage columns or a crash. The 3.0 path pads in Swift. Fix the old path the same way (one-line change, behaviour-preserving). | [ ] |
| 2 | Plan text S3/S9 | The main store already set `busy_timeout=5000` and background-readable file protection before 3.0; S3/S9 wording "none set today" is wrong. | [ ] |
| 3 | Safe Mode wording | Safe Mode = no background work + no 3.0 engines; it does not make the archive read-only. Make help text say exactly that. | [ ] |
| 4 | `BatesNumberingManager.assignNumbers` (old path) | Replaced every existing assignment with a fresh sequence over the loaded emails — broke rule 3 (never renumber). **Owner, 2026-10-10: follow rule 3.** Fixed: numbered emails keep their numbers, unnumbered ones continue after the highest used, in date order; the preview, the status line ("Assigned N new …", was the running total) and the accessibility hint say what the run does. Defaults store injectable for tests. Test `testOldBatesPath_neverRenumbersExistingAssignments`. | [x] |
| 5 | `BatchOperationsView.performRemoveTag` / `performClearClassification` (old path) | Both call `onTagApplied("")`, which clears ALL tags on the emails — "Remove Tag X" removes every tag. 3.0 path removes only the chosen tag. Fix the old path to call `removeTag(tag, from:)`. | [ ] |
| 6 | `FoundationModelEngine.synthesizeThread` (old path) | Puts ~500 characters per message into ONE prompt; a long thread (≈ 25k tokens for 200 messages) exceeds the 4,096-token window and the caller's `try?` swallows the error — Thread Story silently shows nothing. 3.0 (`ThreadStoryEngine`) reads long threads in measured parts. Old path: at least surface the error. | [ ] |
| 7 | `PluginManager.runPluginSandboxed` (old path) | The 30 s timeout never ends the run: when the sleep task finishes first it returns `nil`, the loop `continue`s and waits for the plugin anyway. Findings are also cut at 100 silently. 3.0 (`PluginRunnerV2`) races each call against a deadline that is honoured and reports "N of M batches timed out". | [ ] |
| 8 | `SearchEmailsTool` / `GetThreadInfoTool` (AI assistant tools) | Hydrated FTS hits from `EmailStore` (the v1 SwiftData store) — on an archive held in SQLite (every 2.x/3.0 archive) the assistant's search tool found ids but returned "No emails found". **Fixed in place (bug fix, 2026-10-10)**: hydrate via `ArchiveDataService.fullEmails(ids:)`, the active-store router. Test: `testAISearchToolRetrievesBoundedEvidenceViaFTS` on a disposable SQLite archive (39d3973). | [x] |
| 9 | `IMAPConfigView`, `CloudConnectView` (Gmail / Outlook) | Not reachable: nothing presents these views (`IMAPClient`, `GmailConnector`, `OutlookConnector` are only used by them). Consistent with offline-first 3.0 Private, so H7/H8 have no effect in 3.0. **Owner, 2026-10-10: keep dormant in 3.0** (not reachable, no network — 3.0 Private). If exposed in a future online edition, the "All" option must fetch in chunks (IMAP `FETCH` ranges; Gmail/Graph page tokens) and import per chunk. | [x] decided |
| 10 | `SQLiteEmailStore.delete` / `fingerprintRefreshBuckets` (3.0, F5) | Found by test: deleting an email removed its leaf but kept its month's stored root, so the archive root still vouched for the deleted email. **Fixed**: the month root is dropped in the same transaction (and for orphan leaves on refresh). Test `testFingerprintVerify_pinpointsTheChangedEmail`. | [x] |
| 11 | `ArchiveQueryCompiler.compile` (3.0, Q4) | A negated operator with no exclusion form (`-source:x`, `NOT before:…`) fell through to the INCLUDE parser — it kept exactly what was asked to be left out. **Fixed**: kept as literal text. Sender/subject exclusions made NULL-safe. Test `testExclusions_unsupportedNegationIsNeverAnInclude`. | [x] |
| 12 | `ScopeJob.run` (3.0, F2) | The checkpoint was written with the new counts before the resume cursor moved; a stop between the two writes re-ran the batch on resume (double count, wrong receipt fingerprint). **Fixed**: one write per batch after the cursor moves. Jobs, crash breadcrumbs and checkpoints now read a task-local `ScopeJobEnvironment`, so tests run on a disposable archive. Test `testScopeJob_resumesAfterInterruption_eachEmailOnce_sameFingerprint`. | [x] |
| 13 | `BatesEngine.assign` (3.0, L6) | One assignment wrote two audit entries (engine + `merge`); the CSV index sorted numbers as text (`…1000000` before `…999999` once past the padding). **Fixed**: `merge(log: false)` from the engine, numeric sort; numbering core split out (`BatesEngine.number`) and tested against the database. Test `testBates_numbersOldestFirst_andNeverRenumberWhenMailArrives`. | [x] |
| 14 | `PreservationExporter.verify` (3.0, E5) | Only re-hashed files the manifest lists: a file added under `data/` still "verified", and Payload-Oxum was never checked — not RFC 8493 validation. **Fixed**: completeness (every payload file listed) and Payload-Oxum checked. Test `testPreservationBag_validates_andDetectsAddedOrChangedFiles`. | [x] |
| 15 | 3.0 engines' audit entries | Engines wrote straight to `ForensicManager.shared`, so a test (forensic mode is a UserDefaults flag) could append to the owner's real audit chain. **Fixed**: `ScopeJobEnvironment.logAction` — the real chain in the app, the bound environment's own log in tests. The evidence record writer is split from the save panel (`EvidenceRecordExporter.write`) and every proof is checked by folding to the archive root. | [x] |
| 16 | `LegalStateMirror` / `EDiscoveryEngine.applyHold` (3.0, F4) — rule 16 | (a) a database-only hold job that stopped part-way left holds the files never got; the next activation (files = truth) would then DELETE them from the database, and with the engine off the old screens never saw them. (b) With the engine off, a hold released through the old path stayed in the database and `delete` silently skipped that email. (c) Off → on never re-verified (`active` stayed true). (d) A seal re-made while off failed verification forever. **Fixed** in M6 (fd41796). Tests in `V3CompatibilityTests`. | [~] |
| 17 | `PrivilegeScanEngine.scan` (3.0, L) | Replaced the whole privilege-flag dictionary with the scanned scope's results: a scan of one sender (or a cancelled scan) erased every flag elsewhere. **Fixed** (fd41796): only scanned emails change; the count reported is the scope's. Test `testPrivilegeScan_keepsFlagsOutsideTheScope`. | [~] |
| 18 | Old-file lint sites to review (F9 baseline) | Possible rule-5 defects: `ChainOfCustodyManager` shares a bag with `_ = PlatformExport.share(...)` (outcome discarded); `documentBeforeSave` in `BatesNumberingManager`, `CustodianPanelView`, `EDiscoveryWorkflowView` ×2 (may be unrelated buttons — check); `try?` writes to a user-chosen url in `AIMetrics`, `AIProvenance`, `PIIReportView`; `try!` in `AIAssistantView`, `AIGroundingGate` ×2. Review each in the test pass; a fixed site lowers the ceiling. | [ ] |

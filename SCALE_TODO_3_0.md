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
| M1 | **One capability per rebuilt engine/tool** (e.g. `v3ScopeEngine`, `v3FeatureIndex`, `v3LegalState`, `v3SafeHTML`, `v3EDiscovery`, `v3Bates`, … one per L/A/I/Q tool), raw values permanent, `maturity: .preview`, `requires` the foundations they use, `whenOff` = "the previous engine is used; nothing is lost"; grouped under "3.0 engines" in the matrix | matrix lists every engine; a test asserts each L/A/I/Q/S8 item has a switch and defaults off | [ ] |
| M2 | **Crash breadcrumbs → automatic switch-off ("trip")**: before a new engine runs a job or render, write a durable "running X" marker; clear it on finish. On launch, a marker left behind means the app stopped inside X → X is switched off, the old engine is used, a banner explains it and offers "Copy diagnostics" (S5). Tripped switches stay off until a new app version or the user re-enables them | kill-inside-engine test: next launch has X off, banner shown, old path works | [ ] |
| M3 | **Error fallback**: a new engine that *throws* (not crashes) falls back to the old path for that call, logs it, and says so in the receipt | fault-injection test per seam | [ ] |
| M4 | **Shadow comparison** (debug and TestFlight builds only): run old and new on the same scope (where the old one is capped, on a ≤ 2,000 subset) and record any difference in the result | report per tool before promotion | [ ] |
| M5 | **Promotion rule**: preview → stable (default on) only after golden + 100k + chaos tests pass, shadow comparison matches, and a TestFlight period with zero trips; recorded here with date. Demotion is automatic on a trip | promotion log in this file | [ ] |
| M6 | **Data compatibility** for rule 16: dual-write / read adapters for every moved piece of state, with a test that flips the switch back and forth and loses nothing | flip-flop test per moved state | [ ] |

### S — Safety and recovery (right after M)
| ID | Item | Done means | Status |
|---|---|---|---|
| S1 | **Snapshots**: `VACUUM INTO`/`sqlite3_backup` before every migration + rolling schedule; free-space check; one rolling copy; external location option; restore screen | corrupt-file test restores; migration leaves a snapshot | [ ] |
| S2 | **`PRAGMA checkpoint_fullfsync = ON`** on macOS for every archive connection (keep WAL + NORMAL); measure import speed before/after | pragma read back in test; import timing recorded | [ ] |
| S3 | **iOS suspend/lock safety**: background-task assertions around writes; store + `-wal`/`-shm` + folder set to `completeUntilFirstUserAuthentication`; background work checks `isProtectedDataAvailable`; never repair in background | device test: lock + background during import → no kill (0xdead10cc), resumes | [ ] |
| S4 | **Long jobs on iPhone/iPad via `BGContinuedProcessingTask`** (starts from a tap, continues in background, system Live Activity shows progress, user can cancel; report progress or the system ends it) — used by the scope engine | whole-archive job survives backgrounding on iPad | [ ] |
| S5 | **MetricKit** crash/hang/disk-write diagnostics kept on device; Settings ▸ "Copy diagnostics"; symbolicate with archived dSYMs | forced test crash appears after relaunch | [ ] |
| S6 | **Safe Mode**: two launch crashes → read-only archive, no background jobs, "Restore snapshot / Rebuild search index / Copy diagnostics" (user-initiated, foreground only) | crash-loop test lands in Safe Mode | [ ] |
| S7 | **Archive Health page**: last integrity check, snapshot age, feature-index coverage, fingerprint status, free disk, recent diagnostics, "Run full check" | UI test | [ ] |
| S8 | **Safe HTML email rendering** (found 2026-10-10): `EmailHTMLView` uses the synchronous in-process `NSAttributedString` HTML importer, which Apple discourages, and whose default loader **fetches remote resources** — on iPhone/iPad (no network sandbox) opening an email can load tracking pixels (breaks offline-first; tells a phishing sender the evidence was opened) and can block the main thread (watchdog). Replace with out-of-process rendering (`loadFromHTML…` or a `WKWebView` with JavaScript off, CSP `default-src 'none'`, a block-all `WKContentRuleList`, only `cid:`/`data:` images); remote images never load; render off the main thread | test email with a remote pixel → zero network requests on iOS; 5 MB HTML email does not block the main thread | [ ] |
| S9 | **SQLite connection hygiene** (GRDB guidance): `busy_timeout` on every connection (none set today, several connections open), one writer per file, `BEGIN IMMEDIATE` writes, checkpoints only when idle | concurrency stress test: no SQLITE_BUSY | [ ] |

### F — Foundations
| ID | Item | Done means | Status |
|---|---|---|---|
| F1 | **Scope engine** `ScopeJob(scope) → step per batch → combine`: progress, Cancel, "X of Y", audit-after-success, receipt; adaptive batch size from `os_proc_available_memory`; generalise `ExportRunCenter` | cancel / partial-read / memory tests | [~] |
| F2 | **Resumable jobs**: checkpoint per batch (reuse import checkpoint store); resume after quit/crash/kill; receipt says "resumed" | kill-at-random-batch test resumes to the same result | [~] |
| F3 | **Streaming aggregates** (counters, histograms, top-K-with-total, distinct) | equal to in-memory results on fixtures | [~] |
| F4 | **Legal state into SQLite** (schema bump): holds, evidence seals, custodians (today JSON rewritten per insert), custody events (today UserDefaults), Legal Review + Journalist workspaces (today JSON); batch upserts; seals set once | 100k holds in one transaction in seconds; old files migrated, verified, kept read-only | [~] |
| F5 | **Fingerprint tree** (Merkle over per-email SHA-256, built at import, incremental) replacing the two seal systems as the verification path; old seals and signatures keep verifying | tamper test pinpoints the email; old bundles still verify | [~] |
| F6 | **Feature index** — extend `derived` (versioned, incremental, per email): PII flags, IOC rows, SPF/DKIM/DMARC, privilege flags, language, entities, MinHash bands, threat score, **EDRM Message Identification Hash (MIH)**, sentence embedding (Q2) | coverage shown on Health page; backfill resumable, low priority, pauses on battery/heat | [~] |
| F7 | **Test tiers**: synthetic 100k (every run), 1M (before release), 10M headers-only (store/index/paging); memory ceiling sized for the smallest supported iPhone; "result == SQL count" | harness runs per tool; `SCALE_RESULTS.md` table | [ ] |
| F8 | **Golden archive**: fixed corpus with expected answers for every tool (Swift Testing parameterized) | every tool has a golden test | [ ] |
| F9 | **Audit lessons as build-failing lints**: `_ = PlatformFileSaver…`, `try?` on user-chosen writes, `DocumentRegistry.post/capture` before its save, `workingSet(query:cap:)`, `acc.count >= N { break }`, new `as!`/`try!`, "all" in UI text next to a bounded loop | lint test fails today, passes at the end | [ ] |

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
| L19 | Duplicates ▸ groups from SQL, paged (today 5,000 loader) | [~] |
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
| A15 | Knowledge / Relationship graphs, AI Visualization (build from all; show top-N with totals) |  [~] |
| A16 | Plugin Manager: plugin API v2 takes a batch stream; plugins run isolated with timeouts so a plugin cannot crash the app |  [~] |

### I — AI (designed around the 4,096-token reading window)
| ID | Item | Status |
|---|---|---|
| I1 | **AI answers via FoundationModels `Tool`s** that call our queries (count, top-K, find, timeline) — the model decides which question to ask, our code counts; ≤ 3–5 tools per request, short descriptions (Apple guidance) | [~] |
| I2 | **Token budget**: measure with `tokenCount(for:)`/`contextSize`; handle `contextSizeExceeded` by condensing the transcript; long material map-reduced across sessions | [~] |
| I3 | **Retrieval for narrative answers** from the whole archive (FTS + Q1/Q2), answers state "based on N of M emails" | [~] |
| I4 | **"Enhance with AI" buttons** pick the most relevant emails by retrieval (today newest 500) and say how many | [~] |
| I5 | **Prompt versioning** per model version (Apple "Updating prompts for new model versions") + the existing typed-question checks re-run on each OS update | [~] |
| I6 | Optional **Private Cloud Compute** model for larger context — online feature, off by default, behind the cloud-AI consent toggle | — **owner-bound**: needs the `com.apple.developer.private-cloud-compute` entitlement provisioned by Apple, and it is an online feature (owner decision for 3.0 Private) — [ ] |

### Q — Search and similarity
| ID | Item | Status |
|---|---|---|
| Q1 | **Core Spotlight custom index** (protection class set) + **`SpotlightSearchTool`** for natural-language search inside the AI layer — configured with a `focused` guide and compact format for the on-device model; its default PCC mode is online → off unless the toggle is on | [~] |
| Q2 | **Semantic search**: NaturalLanguage sentence embeddings stored in F6; vector search in SQLite (evaluate sqlite.org **vec1** ANN vs `sqlite-vec`, which is pre-1.0) — decision gate before adopting an extension | [~] |
| Q3 | **EDRM MIH** in load files and duplicate matching (cross-party, cross-matter dedup) | [~] |
| Q4 | Search operators: "has-not" label/tag, and negation for every filter (ePADD feature) | [~] |

### E — Evidence and defensibility
| ID | Item | Status |
|---|---|---|
| E1 | **Job receipts** record scope query, archive revision, counts and the **fingerprint of the exact email set**; "Re-run and prove" button | [ ] |
| E2 | **Long-term evidence records** in RFC 4998 style (hash tree + timestamps) exported with productions and case bundles | [ ] |
| E3 | **Time-stamping**: optional RFC 3161 token on fingerprint-tree heads (online toggle; token never part of the digest); offline alternative: print/email the tree root (linked time-stamping) | [ ] |
| E4 | Collection receipts at import state custodian, source, tool, settings, hashes (EDRM processing guidance) | [ ] |
| E5 | **Preservation export**: BagIt bag with PREMIS metadata (original, processed copy, sidecars) — the archival standard ePADD uses; opens the library/archives market | [ ] |
| E6 | **Redaction completeness**: redacted exports never carry the unredacted HTML part or attachments (ePADD lesson); test checks every part of a redacted export | [ ] |
| E7 | **Collect-to-preserve** option: a matter can auto-hold and seal everything as it is imported (2026 e-discovery practice) | [ ] |

### H — Other hidden limits
| ID | Where | Status |
|---|---|---|
| H1 | Documents list / search (200) → paged | [ ] |
| H2 | Workflow runs (200) → paged | [ ] |
| H3 | Attachment text search (2,000) → paged | [ ] |
| H4 | Search results (FTS 50 / ranked 100) → paged or "N of M" everywhere shown | [ ] |
| H5 | Sender rollups (200) → paged | [ ] |
| H6 | Tag vocabulary (2,000) → paged | [ ] |
| H7 | IMAP fetch/search → chunked "All" option | [ ] |
| H8 | Gmail / Outlook fetch (5,000 stepper) → paged "All" option | [ ] |
| H9 | PST export splits below 50 GB; FAT32 targets split below 4 GB | [ ] |

### X — Experience
| ID | Item | Status |
|---|---|---|
| X1 | **One tool, one host** (~70 entry points → ~35 tools) | [ ] |
| X2 | Confirmation-with-count component (rule 4) used by every whole-archive action | [ ] |
| X3 | Release note + in-app note: "results now cover your whole archive" | [ ] |
| X4 | **Accessibility to Apple's Nutrition Label standard**: VoiceOver, Voice Control, Larger Text, Sufficient Contrast, Dark Interface, Differentiate Without Color, Reduced Motion; automated accessibility audits in UI tests; declare the labels in App Store Connect | [ ] |

### P — Platform future-proofing
| ID | Item | Status |
|---|---|---|
| P1 | Strict concurrency **complete**, then **Swift 6 language mode**, module by module (ArchiveCore first); consider default MainActor isolation for the app target; Thread Sanitizer run | [ ] |
| P2 | **`SWIFT_STRICT_MEMORY_SAFETY`** for ArchiveCore parsers (28 unsafe-pointer sites today); move parser buffers to bounds-checked `Span` where possible | [ ] |
| P3 | Parser hardening: property-based tests + coverage-guided fuzzing of every format parser (damaged/hostile files → named error, never a crash), including the known attack classes from recent CVEs: deeply nested multiparts and nested `message/rfc822` (depth limit 20 exists — prove it), unbounded per-part headers, huge address lists, decompression bombs (ZIP reader is disk-aware — prove it) | [ ] |
| P4 | Replace 5 `as!` in `CaseBundleService.swift:360-364`; F9 lint stops new ones | [ ] |
| P5 | Yearly WWDC checklist: new SDK build, deprecations, prompt re-check (I5), Phase V re-run | [ ] |
| P6 | **SDK 27 readiness**: `@State` becomes a macro (views with custom `init`s — 96 here, 4 assign `State(...)` directly — can stop compiling; use Apple's documented fix, not reordering assignments) and result builders unify under `@ContentBuilder` (ambiguous overlay/background overloads); build against the new SDK and fix per Apple's reference | [ ] |
| P7 | Export-compliance check: `ITSAppUsesNonExemptEncryption = NO` is right only while the app signs/hashes but does not encrypt data itself — re-verify whenever case bundles or exports change | [ ] |

### R — Remove the old path
| ID | Item | Status |
|---|---|---|
| R1 | **Not in 3.0.** Old engines stay behind their switches through 3.0. Delete `ArchiveWorkingSetView` / `workingSet(query:cap:)`, the 8 per-tool loaders and the in-process HTML importer only in a later release, after one full release with each replacement stable and zero trips | [ ] |
| R2 | F9 lints fail the build for **new** code (old files allow-listed until R1) | [ ] |
| R3 | Update `SUPPORTED_FORMATS_AND_LIMITS.md`, `SIZE_LIMITS_DESIGN.md`, store copy, help: real limits only | [ ] |

### V — Verification before shipping
| ID | Item | Who | Status |
|---|---|---|---|
| V1 | Every tool on 100k and 1M: result == SQL count, memory flat, Cancel, resume; 10M store/paging; publish table | me | [ ] |
| V2 | 1 GB real-format fixtures (mbox, PST, EML folder, Maildir, Apple Mail, gzip, mixed) | me | [ ] |
| V3 | Chaos run: kill mid-job, disk full, drive unplugged, iPad locked → relaunch, resume, answers match golden set | me | [ ] |
| V4 | Full unit + package suites; Thread Sanitizer run | me | [ ] |
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

## 8. Findings during the implementation pass (fix in the test-and-fix pass)

| # | Where | Finding | Status |
|---|---|---|---|
| 1 | `ForensicManager.exportPrivilegeLog` (old path) | `String(format: "%-12s …", swiftString)` — `%s` reads a C pointer from a Swift `String`: garbage columns or a crash. The 3.0 path pads in Swift. Fix the old path the same way (one-line change, behaviour-preserving). | [ ] |
| 2 | Plan text S3/S9 | The main store already set `busy_timeout=5000` and background-readable file protection before 3.0; S3/S9 wording "none set today" is wrong. | [ ] |
| 3 | Safe Mode wording | Safe Mode = no background work + no 3.0 engines; it does not make the archive read-only. Make help text say exactly that. | [ ] |
| 4 | `BatesNumberingManager.assignNumbers` (old path) | Replaces every existing assignment with a fresh sequence over the loaded emails — breaks rule 3 (never renumber). The 3.0 engine skips numbered emails. Decide: guard the old path the same way (owner call — it changes old behaviour). Assignments also live in UserDefaults (whole dictionary rewritten); 3.0 keeps them in the database. | [ ] |
| 5 | `BatchOperationsView.performRemoveTag` / `performClearClassification` (old path) | Both call `onTagApplied("")`, which clears ALL tags on the emails — "Remove Tag X" removes every tag. 3.0 path removes only the chosen tag. Fix the old path to call `removeTag(tag, from:)`. | [ ] |
| 6 | `FoundationModelEngine.synthesizeThread` (old path) | Puts ~500 characters per message into ONE prompt; a long thread (≈ 25k tokens for 200 messages) exceeds the 4,096-token window and the caller's `try?` swallows the error — Thread Story silently shows nothing. 3.0 (`ThreadStoryEngine`) reads long threads in measured parts. Old path: at least surface the error. | [ ] |
| 7 | `PluginManager.runPluginSandboxed` (old path) | The 30 s timeout never ends the run: when the sleep task finishes first it returns `nil`, the loop `continue`s and waits for the plugin anyway. Findings are also cut at 100 silently. 3.0 (`PluginRunnerV2`) races each call against a deadline that is honoured and reports "N of M batches timed out". | [ ] |
| 8 | `SearchEmailsTool` / `GetThreadInfoTool` (AI assistant tools) | Hydrated FTS hits from `EmailStore` (the v1 SwiftData store) — on an archive held in SQLite (every 2.x/3.0 archive) the assistant's search tool found ids but returned "No emails found". **Fixed in place (bug fix, 2026-10-10)**: hydrate via `ArchiveDataService.fullEmails(ids:)`, the active-store router. Needs a test. | [~] |

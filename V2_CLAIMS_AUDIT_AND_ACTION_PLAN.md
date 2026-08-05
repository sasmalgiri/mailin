# mailin v2 — Claims-Coverage Audit & Action Plan

**Target:** `maxmailin` target (product `com.ecosanskriti.mailin`, source dir `maxmailin/`) — the code slated to ship as **mailin 2.0**.
**Audited tree:** branch `main`, working tree (no uncommitted changes to the audited files).
**Date:** 2026-08-04.
**Author:** engineering audit (static call-graph analysis + deep code read; no code modified).

---

## 0. How to read this document

- **Authoritative claim source:** the public **landing page** `docs/index.html` (deployed to the GitHub Pages site) — this is what customers see for v2. Secondary published claim sources: `README.md`, `AppStoreMetadata.txt`, `RELEASE_NOTES_v2.md`.
- **Status legend:**
  - 🟢 **GREEN** — implemented, wired to the real user path, matches the claim.
  - 🟡 **AMBER** — implemented but partial, fragile, or the wording overstates it.
  - 🔴 **RED** — the claim is false as it would ship: the feature is missing, broken, or built-but-not-connected to the path users actually run.
- **Method & limits:** findings are from *static* analysis of the checked-out source — which function calls which (the "call graph"), plus reading the implementations. This is **conclusive** for two things: (a) a concrete Swift type with **zero references** anywhere cannot execute (no reflection/string instantiation exists to wire it), and (b) tracing which engine a screen actually calls. It would only be wrong if the missing wiring lives on **another branch** not merged here, or is simply **not-yet-done** work intended before ship. Line numbers marked *(deep-read)* were found by the deep code-read pass; the headline blockers were personally re-verified and are marked *(verified)*.

> **State mismatch to resolve first:** the landing page already says **"mailin 2.0 is here · Now live on the App Store."** If v2 has **not** actually shipped, that copy is live-but-false today and should be corrected regardless of everything below.

---

## 1. Executive summary

mailin v2 is a genuinely substantial product. **Roughly two-thirds of the advertised surface is real and correctly wired** — the entire on-device AI/NLP stack, localization, privacy/no-network posture, import streaming, keyset pagination, export (EML/JSON/CSV/PDF/Bates/signed), and the forensic audit-log/chain-of-custody machinery all check out.

However, a small cluster of **high-profile, prominently-advertised claims are not true as the code would ship today.** They are not random bugs — they share **one systemic root cause: the v2 "foundation rewrite" built new subsystems but never finished wiring the app's UI/feature layers to them.** The rewrite is ~70% integrated; the missing 30% is exactly the last-mile connection work, and it lands squarely on the flagship claims:

| Blocker | Landing-page claim it breaks |
|---|---|
| **Search doesn't use the FTS5 engine** | "a real search engine… instant results across your whole archive," BM25 + boolean + regex + NEAR/n |
| **v1→v2 migration is broken** | "existing users get a free in-place upgrade," "exact same on-device location as v1" |
| **SPF/DKIM/DMARC are not verified** | "Verify email authentication headers" |

Two more published claims (on `README`/App Store, **not** on the landing page) are also false and should be fixed or removed before they migrate onto the site: **AES-256 encrypted storage** and **biometric lock** are both fully-written but **dead code** (zero references), and **iCloud sync** is compiled out of the shipping build.

The good news: the hard engineering for most blockers is **already done** — FTS5, the SwiftData store, EncryptedStorage, and BiometricLock all exist and are well-built. The fix is largely connection, plus honest relabeling of the few genuinely-hard items (real DKIM crypto, a loadable PST writer).

---

## 2. Root-cause analysis (why the claims are blocked)

### ① PRIMARY — the foundation rewrite was never fully wired to the app (`~70% integrated`)
The landing page states it plainly: *"a foundation rewrite… rebuilds the storage, ingest, and search layers underneath… under the same UI."* That is precisely the failure mode. The new foundation exists; the UI/feature layers were **not re-pointed to it**. The pattern repeats across every primary blocker:

| Built (the new foundation) | But the app still… | Result |
|---|---|---|
| `FTSSearchIndex` (year-sharded FTS5 + bm25) | searches the old in-RAM `EmailSearchIndex` / linear scan | **R2** |
| `EmailStore` (SwiftData) + `MigrationService` | v1 persisted JSON+LZFSE; migration reads the wrong path | **R1** |
| `EncryptedStorageManager` (AES-GCM-256) | is never referenced — store writes plaintext | **R3** |
| `BiometricLockManager` (LocalAuthentication) | is never referenced — nothing gates the app | **R4** |
| `PSTStreamingParser` (graceful >2 GB path) | `ParserFactory` routes straight to the in-memory `PSTParser` | >2 GB PST regression |

Fix this one pattern (wire UI → new foundation) and R1–R4 largely close.

### ② SECONDARY — forensic auth was scoped as "display," marketed as "Verify"
No cryptographic/DNS verification layer was ever built. `parseAuthenticationResults` regex-reads the `Authentication-Results` header a relay may have added. The landing-page word **"Verify"** (and the App Store "S/MIME signature verification") therefore overstate what runs — and for a *forensic* product, a false "verified" is the highest-liability item. (**R6**)

### ③ SECONDARY — container writers implement the skeleton, not the spec
`PSTWriter`/`MSGWriter` build headers and happy-path structures but omit the tables real readers require (allocation maps, B-tree interior nodes, MAPI property-stream compliance). PST/MSG *writing* is genuinely weeks of work. (**R5**) *(Note: PST/MSG export is on README/App Store but **not** on the landing page — the page only claims EML/JSON/CSV/PDF/Bates/Concordance export.)*

### ④ SECONDARY — marketing/code drift
Copy written aspirationally or against an earlier design, never reconciled with the final binary: "no migration needed" (R1), iCloud sync that's compiled out (R7), "Now live on the App Store" while pre-release, and pricing that differs between the landing page and App Store metadata.

---

## 3. Landing-page claims matrix (the authoritative v2 claims)

### 3.1 "New in Version 2.0" band

| Claim (landing page) | Status | Evidence | Root cause if not GREEN |
|---|---|---|---|
| Streaming ingest — "drop a 200 GB Takeout… peak memory stays flat" | 🟡 AMBER | `MBOXParser.parseStreamingCallback` real drain-in-batches *(deep-read)* | True for **mbox/eml**; the non-streaming `MBOXParser.parse` (`FileUtils.readTextFile` → whole file into a `String`) and `NSFParser.parseByScan` (whole mmap → `String`) have **no size ceiling** → OOM on non-mbox large inputs. |
| Resumable from any crash — per-file SHA-256 + per-batch checkpoints | 🟡 AMBER | `ImportCheckpointStore`, `BulkImportCoordinator` checkpoints *(deep-read)* | Resume works, but store-vs-FTS commit is not atomic (crash between the two → unsearchable rows / duplicate FTS rows), and resume skips by positional batch index rather than a content anchor. |
| **Year-sharded FTS5 with bm25** | 🔴 **RED** | `FTSSearchIndex` is real and indexed, but its `search()` has **exactly two callers** — `SwiftDataDiagnosticsView.swift:249` and `MaxmailinSelfTest.swift:146`, both diagnostics *(verified)*. The search UI never calls it. | **The advertised engine is not the engine that runs.** See R2 below. |
| Keyset pagination — "jump to email #1,000,000… responds in a heartbeat" | 🟢 GREEN | `EmailStore.pageKeyset(beforeDate:beforeID:)`, adopted by `PaginatedEmailViewModel` *(deep-read)* | — |
| Larger PST/NSF — mmap, PST/OST ≤50 GB, NSF ≤64 GB | 🟡 AMBER | `PSTParser`/`NSFParser` use `.mappedIfSafe` with 50/64 GB caps *(deep-read)* | Import works; **>50 GB PST throws** (the graceful `PSTStreamingParser` is never wired in), and `NSFParser` falls back to a whole-file `String` scan that defeats the mmap benefit. Also a **live crash**: `NSFParser.swift:368` slices `Data` and then subscripts `[0]` on the slice → index-out-of-bounds on ordinary Notes bodies *(verified)*. |
| Same privacy posture — no telemetry/analytics/3rd-party SDKs | 🟢 GREEN | Only outbound calls are in `CloudAIProvider.swift`, entirely under `#if !OFFLINE_MODE` → excluded from the Release binary; no analytics SDKs anywhere *(verified)* | — |
| **"exact same on-device location as v1… free in-place upgrade"** | 🔴 **RED** | v1 has **no `EmailStore`**; it persisted JSON+LZFSE at `mailin/saved_emails.json(.lz)` (`EmailPersistence.swift:15-21`). v2 uses a new SwiftData store. `MigrationService.legacyArchiveURL()` reads `com.ecosanskriti.mailin/email_archive.json` (`:152`) — **wrong dir, wrong filename, can't decompress LZFSE** — then marks itself complete on "not found" (`:82`) *(verified)*. | See R1 below — **silent total data loss** on upgrade. |

### 3.2 "Still offline / No network" band — 🟢 GREEN (all verified)
"No network — can't connect to the internet," "zero data collection," "100% on-device," "App Sandbox," "zero third-party SDKs," "verify with Little Snitch": the shipped Release config compiles with `OFFLINE_MODE`, contains no `URLSession` symbols, and is signed with entitlements that grant **no** `network.client`/`.server`. IAP Free-500 gate enforced (`ParsedEmailListViewModel.swift:731`). App Sandbox + hardened runtime on. *(verified)*
- 🟡 Minor: stale `NSLocalNetworkUsageDescription` in `info.plist` describing IMAP — remove it (App-Review flag; contradicts "cannot connect").

### 3.3 "Two AI engines, both on-device" band — 🟢 GREEN
Apple Intelligence (Foundation Models, `@available(macOS 26)`-gated) + Apple NaturalLanguage; graceful fallback chain; **AIProvenance tags every output** (`FoundationModelEngine.swift:1435` records; `AIAssistantView.swift:912` observes) *(verified)*. Cloud AI is off-by-default and compiled out of the offline build.

### 3.4 "Search like an analyst" band — 🔴 **RED (flagship blocker)**
Landing page: *"a full-text index… with the query power you'd expect from a real search engine — instant results across your whole archive,"* "BM25 relevance ranking," "Boolean (AND, OR, NOT) + regex," "Proximity search (NEAR/n)."

| Sub-claim | Reality |
|---|---|
| "real search engine, instant across whole archive" | Live search calls the **in-RAM** `EmailSearchIndex` (`ParsedEmailListViewModel.swift:635-652`) or a **linear** `allEmails.filter { …localizedCaseInsensitiveContains }` (`:679`). Not sub-second at millions; requires the whole corpus resident in RAM *(verified)*. |
| BM25 | Two implementations exist; the **live** one is a hand-rolled BM25 in `EmailSearchIndex`, not FTS5's `bm25()`. Technically "BM25," but not the FTS5 engine implied. |
| Boolean / regex / NEAR | Faked in Swift over the in-RAM index (`booleanSearch`/`regexSearch`/`proximitySearch`). Regex is an O(N) scan truncated to the first 100 KB/email. Even the FTS5 path can't do these: `escapeForFTS` wraps the whole query in double-quotes (`FTSSearchIndex.swift:395`), turning operators into literal text *(verified)*. |

### 3.5 Feature cards — mostly 🟢 with two exceptions

| Card | Status | Note |
|---|---|---|
| AI Assistant, Analytics Dashboard, Smart Auto-Tagger, Anomaly Detection + IOC, Daily AI Digest, Persona Profiles | 🟢 GREEN | On-device, real *(deep-read)* |
| Flexible Export — EML/JSON/CSV/PDF/Bates-PDF/Concordance/bulk-attach/signed | 🟡 AMBER | EML/JSON/CSV/PDF/Bates/vCard/Ed25519-signing all real *(deep-read)*. Concordance `.dat` correct but **no `.opt`/`.lfp`** image cross-reference files. (Landing page does **not** claim PST/MSG export — good.) |
| Offline Mode — tamper-evident, hash verification, audit logging | 🟢 GREEN | HMAC-SHA256 chained log real *(deep-read)*. Caveat: HMAC key co-located with log → tamper-**evident**, not tamper-**proof**; don't overstate. |
| **SPF / DKIM / DMARC — "Verify email authentication headers"** | 🔴 **RED** | `EmailNLPEngine.swift:673-709` regex-reads `Authentication-Results`; **no crypto, no DNS**. A forged header reports "verified." See R6. ("Inspect… headers" in the IT-Admin persona card is fine; the word **"Verify"** is the problem.) |

### 3.6 Pricing — 🟡 AMBER (drift, not a code defect)
Free-500 gate and tier enforcement are real (`StoreManager`, StoreKit 2, verified). But landing-page prices (Personal yearly **$44.99** / lifetime **$99.99**; Pro lifetime **$249.99**) differ from `AppStoreMetadata.txt` ($29.99 / $49.99 / $149.99). Reconcile the numbers across surfaces.

---

## 4. The blockers, in detail

### R1 — In-place upgrade / migration → **silent total data loss** (ship-blocker, data-loss)
- **Claim:** "existing users get a free in-place upgrade," "exact same on-device location as v1."
- **Reality:** v1 stored emails as JSON+LZFSE (`EmailPersistence`, dir `mailin/`, file `saved_emails.json(.lz)`). v2 introduces a **new** SwiftData `EmailStore`. `MigrationService` reads a **different** path (`com.ecosanskriti.mailin/email_archive.json`), cannot decompress LZFSE, and on "not found" sets `status = .completed` + a permanent flag so it **never retries** (`MigrationService.swift:82-83, 152`).
- **Effect:** every upgrading v1 user opens v2 to an **empty app**; their archive is orphaned on disk.
- **Root cause:** Pattern ①. No `VersionedSchema`/`SchemaMigrationPlan` either, so a future v2.1 schema change will throw `containerUnavailable` on launch and brick the app.

### R2 — Search doesn't use the advertised FTS5 engine (ship-blocker, flagship claim)
- **Claim:** §3.4 above.
- **Reality:** FTS5 is indexed on import but queried only by diagnostics. Live search uses the in-RAM engine / linear scan; operators are faked in Swift; `escapeForFTS` neuters FTS5 operators even on the unused path.
- **Root cause:** Pattern ①.

### R6 — SPF/DKIM/DMARC "verify" is header-trust (high forensic liability)
- **Claim:** "Verify email authentication headers"; App Store adds "S/MIME signature verification."
- **Reality:** No SPF eval, no DKIM canonicalization/RSA-verify, no DMARC alignment, no DNS. Reads the `Authentication-Results` string (`EmailNLPEngine.swift:673-709`). S/MIME uses real `CMSDecoder` but **ignores the cert-trust result** and mishandles detached signatures → both false-valid and false-invalid conclusions (`SMIMEHandler.swift`, deep-read).
- **Root cause:** Pattern ②. A blanket legal disclaimer does not cure a specific, affirmative "verified."

### Secondary published claims (README / App Store — NOT on the landing page yet)
- **R3 — AES-256 encrypted storage:** `EncryptedStorageManager` (real AES-GCM-256) has **0 references** outside its own file *(verified)*; primary store is plaintext (`EmailStore.swift:114-117`). **False as claimed.**
- **R4 — Biometric lock:** `BiometricLockManager`/`View` fully built, **0 references** outside its own file *(verified)*. Nothing gates the app. **False as claimed.**
- **R7 — iCloud sync:** entire `iCloudSyncManager` is `#if !OFFLINE_MODE` → **compiled out** of the shipping build; and it only ever synced metadata, never emails (`EmailStore.swift:64` `cloudKitDatabase: .none`).
- **R5 — PST/MSG export:** `PSTWriter` produces a **non-loadable** PST (NBT/BBT capped at 15/20 nodes, no allocation maps — `PSTWriter.swift:376-426`, deep-read). `MSGWriter` assembles a CFBF container but is MAPI-noncompliant/unverified in Outlook.

---

## 5. Robustness findings (from the crash/concurrency/parser/storage audits)

These threaten the "resumable / never OOM / robust handling of malformed email" promises even where the feature exists.

- 🔴 **Crash:** `NSFParser.swift:368` slice index-out-of-bounds — reproduces the v1 crash-dump signature (`EXC_BREAKPOINT`); fires on ordinary Lotus Notes bodies *(verified)*.
- 🔴 **Crash:** `MSGParser` integer overflows (`compressedSize + 4` UInt32 at `:153`; `Int(UInt64)` at `:494`); `OLE2Reader.collectTree` unbounded sibling recursion → stack overflow on hostile `.msg` *(deep-read)*.
- 🔴 **OOM / main-thread:** ZIP extract runs on `@MainActor`, loads the whole zip into RAM twice, and only extracts `mbox/eml` (not the other advertised formats) — `ContentViewModel.swift:143` *(deep-read)*.
- 🟠 **Integrity:** no per-row FTS delete and no store-driven FTS rebuild → deletions/redactions leave searchable ghost rows; store↔FTS can drift; ENOSPC during a large import isn't handled; `try?` swallows the dedup fetch *(deep-read)*.
- 🟠 **Forensic silent drops:** several parsers skip unparseable messages/attachments with **no surfaced count** — unacceptable for a forensic tool *(deep-read)*.
- 🟡 **Concurrency:** memory-pressure eviction runs `queue.sync` on the main thread; `KnowledgeGraph` `@unchecked Sendable` is unsound; import task not cancelled on view disappear *(deep-read)*.

---

## 6. Action plan

Each item lists a **route** — **Fix** (build the missing wiring/logic) or **Relabel** (trim copy to match reality) — plus effort (S/M/L), the files involved, and an acceptance criterion. Three overall **postures**:

- **Posture A — Fix-to-claim everywhere:** build real DKIM/DMARC crypto, a loadable PST writer, etc. Most ambitious; weeks.
- **Posture B — Relabel-to-code everywhere:** ship fast with honest, trimmed copy; days.
- **Posture C — Hybrid (recommended):** Fix the already-built-but-unwired items (cheap, high-value) and Relabel the genuinely-hard ones. Closes the honesty gap in days, keeps the strongest features.

### Phase 0 — Ship-blockers (must precede any v2 release)

| # | Item | Route | Effort | Files | Acceptance |
|---|---|---|---|---|---|
| 0.1 | **Migration data loss (R1)** | Fix | M | `MigrationService.swift`, reuse `EmailPersistence.load()` | Fresh v1 install with real `saved_emails.json.lz` → after v2 launch, all emails present in `EmailStore`; migration is idempotent and retries on failure (no false "complete"). Integration test with a real v1 fixture. |
| 0.2 | **SwiftData schema versioning** | Fix | S–M | `EmailStore.swift`, new `SchemaV1`/`SchemaMigrationPlan` | App launches cleanly against a store written by the previous schema; `containerUnavailable` has a user-visible recovery, not a silent throw. |
| 0.3 | **"Now live on the App Store" copy vs reality** | Relabel | S | `docs/index.html` | Page state matches actual release state. |

### Phase 1 — Flagship claim: Search (R2)

| # | Item | Route | Effort | Files | Acceptance |
|---|---|---|---|---|---|
| 1.1 | Route the search UI through `FTSSearchIndex` | Fix | M | `ParsedEmailListViewModel.swift`, `FTSSearchIndex.swift` | Search bar issues FTS5 `MATCH` queries; results identical set to current behavior on a fixture archive; sub-second on a ≥1M-message corpus. |
| 1.2 | Translate Boolean/regex/NEAR to FTS5 syntax; stop quoting the whole query | Fix | M | `FTSSearchIndex.swift` (`escapeForFTS`, query builder) | `a AND b`, `a OR b`, `NOT c`, `budget NEAR/5 deadline` produce correct FTS5 queries; regex documented as a post-filter over FTS candidates (or relabeled). |
| 1.3 | Per-row FTS delete + store-driven streaming rebuild/repair | Fix | M | `FTSSearchIndex.swift`, `EmailStore.swift` | Deleting/redacting an email removes it from search; a "rebuild index" action reconstructs FTS from the store by streaming pages. |
| 1.4 | If 1.1–1.2 slip: relabel search copy | Relabel | S | `docs/index.html` | Copy matches the in-RAM engine's real capability and scale. |

### Phase 2 — Crash & OOM hardening (protects "resumable / never OOM / robust")

| # | Item | Route | Effort | Files | Acceptance |
|---|---|---|---|---|---|
| 2.1 | NSF slice crash | Fix | S | `NSFParser.swift:368` (wrap slice in `Data(...)`) | Importing a real `.nsf` with rich-text bodies doesn't crash. |
| 2.2 | MSG overflows + OLE2 recursion | Fix | S | `MSGParser.swift:153,494`, `OLE2Reader.collectTree` | Fuzzed/hostile `.msg` fixtures import without trap/stack-overflow. |
| 2.3 | Move ZIP extract off main thread; stream it; extract all supported formats | Fix | M | `ContentViewModel.swift:143` | Multi-GB zip doesn't beachball/OOM; a zip of `.pst/.msg/.emlx` extracts. |
| 2.4 | Size ceilings on the MBOX `String` path + NSF scan fallback | Fix | S–M | `MBOXParser`/`FileUtils`, `NSFParser.parseByScan` | Oversized non-mbox inputs fail with a clean error, not OOM. |
| 2.5 | Surface a per-import RecoveryReport (imported/skipped/damaged) | Fix | M | all parsers, import UI | Every skipped message/attachment is counted and shown — no silent forensic drops. |

### Phase 3 — Forensic honesty (R6) & integrity

| # | Item | Route | Effort | Files | Acceptance |
|---|---|---|---|---|---|
| 3.1 | Relabel SPF/DKIM/DMARC now | Relabel | S | `docs/index.html`, in-app UI/CSV/report strings | Everywhere reads "shows authentication results **as reported by the receiving server**," never "verified." |
| 3.2 | (Posture A/C-later) Real DKIM/DMARC/SPF verification | Fix | L | new crypto/DNS module | DKIM signature cryptographically verified against DNS `p=`; DMARC alignment computed; forged headers fail. |
| 3.3 | S/MIME trust-chain + detached-content correctness | Fix | M | `SMIMEHandler.swift` | Untrusted chain → not "Valid"; genuine detached signatures verify. |
| 3.4 | ENOSPC handling; stop `try?`-swallowing dedup fetch; atomic store↔FTS or reconcile | Fix | M | `EmailStore.swift`, `BulkImportCoordinator.swift` | Disk-full yields a resumable state; no duplicate inserts on transient fetch error. |

### Phase 4 — Secondary published claims (README/App Store)

| # | Item | Route | Effort | Files | Acceptance |
|---|---|---|---|---|---|
| 4.1 | **AES-256 storage (R3)** | Fix **or** Relabel | S (relabel) / M (fix) | wire `EncryptedStorageManager` into `EmailStore` external blobs, **or** remove the claim | Either the store is actually encrypted, or the claim is gone. |
| 4.2 | **Biometric lock (R4)** | Fix **or** Relabel | S (fix — it's built!) / S (relabel) | wire `BiometricLockManager` into app launch/scene-phase, **or** remove the claim | Either Face ID/Touch ID gates access, or the claim is gone. |
| 4.3 | **iCloud sync (R7)** | Relabel/remove | S | `docs`, README, App Store | Claim removed or explicitly scoped ("settings metadata, cloud build only"). |
| 4.4 | **PST/MSG export (R5)** | Relabel (recommended) | S | README, App Store | Export claim lists only working formats (EML/MSG-caveat/PDF/…); or invest L to build a loadable PST writer. |
| 4.5 | Concordance `.opt`/`.lfp`; Bates cross-batch monotonicity; stale `NSLocalNetworkUsageDescription`; pricing drift | Fix/Relabel | S each | as noted | Each closed or copy-corrected. |

### Recommended sequence (Posture C)
**Phase 0 → Phase 1 → Phase 2 → Phase 3.1 (+3.4) → Phase 4 relabels → (later) Phase 3.2/3.3 & any Fix-to-claim upgrades.**
Everything is fixture-driven: add malformed/edge/large sample files and unit tests per phase, and build after each.

---

## 7. Appendix — key evidence index

| Finding | Evidence (file:line) | Confidence |
|---|---|---|
| FTS5 search unused by UI | callers only at `SwiftDataDiagnosticsView.swift:249`, `MaxmailinSelfTest.swift:146` | verified |
| Live search path | `ParsedEmailListViewModel.swift:635-652, 679` | verified |
| FTS operators neutered | `FTSSearchIndex.swift:393-396` (`escapeForFTS`) | verified |
| Migration wrong path | `MigrationService.swift:82-83, 152` vs `EmailPersistence.swift:15-21` | verified |
| v1 has no `EmailStore` | `EmailStore.swift` present only in `maxmailin/` | verified |
| AES manager dead | `EncryptedStorageManager` — 0 external refs | verified |
| Biometric manager dead | `BiometricLock*` — 0 external refs | verified |
| No network entitlement / OFFLINE_MODE | `maxmailin.xcodeproj/project.pbxproj` target Release `SWIFT_ACTIVE_COMPILATION_CONDITIONS = OFFLINE_MODE`; `mailin/mailin.entitlements` (no network keys) | verified |
| AIProvenance wired | `FoundationModelEngine.swift:1435`, `AIAssistantView.swift:912` | verified |
| NSF crash | `NSFParser.swift:368` (+ `:427`) | verified |
| SPF/DKIM/DMARC header-trust | `EmailNLPEngine.swift:673-709` | deep-read |
| PST writer non-loadable | `PSTWriter.swift:376-426, 322-332` | deep-read |
| MSG overflows / OLE2 recursion | `MSGParser.swift:153, 494`; `OLE2Reader.collectTree` | deep-read |
| ZIP on main thread | `ContentViewModel.swift:143` | deep-read |

### Verification commands (reproducible)
```
# FTS5 search callers (should be diagnostics only)
grep -rn "FTSSearchIndex.shared.search" maxmailin/
# Dead managers (0 lines outside their own file = unreachable)
grep -rl "EncryptedStorageManager" maxmailin/ | grep -v EncryptedStorageManager.swift
grep -rl "BiometricLock" maxmailin/ | grep -v BiometricLockManager.swift
# v1 vs v2 store paths
grep -n "saved_emails\|\.lz" maxmailin/EmailPersistence.swift
grep -n "email_archive\|completionKey\|\.completed" maxmailin/MigrationService.swift
```

*End of report.*

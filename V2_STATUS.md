# mailin v2 — Status: Goal · Implemented · Remaining

**Target:** `maxmailin` (ships as `com.ecosanskriti.mailin`, "mailin 2.0")
**Branch:** `v2-honesty-pass` (11 commits) · **PR #3** open → `main` (mergeable, not merged)
**Ship state:** **NOT shipped. Merge ≠ release** — 2 non-code gates open (§4)
**Tests:** 6 executed, green (R1/R2 red-then-green)
**Source of truth for claims:** `docs/index.html` (the deployed landing page)

Legend: ✅ verified by executed test · 🔨 build-verified (compiles/integrated, not fixture-tested) · 🟡 partial/relabeled · ⏸️ deferred (explicit plan call) · 🧑‍⚖️ owner decision (not code)

---

## 1. The goal (what the landing page promises for v2)

**"mailin 2.0 — a foundation rewrite, now shipping, under the same UI."** Rebuild storage/ingest/search so archives that were never realistic on v1 work, while keeping every v1 feature, strictly on-device.

Landing-page headline claims:
- **Streaming ingest** — drop a 200 GB archive, peak memory stays flat
- **Resumable from any crash** — per-file SHA-256 + per-batch checkpoints
- **Year-sharded FTS5 search** — bm25, "a real search engine, instant across your whole archive," Boolean/regex/proximity
- **Keyset pagination** — jump to email #1,000,000 instantly
- **Larger PST/NSF** — mmap; PST/OST ≤50 GB, NSF ≤64 GB
- **In-place upgrade** — existing v1 users keep their data
- **Strictly offline** — no IMAP/SMTP/network in the shipped binary; on-device AI only
- **Formats:** MBOX, EML, EMLX, MSG, PST, OST, NSF, ZIP
- **Forensic/legal:** tamper-evident audit log, chain-of-custody, Bates, SPF/DKIM/DMARC, S/MIME, redaction, signed exports
- **Export:** EML/JSON/CSV/PDF/Bates-PDF/Concordance, Ed25519-signed

The v2 gap this branch fixes: the audit found several of these were **built but not wired**, **false**, or **overstated**. This branch reconciles code ↔ claims.

---

## 2. Implemented (this branch)

### ✅ Verified by executed tests (`maxmailinTests/V2VerificationTests.swift`)
| Item | What | Test |
|---|---|---|
| **R1 in-place upgrade** | migration reads the REAL v1 store, non-destructive, dedup-aware count gate (never marks complete on read failure) | `testMigrationFromRealV1Store` (red-then-green: forced `S<E` data-loss) |
| **R2 real search engine** | live search now routes free-text + boolean through the FTS5 engine (was using an in-RAM engine); population-gated fallback; prefix match; mutation-versioned cache | `testLiveSearchDispatchesToFTS` (red-then-green: counter 0) |
| **Delete integrity** | `EmailStore.delete` + FTS delete — deleted emails no longer linger as searchable ghost rows | `testDeleteRemovesFromStoreAndSearch` |
| **Store↔FTS reconcile** | `indexMissing` repairs drift (crash between store + FTS commit); guarded launch reindex | `testReconcileIndexesMissing` |
| **Redaction** | exported redaction actually strips content (secret absent from output), not a visual box | `testRedactionStripsContentFromOutput` |

### 🔨 Build-verified (compiles + integrated; not fixture-tested)
- **S/MIME** — honors cert-trust (no false "Valid" on untrusted chains); detached `multipart/signed` no longer false-"Invalid". *High-liability; stays build-verified until untrusted-CA + genuine-detached fixtures added.*
- **Crash hardening** — NSF slice crash, MSG integer overflows, OLE2 recursion → iterative
- **OOM ceilings** — 500 MB MBOX / 200 MB NSF-scan caps → clean error, not OOM
- **No silent drops** — streaming import now counts skipped messages (forensic completeness)
- **Schema versioning** — SwiftData `VersionedSchema` + migration plan (future changes won't brick launch)
- **Biometric lock** — wired into app launch (was dead code)
- **ZIP** — extracts all advertised formats + zip-slip guard + off-main extraction
- **Dedup errors** — stop silently swallowing dedup-fetch failures

### 🟡 Relabeled to match reality (honesty fixes)
- **SPF/DKIM/DMARC** — copy changed from "Verify" → "as reported by the receiving server" (it reads headers; it does not cryptographically verify)
- **AES-256 storage** — claim dropped (manager was dead code; store uses OS file protection)
- **iCloud sync** — claim dropped (compiled out of the offline build)
- **PST export** — marked experimental / not guaranteed loadable in Outlook
- **Info.plist** — removed the misleading IMAP/network usage key

### ✅ Already-true claims (audit confirmed, no change needed)
Streaming mbox ingest, resumable checkpoints, keyset pagination, year-sharded FTS5 engine (now actually queried), strictly-offline / no-network entitlement, on-device AI (sentiment, topics, predictive coding, AI assistant, anomaly), 11-language localization, Vision OCR, Spotlight, Ed25519 signed exports, HMAC audit log, Bates, chain-of-custody.

---

## 3. Remaining (deferred — explicit plan calls, not hidden gaps)

| Item | Status | Why |
|---|---|---|
| **Real DKIM/DMARC crypto** | ⏸️ deferred | Weeks of work (DNS + canonicalization + verify); archived selectors often gone from DNS anyway. Honest relabel shipped in its place. |
| **True ZIP streaming** | ⏸️ partial | Extraction moved **off-main** (beachball fix) but still reads whole zip into RAM; central-directory streaming is a separate rewrite. |
| **Loadable PST writer** | ⏸️ deferred | Real PST writing is weeks; relabeled "experimental" instead. |
| **Full RecoveryReport UI** | 🟡 partial | Worst silent-drop (streaming MBOX) fixed + counts recorded; per-parser UI surfacing is incremental. |
| **S/MIME fixtures** | 🔨 | Promote 3.3 from build-verified to executed with untrusted-CA + detached-signature fixtures. |
| **>50 GB PST / >2 GB MSG / >500 MB EMLX** | ⏸️ | Per-format hard ceilings remain (plan-known); large PST is a v2.1 streaming-walker item. |

---

## 4. 🚦 Release gates (block shipping — NOT code, can't be pushed)

1. **Device smoke test = the real R1 gate.** The XCTest used a *synthetic* temp-dir v1 store; a real v1→v2 upgrade on hardware (real Application Support paths, interrupted-then-resumed) is **unrun**. Run `V2_SMOKE_TEST.md` on a device before shipping.
2. **Step 9 = business decisions.** Pricing must be reconciled (landing page vs `AppStoreMetadata.txt` differ) and the "Now live on the App Store" copy made accurate. Decided-and-applied, not a code task.

**Merge is safe (strict improvement over `main`); shipping is blocked on the two gates above.**

---

## 5. Reference docs in repo
- `V2_CLAIMS_AUDIT_AND_ACTION_PLAN.md` — full claims-vs-code audit + plan
- `V2_IMPLEMENTATION_LOG.md` — chronological record of every change + corrections
- `V2_SMOKE_TEST.md` — device test matrix + directional pass rule (S≥E)
- **PR #3** — four-tier ledger + "merge ≠ release" banner

# mailin 3.0 — Private-App Plan (deferrals + edge-case todo)

Date: 2026-09-24. Supersedes the scope line in `V3_0_PLAN.md` §"Locked
decisions", which said **all four pages including Live Mail** ship in 3.0.

**New scope decision (owner, 2026-09-24):** 3.0 ships as a **private app** —
privately distributed, network-free, Pages 1–3. Everything that only makes
sense for a public consumer app, or that requires the app to reach the network,
is **deferred out of 3.0**.

---

## 1. What "private app" means concretely

| Dimension | 3.0 Private |
|---|---|
| Distribution | Apple Business Manager **Custom App** (private), per organisation ID |
| Bundle | `com.ecosanskriti.mailin.enterprise` — separate from the live public listing |
| Entitlements | sandbox, user-selected files, app-scope bookmarks, print. **No `network.client`. No iCloud.** |
| Build flag | `NO_NETWORK_BUILD` (today's `OFFLINE_MODE`, renamed) — network code is *absent*, not merely disabled |
| Pages | Archive, AI Insights (on-device only), Professional Workflows |
| Monetisation | Paid-upfront per seat via ABM. **No IAP, no paywall UI, no tier gating** |
| Claim | "Cannot reach the network" — provable from the signed entitlements, not from a runtime promise |

The public consumer app on the store continues on the **2.x line** and is not
touched by this plan.

### Why this is a simplification, not a retreat

Dropping network from 3.0 removes, in one stroke: the Google restricted-scope
verification clock (weeks, possibly a CASA security assessment), Microsoft Entra
registration, provider policy compliance, the App Store privacy-label rewrite,
the "prove zero network while disabled" instrumentation, and the multi-account
sync/outbox correctness surface (wrong-account send, duplicate send on retry,
token expiry, throttling). It also makes the strongest claim in the product
literally true instead of conditionally true.

---

## 2. Deferred out of 3.0 — and the cost of deferring

| Deferred | Why it does not fit a private app | What we lose | Where it goes |
|---|---|---|---|
| **Live Mail (Page 4)** — accounts, IMAP/SMTP, Graph, compose, outbox, sync | Requires `network.client` in the signed binary; requires provider verification; contradicts "nothing to breach" | No send/receive. Users keep using their existing mail client | **3.1 Public** (or never, if the private line is the product) |
| **iCloud Overflow (P8)** | Requires iCloud entitlements and puts evidence-derived segments in Apple's cloud; the whole feasibility question is unresolved | No cloud cold tier. Large corpora need an external SSD | **Deferred indefinitely**; external-SSD tier covers the real need |
| **Cloud AI provider** (`CloudAIProvider.swift`) | Network egress of message content, even opt-in | AI is on-device only — smaller models, no frontier-model quality | Stays compiled out; revisit only for the public line |
| **iCloud metadata sync** | Already deleted (it synced case metadata to the ubiquity container and could not work without the entitlement) | Nothing: it never shipped | Gone |
| **IAP / paywall / tier gating** | ABM Custom Apps are bought per seat; consumer IAP does not flow through volume purchasing, and dead IAP UI is an App Review rejection risk | Nothing for this SKU | Public line keeps 2.x IAP |
| **App Store consumer artefacts** — screenshots, keywords, What's New, rating prompt | A Custom App needs a review build and notes, not a storefront | Nothing | Public line |
| **Consumer onboarding polish** — persona picker as a launch step, welcome hub | An org deploys with managed configuration; the operator is not a first-time consumer | Nothing; the MDM path replaces it | Already off the launch path |
| **Apple Mail / Thunderbird handoff (P4)** — *partially* deferred | Export to MBOX stays (it is offline and genuinely useful). The **guided "Import from Apple Mail…" flows** and the executed third-party import tests are consumer-facing polish | Users do the target-app import themselves, unguided | Export **in**; guided flows + executed target tests **3.1** |

### Deferrals that must be stated publicly, not silently

Anything in `V3_0_PLAN.md` §11 that promised Live Mail or iCloud in 3.0 must be
struck before any collateral is written. The enterprise page may claim
"network-free by construction"; it may **not** claim send/receive is coming on
a date.

---

## 3. In scope for 3.0 Private — sequenced

### Phase A — finish the size-limit spine (in flight)
S3b blob tier wiring → S4 offset parser → S5 locator-backed reads. This is what
makes "no artificial caps" true, and it is the only remaining *architectural*
risk in the private scope.

### Phase B — Page 1 completion
A3 guided import sheet, A4 import queue, A5(d) attachment-family coverage,
A6 index-coverage badge, A7 advanced search sheet, A8 export sheet + receipt,
plus the storage tiers that matter offline: **Mac internal** and **local
external SSD** (no cloud tier).

### Phase C — Pages 2 and 3 re-hosting
I1–I5 (AI Insights, on-device only — the Cloud AI rows disappear from the
matrix) and P1–P4 (Professional), including the **51-row** workflow inventory.

### Phase D — Enterprise deployment
`NO_NETWORK_BUILD` configuration, managed-configuration keys end to end, sealed
`.mailincase` bundles, multi-examiner merge, the assurance pack, and the ABM
Custom App record.

### Phase E — Evidence
Scale matrix on real corpora, the 13 deliverable documents, release readiness
with owner/Apple gates separated.

---

## 4. Detailed todo list, with edge cases

Each item lists the **edge cases that must be handled and tested**, because
that is where this app's correctness actually lives. Items marked ⛔ are
blockers for the phase.

### A. Size-limit spine

#### A1 ⛔ S3b — wire the blob tier (7 sites, one atomic change)
Edge cases:
- Blob written, **row commit fails** → orphan, collectable; never a dangling reference
- Row committed, **blob file deleted externally** (user cleaned the library) → named error, not empty body; the message is flagged as body-missing rather than silently blank
- **Blob content modified externally** → digest mismatch surfaces as tamper, message not served as authentic
- Two messages with **identical raw bytes** → one blob, two rows; deleting one message must not delete the blob
- **Orphan GC racing an active import** → GC must take the referenced set inside the same transaction window, or skip while an import is running
- A row with **both** inline `raw` and a blob digest (should be impossible) → inline wins, log a fault
- Message exactly **at** the 8 MiB threshold → deterministic tier choice, tested on both sides
- The four backfill predicates (`length(b.raw)`) must treat a blob-backed row as **having** raw, or the backfills loop forever "repairing" it
- Migration: an existing 2.x database has no blob columns → additive `ALTER TABLE`, and every existing row stays inline
- Blob directory **read-only** or on a full volume → import refuses with the storage reason, no partial state
- `blobs/` on an **ejected external volume** → named error and pause, not a crash

#### A2 ⛔ S4 — offset parser (high risk)
Edge cases:
- mbox with **no trailing newline**; file ending mid-header; file ending mid-body
- **CRLF vs LF vs CR** line endings, mixed within one file
- `>From ` quoting present, absent, or doubled (`>>From `)
- An unquoted `From ` **inside a body** that looks like a separator (date-shaped) → must not split a message
- First line is not a separator (bare `.eml` handed to the mbox path)
- **Header line > 998 chars**; folded headers; a header with no colon; duplicate `Subject`
- RFC 2047 encoded words in every header; **mislabelled charset**; 8-bit bytes in headers
- `Date` missing / unparseable / year 1601 / year 3000 → shard 0, never a negative-year shard filename
- **Message-ID** missing, duplicated, or absurdly long
- MIME: unterminated multipart; **boundary appearing inside a body**; nested `message/rfc822` to depth 10; boundary with trailing whitespace; `Content-Transfer-Encoding` unknown
- base64 with invalid padding / stray characters; quoted-printable soft line breaks and `=3D` at a chunk edge
- A **single message of 2 GB** (the S3 case) and **1 M tiny messages** in one file
- Attachment with **no filename**; filename containing `/` or `..`; filename 1000 chars; two attachments with the same name
- **I/O error mid-parse** → throws with the byte offset, never treated as EOF (existing guarantee; must survive the rewrite)
- **Force quit** at: before first batch, mid-batch, after store commit but before checkpoint, after checkpoint but before FTS → no omission, no duplication
- Resume when the **batch envelope changed** between runs (adaptive batching makes this normal), when the **parser version** changed, and when the **source file was modified** (hash mismatch → refuse resume, restart)

#### A3 S5 — locator-backed reads
Edge cases:
- Locator offsets that no longer match (source replaced) → verify against the message digest before trusting a range
- Range beyond blob length → refused, not truncated
- Attachment whose bytes are **absent from the source** (NSF/DAOS externalised attachments are the real case) → reported as unavailable with the reason, not as a zero-byte file
- Inline (`cid:`) parts vs real attachments; same part referenced twice
- Export of a message whose blob is missing → export receipt records the failure per message, run is Partial

### B. Page 1 completion

#### B1 A3 — guided import sheet
Edge cases:
- Selection contains a mix of supported, unsupported, and unrecognised files → per-file verdicts shown **before** Start, using the existing classifier
- Zero-byte file; file that **disappears between selection and Start**; permission denied; file on an **unmounted** volume
- Selection is a **folder** (Apple Mail package, Maildir, or arbitrary directory) → classified per §A12
- Duplicate paths differing only by case; symlink pointing outside the sandbox; alias file
- Same source selected **twice** in one run
- **Copy vs reference** choice: reference requires a security-scoped bookmark; the bookmark must survive relaunch and be shown as stale when it does not
- Required-space figure comes from `StoragePlanner`; the sheet must refuse Start when the plan says insufficient and show the shortfall
- Encrypted/password-protected PST, WIP-protected PST → surfaced before Start, not discovered at message 400,000

#### B2 A4 — import queue
Edge cases:
- Pause **during** a batch commit → must pause at a boundary, not mid-transaction
- Stop this source while others are queued → other sources unaffected, receipt records the stop
- Reorder while running; remove the running source; add a source mid-run
- Source becomes unreadable mid-run (ejected drive, deleted file) → that source fails, the run continues
- **Disk fills mid-run** (ENOSPC) → pause with the storage reason, resume after the user frees space, no corruption
- Browsing/searching the archive **during** import must stay responsive (the directive's work-fairness rule)
- App quit with an import running → resume offers exactly the right position on relaunch
- ETA must be labelled an estimate and must not go backwards absurdly
- The **pause reason** from `AdaptiveBatchController` must be visible (it is currently only logged)

#### B3 A6/A7 — search coverage and advanced search
Edge cases:
- Query containing FTS5 syntax (`"`, `*`, `NEAR`, `AND`) typed literally by a user
- Empty query; whitespace-only; a single character; 10,000-character query
- Partly-indexed messages in the result set → badge says so (S0 data exists)
- A shard file **missing or corrupt** → search over remaining shards succeeds and *reports* the gap rather than returning a confident zero
- Unicode: normalisation (é vs e+◌́), CJK with `porter unicode61`, right-to-left, emoji
- Date filters crossing DST and time zones; `after > before`
- Attachment-name search vs attachment-content search — the difference must be visible
- A filter combination that matches nothing vs one that cannot be evaluated → different messages

#### B4 A8 — export sheet and receipt
Edge cases:
- Destination full; read-only; **exFAT/FAT32 4 GB single-file limit** (a whole-archive mbox will exceed it) → partition output and say so
- Filename collisions; illegal characters; path length limits; two messages with the same subject in per-message export
- Cancellation mid-export → partial artefact removed or clearly marked, receipt records cancellation
- Export scope that changes under the export (a concurrent delete) → receipt reconciles requested vs written
- Attachment bytes unavailable (see A3) → per-message failure list, run marked Partial
- Round-trip verification: re-parse the artefact and compare counts; refuse to claim success from a write receipt alone

#### B5 Storage tiers (internal + external SSD only)
Edge cases:
- External volume **ejected mid-write** → detect before the next write, pause, resume on reconnect
- External volume is **exFAT/NTFS/network share** → refuse for the active store (no valid WAL locking), allow for export output
- Volume remounted at a different path → bookmark resolution, not a stored path
- Two libraries on two volumes; both plugged in; the app must not merge them
- Volume full while WAL is growing → checkpoint, then pause with the reason

### C. Pages 2 and 3

#### C1 AI Insights (on-device only)
Edge cases:
- The on-device model is **unavailable** on this OS/hardware → the page says so and offers nothing it cannot do
- Model load fails or is evicted under memory pressure mid-answer
- A question whose scope selects **zero** messages, or the entire 1 M-message archive
- Citations must reopen the exact message; a citation whose message was **deleted since** must say so rather than 404 silently
- Prompt-injection text inside imported mail must never be treated as instruction (existing rule, needs a test)
- Every Cloud AI row disappears from the feature matrix in this SKU — the matrix must not advertise what the build excludes

#### C2 Professional Workflows
Edge cases:
- Legal hold: held message cannot be deleted, and the hold **survives** disabling Page 3 (already a stated rule, needs a test)
- Audit chain: genesis at enablement, honest about the pre-enablement gap; `verifyChain()` on a long chain must not block the UI
- Bates numbering: restart, gap, and collision behaviour; a number issued then the run cancelled
- Redaction: the S0-era token rules; a name that is also a common word; redaction applied then the export cancelled
- 51-row inventory: every row either validated by an SME or marked **Draft** — no row may imply certification
- Production export: requested vs included vs excluded counts must reconcile; attachment families kept together

### D. Enterprise deployment

#### D1 ⛔ `NO_NETWORK_BUILD` configuration
Edge cases:
- Verify the **signed** binary's entitlements contain no `network.client` (the check I still owe — `codesign -d --entitlements` kept timing out in this environment)
- Live Mail/Cloud AI code must be **absent**, and `ModuleRegistry.buildExclusions` must report Live Mail as `.unavailable` with "not included in this edition"
- A user with a 3.0 state file that has `liveMail: true` (from a public build) → must render as unavailable, never as on

#### D2 Managed configuration
Edge cases:
- Managed dictionary **arrives after launch** → policy must apply without a restart
- Org disables a module **while its page is open** → page falls back to Archive (router already does this; needs an MDM-triggered test)
- Conflicting keys; unknown keys; a key with the wrong type → ignored with a fault log, never a crash
- `disabledModules` naming a module that does not exist
- Enforced biometric lock with no biometric hardware → passcode fallback, never lockout

#### D3 Sealed case bundles + multi-examiner merge
Edge cases:
- Bundle opened on a Mac with a different app version / schema
- Tampered bundle → refused with a diff of what failed
- Merge with a **deliberate conflict** → both readings preserved, never silently merged
- Two examiners with the same name; an examiner name from managed config vs local
- Bundle containing a blob-backed body (S3b) → blobs travel with the bundle or the bundle is refused as incomplete

### E. Evidence and release

#### E1 Scale matrix
Edge cases: the P9 matrix, minus every cloud row. Corpora we cannot obtain are
marked **NOT TESTED** — never inferred.

#### E2 The 13 documents
`SUPPORTED_FORMATS_AND_LIMITS.md` (owed since S1), `MODULE_ACTIVATION_MATRIX.md`
(needs a clean container), `ADAPTIVE_IMPORT_DESIGN.md`, `IMPORT_RECEIPT_SPEC.md`,
`STORAGE_TIER_FEASIBILITY.md` (external SSD only), `WORKFLOW_INVENTORY.md` (51
rows), `SCALE_RESULTS.md`, `MAIL_CLIENT_HANDOFF_TESTS.md` (export only),
`PAGE_WINDOW_MATRIX.md`, `RELEASE_READINESS.md`, plus the enterprise assurance
pack. `LIVE_MAIL_*` and `NETWORK_AND_PRIVACY_MATRIX.md` shrink to one page each
stating that the build has no network capability.

---

## 5. What this does to the estimate

| Scope | Engineering-days |
|---|---|
| 3.0 as originally locked (four pages) | ~210–300 |
| **3.0 Private (this plan)** | **~120–160** |
| Removed by deferring Live Mail | ~50–70 |
| Removed by deferring iCloud Overflow | ~15–25 |
| Removed by dropping IAP/store/consumer artefacts | ~10–15 |

Plus the external clocks that disappear entirely: Google verification,
Microsoft registration, App Store privacy review of network features.

---

## 6. Release gates for 3.0 Private

1. Signed binary proves no network entitlement (D1)
2. Every claim in the enterprise collateral maps to a passing test or a
   measured number; anything else is marked NOT TESTED
3. The 51-row inventory has no row implying certification without SME validation
4. A genuine 2.x customer library opens unchanged
5. Apple review of the Custom App build, and the owner's own sign-off

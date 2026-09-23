# mailin 3.0 — Four-Page Architecture Plan

Date: 2026-09-23 · Basis: `Mailin-Xcode-Agent-Revised-Directive-2026-09-23.md`
(the directive), verified against working tree at `771e993`.

**Relationship to the older V3 docs.** `V3_PLAN.md` and `V3_RELEASE_PLAN.md`
describe the five-studio + Researcher-persona work, which is code-complete and
behaviorally verified. That work **re-numbers to 2.1** and ships before this
plan's work begins (§2). "3.0" from here on means the four-page module
architecture described by the directive, including Live Mail.

**Locked decisions (owner, 2026-09-23):**

| Decision | Choice |
|---|---|
| 3.0 scope | All four pages, **including Live Mail** + iCloud Overflow prototype |
| Module boundaries | Extract **ArchiveCore as a local Swift package**; AI / Professional / Live Mail stay in-target behind a registry with lazy construction, extracted package-by-package later |
| Release order | iOS 2.0 → 2.0.1 → **2.1 (studios)** → 3.0 (this plan) |
| Platforms | **macOS-first** and verified there; the iOS build must keep compiling and stay usable, but iOS parity does not gate 3.0 |

---

## 1. Verified baseline (re-verified today, not copied from docs)

The directive requires re-verifying current code facts at implementation time.
Done; these are the facts 3.0 is planned against.

| # | Fact | Evidence |
|---|---|---|
| B1 | **One monolithic app target.** `maxmailin` (application) + `maxmailinTests` + `maxmailinUITests`. No Swift packages, no frameworks. 241 Swift files, ~132,600 lines. | `XcodeListTargets`; `find maxmailin -name '*.swift' \| wc -l` |
| B2 | Project uses **file-system synchronized groups** (4 × `PBXFileSystemSynchronizedRootGroup`), with **no membership exceptions** — every `.swift` file in the folder is compiled into the app. Adding a file to the folder ships it. | `project.pbxproj` |
| B3 | Bundle id `com.ecosanskriti.mailin`, `MARKETING_VERSION = 2.0`, universal: `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`, `TARGETED_DEVICE_FAMILY = 1,2`, macOS 14.6 / iOS 17.6 minimums. | `project.pbxproj` |
| B4 | **`OFFLINE_MODE` is defined in Debug *and* Release** for the app target (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`). Every `#if !OFFLINE_MODE` file is therefore absent from shipping builds. | `project.pbxproj:572, :624` |
| B5 | Live-mail-ish code exists but is **entirely compiled out** by B4: `IMAPClient.swift` (745), `SMTPClient.swift` (451), `GmailConnector.swift` (424), `OutlookConnector.swift` (625), `ComposeEmailView.swift` (783), `IMAPConfigView.swift` (328), plus `iCloudSyncManager.swift` (562) and `CloudAIProvider.swift` (757). ~4,675 lines of unshipped, unverified-against-current-provider-policy code. | file heads + `wc -l` |
| B6 | **Entitlements contain no networking and no iCloud**: sandbox, print, `files.user-selected.read-write`, `files.bookmarks.app-scope`. Signed target uses `mailin/mailin.entitlements`. | `mailin/mailin.entitlements`, `project.pbxproj:532` |
| B7 | Importer batch policy is **fixed**: `Options.batchSize = 500`, clamped `max(1, min(batchSize, 10_000))`. No resource-aware tuner, no byte-based bound, no pressure response. | `BulkImportCoordinator.swift:68, :160, :202` |
| B8 | **No storage tiering exists.** No `StoragePlanner`, no `volumeAvailableCapacity` query, no external-volume/eject handling anywhere in the target. | grep across `maxmailin/*.swift` |
| B9 | Production SQLite lives under `applicationSupportDirectory/…/emails.db` with WAL and year-sharded FTS; shard handles close under memory pressure. | `SQLiteEmailStore.swift:43–89`; `mailinApp.swift` memory-pressure wiring |
| B10 | A **real streaming MBOX writer exists** (`exportMBOXArchive`) using stored `rawSource` with `>From` quoting — but the envelope line is hardcoded `From MAILER-DAEMON Thu Jan  1 00:00:00 1970`, and when `rawSource` is empty it synthesizes headers + plain body only (**attachments dropped**). No export receipt, no round-trip verification. | `ArchiveExportService.swift:559–580` |
| B11 | **No Apple Mail / Thunderbird handoff feature.** Those names appear only in import help text and an "Apple Mail auto-import" path. No guided export sheet, no post-import verification. | `ContentView.swift:1975–2007`, `ContentViewModel.swift:558` |
| B12 | The workflow catalog is **51 definitions**, not 47 (`WorkflowEngine.all`: 47 v2 + `researchProtocol`, `researcherScreening`, `researcherCoding`, `forensicEvidencePlan`). | `WorkflowEngine.swift:1280–1293` |
| B13 | Launch is **not module-gated today**: `PersonaOnboardingView` is presented as a launch sheet, and `BackgroundAnalysisManager.shared.scheduleBackgroundAnalysis()` runs unconditionally in `onAppear`. 69 `static let shared` singletons exist across the target. | `mailinApp.swift:36–110`; grep |
| B14 | Format ceilings currently enforced: MBOX/EML per-message 100 MB; **PST/OST 50 GB**; **NSF 64 GB**; ZIP explicitly unsupported. | `V2_FORMAT_MATRIX.md` + parser caps |
| B15 | Largest executed production-path run: **1,000,000 messages / ~4.7 GB / 582 MB peak RSS**. Nothing at 16/50/100/200 GB or 1 TB has been executed. | `V2_IMPLEMENTATION_COMPLETE.md:16–18` |

**Consequences that shape the whole plan:**

1. B4 + B6 mean today's shipping binary *cannot* make a network connection —
   the directive's "zero network while disabled" baseline currently holds **by
   construction**. Shipping Live Mail replaces that structural guarantee with a
   *runtime* guarantee, which must then be proven by test (§8, P7.1) and
   re-disclosed on the App Store (§11).
2. B2 means "module off" can never mean "not linked" inside this target. Real
   enforcement in 3.0 = ArchiveCore package boundary (compiler-enforced for the
   core) + registry/lazy-construction + tests that assert no jobs, files, or
   sockets appear when disabled.
3. B7/B8/B10/B11 are the genuinely new Page 1 engineering; Pages 2–3 are mostly
   *re-hosting and gating* work over code that already exists.

---

## 2. Release train

```
NOW   iOS 2.0            in review / release           (owner)
      2.0.1  both        PST export fix, IAP discoverability
      2.1    both        five studios + Researcher persona  ← today's V3_PLAN.md work
      ───────────────────────────────────────────────────────
      3.0    macOS-first four pages, modules off by default,
                         adaptive import, storage tiers, handoff,
                         Live Mail, iCloud Overflow (feasibility-gated)
      3.0.x              iOS parity follow-ups, Enterprise Offline SKU refresh
```

Rule: 3.0 branches from the 2.1 tag. No 3.0 work lands on the 2.x release
branch. `V3_PLAN.md` / `V3_RELEASE_PLAN.md` need their version strings changed
from 3.0 → 2.1 when 2.1 is cut (small doc edit, not part of 3.0).

### Two signed configurations in 3.0

Because Live Mail forces `com.apple.security.network.client` into the signed
app, the "nothing to breach" enterprise story needs a home:

| Configuration | Bundle id | Entitlements | Modules present |
|---|---|---|---|
| `mailin` (consumer/store) | `com.ecosanskriti.mailin` | sandbox, files, bookmarks, **network.client**, **iCloud** (container TBD) | All four pages; AI/Professional/Live Mail default **off** |
| `mailin Enterprise Offline` | `com.ecosanskriti.mailin.enterprise` | sandbox, files, bookmarks — **no network, no iCloud** | Pages 1–3 only; Live Mail + iCloud Overflow **compiled out** via the existing `OFFLINE_MODE`-style flag (renamed `NO_NETWORK_BUILD`) |

This keeps `OFFLINE_MODE`'s value (a binary that provably cannot reach the
network) instead of deleting it, and it matches the Custom App / ABM decision
already made in `V3_RELEASE_PLAN.md` §R3.

---

## 3. Target architecture

### 3.1 Package and module layout

```
mailin.xcworkspace
├─ Packages/ArchiveCore                     ← NEW local Swift package (P1)
│   ├─ ArchiveCoreModel      canonical message, provenance, locator, IDs
│   ├─ ArchiveCoreStore      SQLiteEmailStore, FTS shards, migrations, WAL policy
│   ├─ ArchiveCoreParsers    ParserFactory, MBOX/EML/EMLX/MSG/PST/OST/NSF
│   ├─ ArchiveCoreImport     BulkImportCoordinator, AdaptiveBatchController,
│   │                        Reconciler, ImportReceipt, StoragePlanner
│   └─ ArchiveCoreExport     streaming exporters, MBOXWriter, ExportReceipt
└─ maxmailin (app target)
    ├─ AppShell              ModuleRegistry, JobRegistry, routing, Settings>Modules
    ├─ ArchiveFeature        Page 1 views + view models
    ├─ AIInsightsFeature     Page 2 (in-target, registry-gated)
    ├─ ProfessionalFeature   Page 3 (in-target, registry-gated)
    └─ LiveMailFeature       Page 4 (in-target, registry-gated) + MailTransport
```

Dependency rules, enforced by a CI lint step plus the package boundary:

- `ArchiveCore` imports **nothing** from the app target. It has no SwiftUI
  dependency in the store/parser/import/export layers.
- Every feature reaches ArchiveCore only through protocols:
  `ArchiveReading` (paged/keyset queries, streams), `ArchiveImporting`
  (submit source + observe receipt), `ArchiveExporting`, `ArchiveIdentity`
  (stable IDs + locators). No feature touches SQL or table names.
- `LiveMailFeature` may **not** write archive tables. Its only path into the
  archive is `ArchiveImporting` via the bridge service (P7.7).
- A grep-based CI check fails the build on `import ArchiveCoreStore` from any
  feature file, and on `SQLite`/`sqlite3_` symbols outside ArchiveCore.

Why ArchiveCore only: with 241 files in synchronized groups (B2), a full
seven-package split is a multi-week mechanical refactor with a large regression
surface. ArchiveCore is the boundary that actually buys enforcement (it is what
all four pages share), so it goes first; feature packages get extracted in
3.1+ as each stabilizes.

### 3.2 Module registry

```swift
enum AppModule: String, CaseIterable, Sendable {   // AppShell
    case archive, aiInsights, professional, liveMail
}

enum ModuleActivation: Sendable {
    case unavailable(reason: String)   // build excludes it (NO_NETWORK_BUILD)
    case disabled
    case enabledNoAccounts             // Live Mail only
    case active
    case paused(reason: String)
    case error(String)
}

@MainActor @Observable final class ModuleRegistry {
    func activation(_ m: AppModule) -> ModuleActivation
    func enable(_ m: AppModule) async throws     // may require consent sheet
    func disable(_ m: AppModule, retention: RetentionChoice) async
    func register(_ m: AppModule, factory: @escaping () -> AnyModuleHost)
    var jobs: JobRegistry                        // observable, per-module
}
```

- State persisted in a small versioned store (`ModuleState.v1.json` in
  Application Support) — **not** scattered `@AppStorage` flags.
- `EnterpriseConfig` managed-config keys can force a module to
  `.unavailable` (org hard-off), which the UI must render as locked-by-org, not
  as user-off.
- Feature hosts are built by **factory closures**, so a disabled module's types
  are never instantiated. `@Observable` feature managers must lose their
  `static let shared` eager initialization (B13) — P1.4.
- `JobRegistry` is the single truth for "what is running": import, index,
  embedding, workflow, sync. Settings > Modules and the Activity window both
  read it.

### 3.3 Page independence and zero load when off (hard requirement)

Owner requirement, 2026-09-23: *"each page and its functions should only depend
on it only, not other pages — unless the user activates a feature or page it
should not run and increase the load."* This is a release gate, not a design
preference.

**R1 — Each page depends only on itself.** A page owns its own views, view
models, state store, jobs and settings. No feature file may import another
feature's types. Anything genuinely shared goes into ArchiveCore behind a
protocol, or through the explicit Live Mail → Archive bridge (P7 L7). Enforced
by the CI lint in §3.1 plus a per-feature import allow-list.

**R2 — Nothing for a page exists until it is activated.** While a module is
disabled there is: no type instantiation, no state file created, no
`UserDefaults` key written, no timer or scheduled task, no index or embedding,
no model load, no socket, and no schema migration. Feature hosts come from
registry factory closures (§3.2); a feature's state store is created on first
enable, not at launch. Optional-module types may not keep a work-performing
`static let shared` — first access must allocate nothing and schedule nothing.

**R3 — Enabling a page is the only thing that adds load.** Acceptance is
measured, not asserted. For all-off, and then for each module enabled
individually, record: cold-launch ms, idle RSS, 60-second idle CPU, disk I/O
bytes, open file handles, live timers, and network connections. The all-off
column is the baseline; every other column's delta must be attributable to that
module alone.

**R4 — Disabling returns to the baseline.** Turning a module off stops its jobs
promptly, releases its memory, and returns the R3 measurements to the all-off
numbers, while preserving its saved artifacts on disk (reports, cases, holds,
accounts' local cache per the retention choice).

**R5 — Enforcement in code, not review.** Three mechanisms: (a) the §3.1 import
lint; (b) a "constructed while disabled" trap — registry factories assert in
Debug and report in Release if a disabled module's host is built; (c) a launch
instrumentation test that fails if any optional-module file, timer, or
connection appears during a disabled cold launch.

The six launch-time offenders that violate R2 today are inventoried in
`RELEASE_READINESS.md` §P0.1 and are P1's first fixes.

### 3.4 Entitlement / capability matrix (3.0)

| Entitlement | Consumer 3.0 | Enterprise Offline | Gate |
|---|---|---|---|
| `com.apple.security.app-sandbox` | ✅ | ✅ | — |
| `files.user-selected.read-write` + `files.bookmarks.app-scope` | ✅ | ✅ | — |
| `com.apple.security.print` | ✅ | ✅ | — |
| `com.apple.security.network.client` | ✅ (new) | ❌ | Live Mail, Cloud AI provider, iCloud API verification |
| `com.apple.developer.icloud-container-identifiers` + services | ✅ (new, container id TBD) | ❌ | iCloud Overflow only; **P8 feasibility gate** — if P8 fails, this entitlement does not ship |
| Keychain access group | ✅ (new) | ❌ | Per-account OAuth token isolation |

Not requested: default-mail-client entitlement (directive §6 — not needed to
send/receive), MailKit extensions.

---

## 4. Page 1 — Archive (default, always on)

Goal: first launch is a familiar three-pane mail-style archive explorer with
Import / Search / Export and **no persona picker, case setup, or AI prompt**.

| ID | Work | Detail | Est. |
|---|---|---|---|
| A1 | Default-route to Archive | Remove persona onboarding from the launch path (B13); `PersonaManager` becomes a Page 3 preference, migrated silently for existing users. Fresh install: sidebar = All mail + imported sources; toolbar = Import, one search field, Export. | 3–5 d |
| A2 | Three-pane shell | Sidebar (All mail, source/folder tree, saved searches) / list / detail, with keyset pagination + stable IDs + lazy body hydration. Audit `ContentView.swift` (6,041 lines) and split it; any remaining `[RawEmail]` full-corpus array is a defect to remove. | 8–12 d |
| A3 | Guided import sheet | Source-guided flow: pick format/source → copy vs reference → destination → duplicate policy → indexing choices → required space → Start. Shows unsupported/encrypted/corrupt variants **before** start. | 5–7 d |
| A4 | Import queue UI | Start/pause/resume/stop per source, reorder, browse+search during import; per-source bytes, messages, throughput, stage, **current batch size**, resource status, indexed fraction, ETA-as-estimate, pause reason. | 4–6 d |
| A5 | Import receipt | `ImportReceipt` value type + store: source SHA-256, parser/build version, start/end, offset/ordinal checkpoint, discovered/stored/duplicate/skipped, FTS coverage, attachment coverage, error list; printable/saveable; `Recheck`/`Retry`. Status is exactly one of Complete / **Partial** / Failed, decided by `Reconciler`, never by "no exception thrown". | 6–8 d |
| A6 | Index-coverage truth | A coverage badge on search results; a partial index may **never** return an unqualified zero. Requires a per-source coverage record (bodies indexed, attachment text indexed, pending). | 4–5 d |
| A7 | Advanced search sheet | Dates, people, folder, has-attachment, filename/type, phrase, AND/OR/NOT **only where tested**; results show matching field + Open exact original. | 4–6 d |
| A8 | Export sheet + receipt | Scope (selected/filtered/folder/whole archive), format, destination, folder layout, attachment inclusion, collision rule, size estimate; progress → verification window with requested/written/failed, output hashes, Open in Finder. Interrupted exports resume or fail loudly. | 5–7 d |

Deliverable: `PAGE_WINDOW_MATRIX.md` — every control and state above for all
four pages.

---

## 5. Adaptive importer + storage tiers

### 5.1 `AdaptiveBatchController` (ArchiveCoreImport)

Replaces B7's fixed 500. Bounds **both** message count and parsed bytes.

```swift
struct BatchEnvelope: Sendable { var maxMessages: Int; var maxBytes: Int }

protocol PressureSource: Sendable {            // testable, injectable
    func sample() async -> PressureSample       // RSS, memory-pressure level,
}                                               // free disk, thermal, WAL latency,
                                                // commit p50/p95, UI loop lag
actor AdaptiveBatchController {
    init(envelope: BatchEnvelope, budget: MemoryBudget, sources: [PressureSource])
    func next(after outcome: BatchOutcome) -> BatchEnvelope
    var trace: [EnvelopeTransition] { get }     // for diagnostics + receipt
}
```

- **Start envelope:** conservative, derived from machine RAM and source format —
  the directive's example is 128 messages / 16 MiB; the *shipped* numbers come
  from P9 measurements, not from this document.
- **Fast path:** grow bounds gradually only while RSS, event-loop latency, free
  disk, WAL latency and thermal state are all healthy.
- **Pressure response:** shrink immediately on rising RSS, long commit stalls,
  thermal/battery pressure, FTS backlog or low disk; **pause with an actionable
  reason** at hard thresholds.
- **Oversized item:** a single message larger than `maxBytes` streams to a
  bounded temp spool / chunked representation — never a whole-file `Data`, never
  a broken envelope.
- **Transaction boundary:** checkpoint (offset/ordinal + source SHA-256 + parser
  version + dedup policy) is durable **only after** the store transaction; FTS
  reconciles independently. Force-quit at each boundary must produce neither
  silent omission nor duplication.
- Manual batch size survives **only** as a troubleshooting override in a
  diagnostics pane, not as a user-facing setting.
- Concurrency rule to verify first: one SQLite writer; parse/hash/decompress/
  index workers may overlap **within queue limits**; confirm the current
  `@MainActor` coordinator does not drag parsing or hashing onto the UI thread
  (B7 area) — that audit is task P3.0.

Deliverable: `ADAPTIVE_IMPORT_DESIGN.md` (controller, bounds, telemetry,
failure transitions).

### 5.2 Storage tiers (`StoragePlanner`, new — B8)

| Mode | Active DB/FTS/WAL | Originals | 3.0 status |
|---|---|---|---|
| Mac internal | local Application Support (B9) | managed copy or bookmarked reference | ship |
| Local external APFS SSD | on the selected mounted volume after a validated safe move + bookmark + lock check | same volume or reference | ship |
| iCloud Overflow | **never** — hot DB/WAL/FTS stay local or on external SSD | immutable content-addressed segments uploaded, verified by hash, fetched on demand, bounded local cache | **prototype, feasibility-gated (P8)** |
| Insufficient everywhere | no speculative start | nothing moved or deleted | ship: show exact missing bytes + options |

Preflight must budget: source bytes, DB growth, WAL checkpoint, FTS, extracted
text, export temp, OS safety margin. Unplug-before-write detection and a resume
path are acceptance criteria, as is ENOSPC recovery. Network shares are refused
for the active store (no valid WAL locking).

Deliverable: `STORAGE_TIER_FEASIBILITY.md` (incl. the 250 GB Mac case).

---

## 6. Mail-client handoff (Apple Mail / Thunderbird)

B10/B11 mean this is real engineering, not a label change.

| ID | Work | Est. |
|---|---|---|
| H1 | **MBOXWriter hardening**: real `From_` envelope (sender + message date, not epoch), correct `>From` quoting on all line endings, full MIME emission from canonical records when `rawSource` is absent (**attachments must survive**), deterministic folder mapping, partitioned output for validated target sizes. | 6–9 d |
| H2 | **Round-trip harness**: source → canonical → MBOX → re-parse; compare by message identity, count, attachment identity and original hash where applicable. This is the gate on showing the feature at all. | 4–6 d |
| H3 | Import menu: `Import from Apple Mail…` / `Import from Thunderbird…` — **guided sheets** that explain `Mailbox > Export Mailbox` / a version-tested Thunderbird route, then a picker. No background scanning of either app's private store. | 4–6 d |
| H4 | Export menu: `Export to Apple Mail…` / `Export to Thunderbird…` — create + verify files, then show exact manual steps with the sentence "You will finish importing in Apple Mail/Thunderbird." Free-space preflight for **both** the output destination and the machine importing. | 4–6 d |
| H5 | Executed Apple Mail import test at a size the destination Mac can hold; count/attachment/folder diff recorded. Thunderbird route tested on the current version, documenting the ImportExportTools NG requirement and the 2 GB ZIP limit. | 3–4 d |

Hard rules: never write Apple Mail's or Thunderbird's private stores; no logos
or endorsement; no "one-click" wording; an export receipt is **not** proof of a
successful import.

Deliverable: `MAIL_CLIENT_HANDOFF_TESTS.md`.

---

## 7. Pages 2 and 3 (re-host + gate existing code)

### Page 2 — AI Insights (off by default)

| ID | Work | Est. |
|---|---|---|
| I1 | Page shell: scope bar (source + date) + Ask / Summaries / Reports tabs, hosting existing `AIAssistantView`, `AIDigest*`, `ReportBuilderView`. | 5–7 d |
| I2 | Registry gating: no model load, no embedding index, no FTS duplication, no scheduled digest, **no network** while disabled. `DigestScheduler` and `BackgroundAnalysisManager` move behind the registry (B13). | 4–6 d |
| I3 | Provenance surface: every answer shows on-device vs consented provider, coverage, and per-sentence citations that reopen the exact message (`AIGroundingGate`, `AIProvenance`, `CitationVerifier` already exist — wire to the new locator type). | 4–6 d |
| I4 | Opt-in embedding index inside the module, independently resumable; prompt-injection rule: imported text is never instruction. | 4–6 d |
| I5 | Cloud AI provider: `CloudAIProvider` (B5) returns to the build behind explicit per-request consent + org hard-off; it is the *only* AI network path. | 3–4 d |

### Page 3 — Professional Workflows (off by default)

| ID | Work | Est. |
|---|---|---|
| P1 | Page shell: Job catalog / Active work / Outputs tabs hosting `WorkCenterView`, `WorkflowRunnerView`, the five 2.1 studios, `DocumentRegistry`. | 5–7 d |
| P2 | **`WORKFLOW_INVENTORY.md`: 51 rows** (B12 — the "47" claim is stale), one per `WorkflowEngine.all` entry, with the directive's nine columns. Unverified rows are marked **Draft / Needs review**, never "certified". No invented forms, jurisdictions or designations. | 8–12 d (SME-bound) |
| P3 | Gating with evidence safety: legal holds and case data **survive module deactivation**; disabling never erases evidence or defeats a hold; no workflow catalog parsing, audit timer or case indexing on disabled launches. | 4–6 d |
| P4 | Outputs: production window (requested/included/excluded, attachment families, Bates sequence, hash manifest, signed-off version) reusing the new `ExportReceipt`. | 4–6 d |

---

## 8. Page 4 — Live Mail (off by default, new capability)

This is the largest new risk area: B5's connectors have never shipped, never
been compiled in Release, and have never been tested against current provider
policy. Inspection of them (2026-09-23) shows how unshipped they are:

| File | Actual state | 3.0 disposition |
|---|---|---|
| `GmailConnector.swift` | `clientID = "YOUR_GOOGLE_OAUTH_CLIENT_ID…"` placeholder — never registered. Scopes `gmail.readonly` + `gmail.labels` = Google **restricted** scopes (CASA security assessment). Read-only; cannot send. | **Park behind a flag; lands in 3.1** |
| `OutlookConnector.swift` | Real OAuth PKCE + Graph scaffolding, but `msClientID = "YOUR_AZURE_CLIENT_ID"` and scopes are `Mail.Read`/`Mail.ReadBasic`/`User.Read` — **no `Mail.Send`** | **Rewrite as Graph read + send** (needs only an Entra app registration) |
| `IMAPClient.swift` | Plaintext `IMAP LOGIN` only (:153); no XOAUTH2 | Becomes `MailTransportCore`; add XOAUTH2 + hardening |
| `SMTPClient.swift` | Same auth gap | Same |
| `ComposeEmailView.swift` / `IMAPConfigView.swift` | Unshipped UI, pre-dates the module registry | Rebuild against `AccountRegistry` + per-account `Outbox` |
| `iCloudSyncManager.swift` | Syncs forensic **metadata** (evidence tags, annotations, case info, knowledge graph, KV settings) to the ubiquity container — not the email store. Compiled out of every shipping build, and non-functional anyway because the app has no iCloud entitlement, so `url(forUbiquityContainerIdentifier:)` returns nil. Paywalled UI for a dead capability, and a second undisclosed iCloud path for exactly the most sensitive data | **Deleted 2026-09-23** (superseded by §9's consented segment design) |

**Provider staging — this is what keeps external approvals off 3.0's critical
path.** 3.0 ships generic IMAP/SMTP (so Gmail and iCloud users connect with an
app-specific password, needing no Google review) **plus** Microsoft Graph OAuth
for read *and* send. Gmail's own OAuth flow is filed in parallel and ships in
3.1. Result: a working multi-account Page 4 in 3.0 with no third-party approval
gating the release date, and no Gmail user excluded. Google and Microsoft policy
must be re-verified when P7 starts — app-password availability has been
tightening — and if generic IMAP for a provider turns out to be unusable, that
provider is simply not claimed.

| ID | Work | Detail | Est. |
|---|---|---|---|
| L0 | Flag rework + dead-code triage | `OFFLINE_MODE` → `NO_NETWORK_BUILD`, applied to the Enterprise Offline configuration only; consumer configuration compiles Live Mail in but leaves it registry-disabled. Execute the disposition table above in the same PR: delete `iCloudSyncManager.swift`, gate `GmailConnector.swift`, move IMAP/SMTP into `MailTransportCore`. | 3–5 d |
| L1 | **Disabled-baseline proof** | Automated test + instrumented run proving a fresh consumer install with Live Mail off makes **zero** connections, registers no timers/notifications, stores no tokens, runs no migration. Uses a `URLProtocol`/`NWConnection` trip-wire that fails the test suite on any attempt, plus a signed-binary check with Charles/`nettop` recorded in the matrix. | 5–7 d |
| L2 | Account model | `AccountRegistry` + per-account Keychain items (separate keys, never shared), account-scoped SQLite records keyed `(accountID, mailbox, serverID)`, distinct cursors/rate limits/outboxes. | 6–9 d |
| L3a | Auth, 3.0 providers | Generic IMAP+SMTP with server/port/TLS test and app-specific-password entry (clearly labeled as the provider's own app password, never presented as an OAuth screen) + XOAUTH2 support in `MailTransportCore`; Microsoft Graph via `ASWebAuthenticationSession` + PKCE with `Mail.ReadWrite` + `Mail.Send` + `offline_access`. | 8–12 d |
| L3b | Gmail OAuth | **3.1, not 3.0.** Google Cloud project + consent screen + restricted-scope verification/CASA; then native Gmail API paths. Built behind the L0 flag so it can be switched on without a structural change. | 5–8 d (+ external clock) |
| L4 | Receive | `MailSyncEngine`: headers-first, bodies/attachments on demand, per-account quota + total cache ceiling, fair scheduling, backoff, offline state; **never** bulk-download server history by default. | 12–18 d |
| L5 | Read/act | Account-badged detail, remote-content controls, mark/move/flag/delete acting **only** on the originating account, with confirmation for irreversible server operations and offline rollback/retry. | 6–9 d |
| L6 | Compose/send | `Composer` + per-account `Outbox`; From visible before editing and again at Send; reply defaults to the receiving account; persisted statuses Queued / Uploading / Accepted by provider / Failed / **Uncertain**; duplicate-send prevention on retry; alias validation. | 10–14 d |
| L7 | Archive bridge | Explicit "Copy to Archive" / "Reference" through `ArchiveImporting` only, preserving account/UID/original MIME, with a handoff receipt. No silent back-sync, no automatic upload of offline archives. | 5–7 d |
| L8 | Activation UX | Settings > Modules, plus intent interception on Send/Receive with the directive's exact sheet copy and Enable / Not now. Declining = no auth, no socket, no queued send. Paused accounts offer **Resume sync**, not a fake first-run permission prompt. Never impersonate a system permission alert. | 4–6 d |
| L9 | Multi-account matrix | Three accounts (two same provider + one different): combined Inbox with labeled origins, independent folder trees, scoped + unified search, separate token expiry, distinct drafts/outboxes, one account offline without breaking the others, removal without server deletion, reinstall identity/cache restoration, per-account cache pause. | 6–8 d |

Deliverables: `LIVE_MAIL_PROVIDER_MATRIX.md`,
`LIVE_MAIL_MULTI_ACCOUNT_TESTS.md`, `NETWORK_AND_PRIVACY_MATRIX.md`.

**External release gates (not engineering):** a Microsoft Entra app
registration (days, owner-only) and the App Store privacy-label + description
rewrite are the only ones on 3.0's path. Google restricted-scope verification
is deliberately moved off it by the staging above; file the Google application
at the start of P7 anyway, so 3.1 is not waiting on it.

---

## 9. iCloud Overflow (prototype, feasibility-gated)

Scope in 3.0 = an honest answer plus a bounded prototype, **not** a promise.

1. Decide iCloud Documents vs CloudKit assets by measurement (API surface,
   quota reporting, eviction control, conflict semantics). Record the chosen
   container id.
2. Prototype: segmented immutable content-addressed blobs + local manifest +
   bounded cache + on-demand fetch. Hot SQLite/WAL/FTS never leave local or
   external SSD.
3. Prove: upload + remote hash verification **before** any local copy is
   dropped; eviction, quota exhaustion, network loss, offline read-only
   operation with receipts, device sync behavior, single-writer rule.
4. 250 GB-Mac test with a 1 TB corpus, reporting exactly how much local disk the
   catalog + fitted FTS require. If catalog/FTS cannot fit, the app must require
   external storage or offer **explicitly limited** search — never a false
   full-search promise.
5. Publish the SQLite-on-iCloud answer verbatim in the feasibility doc (a
   materialized iCloud file is just a local file; this is not cloud-side SQL and
   does not solve 1 TB on a 250 GB Mac); also verify `PRAGMA page_size`,
   `max_page_count`, `journal_mode` and the active file path on a Release build,
   and correct the "267 TB" figure wherever it appears.

**Gate:** if steps 2–4 do not pass, 3.0 ships **without** the iCloud
entitlement and the feature is reported as NOT FEASIBLE YET. Basic Archive
release is never blocked on this.

---

## 10. Phases, order and exit criteria

| Phase | Content | Exit criterion |
|---|---|---|
| **P0 — Audit & baseline** (3–5 d) | Re-verify §1 on the 2.1 tag; measure cold launch, idle RSS, storage use, migration timings; inventory the 69 singletons and every launch-time job; capture current UI paths. | `RELEASE_READINESS.md` opens with measured 2.1 baselines; no work starts from assumption |
| **P1 — ArchiveCore + registry** (15–20 d) | Extract the package (§3.1); build `ModuleRegistry`/`JobRegistry`/Settings > Modules; default AI/Professional/Live Mail **off** on fresh install while mapping existing users' state and purchases; kill eager singletons on the disabled paths. | **§3.3 R1–R5 all satisfied with measured numbers** — the all-off baseline column and one column per module in `MODULE_ACTIVATION_MATRIX.md`; CI lint blocks boundary violations; the six §P0.1 launch offenders are gated; existing 2.x libraries open unchanged |
| **P2 — Page 1** (25–35 d) | A1–A8. | `PAGE_WINDOW_MATRIX.md` Page 1 complete; receipts reconcile; partial index cannot report a bare zero |
| **P3 — Adaptive import + storage** (18–25 d) | P3.0 main-actor audit, `AdaptiveBatchController`, backpressure, `StoragePlanner`, external SSD tier, force-quit/ENOSPC/eject recovery. | 10K/100K/1M regressions green; force-quit at every boundary reconciles; UI stays responsive during import+search+export on a documented Mac |
| **P4 — Handoff** (15–22 d) | H1–H5. | Executed PST → canonical → MBOX → **real Apple Mail import** with counts and attachments reconciled; feature hidden until H2 passes |
| **P5 — Page 2** (18–24 d) | I1–I5. | Citation-reopen test passes; disabled-module resource proof holds; no unsupported completeness claim from a partial import |
| **P6 — Page 3** (20–30 d) | P1–P4, 51-row inventory. | Every row filled or marked Draft; holds survive deactivation; outputs reopen with exact lineage |
| **P7 — Page 4 Live Mail** (50–70 d) | L0–L9 minus L3b; Google application filed on day 1 anyway, for 3.1. | Three-account matrix green (two generic IMAP + one Graph, per the staging); wrong-account send impossible; disabled-baseline proof recorded; only verified providers named in the UI and store copy |
| **P8 — iCloud Overflow** (15–25 d, parallel) | §9. | Feasibility verdict with measurements; entitlement ships only on PASS |
| **P9 — Scale & format matrix** (20–30 d, hardware-bound) | Format variants; 200 GB PST + 200 GB MBOX + 100 GB Apple Mail; mixed 1 TB; single-source 1 TB where the format permits; low-disk; external disconnect; iCloud quota/eviction/loss; memory pressure; force quit; cold reopen; export to real clients. State decimal TB vs TiB explicitly. | `SCALE_RESULTS.md` with exact fixture + host per row and **NOT TESTED** wherever corpus/hardware is missing; zero extrapolation presented as proof |
| **P10 — Release readiness** (10–15 d) | Debug+Release builds both platforms, full test suite, macOS UI smoke, genuine v1/v2 customer-library migration, store description/screenshot audit against measured results, privacy labels, whitepaper + privacy policy rewrite. | `RELEASE_READINESS.md` separates engineering-complete from owner/Apple gates |

Rough total: **210–300 engineering-days** of sequential-equivalent work, with
P8 and much of P9 parallelizable. P7 alone is ~25% of it — that is the cost of
the "all four pages in 3.0" decision, and its external verification clock runs
independently of engineering.

Suggested branch/PR shape: one PR per phase-section (P1 split into
package-extraction / registry / default-off-migration), each with its own
behavioral check added to CI.

---

## 11. Claims, privacy and disclosure changes forced by 3.0

| Existing claim | 3.0 reality | Action |
|---|---|---|
| "Fully offline / no network" (store copy, `SECURITY_WHITEPAPER.md`, `PrivacyPolicy.html`) | Consumer binary gains `network.client`; nothing connects until a module is enabled | Reword to "no network activity by default; Live Mail and Cloud AI are opt-in modules", and point to the Enterprise Offline SKU for a provably network-free binary |
| "PST up to 50 GB / NSF up to 64 GB" (B14) | Unchanged until P9 raises them with executed evidence | Keep as-is; 200 GB claims require parser work **and** executed tests |
| "1M emails verified" (B15) | Still the largest executed run | Keep, with its 4.7 GB / 582 MB context; no 500 GB or 1 TB claim until P9 |
| "47 workflows" | 51 definitions exist (B12), verification varies | Claim only inventoried rows; Draft rows are not marketed |
| Apple Mail / Thunderbird compatibility | No handoff feature exists (B11) | No claim until H2 + H5 pass; then descriptive wording only, no endorsement |
| iCloud / storage limits ("267 TB") | Not an observed quota or mailin limit | Remove; replace with measured tier guidance from §5.2/§9 |

Deliverable: `NETWORK_AND_PRIVACY_MATRIX.md` (exact entitlements, every cloud
and provider flow, data disclosed, consent copy, and the proof of zero network
activity while disabled) + `SUPPORTED_FORMATS_AND_LIMITS.md`.

---

## 12. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Gmail restricted-scope verification denied or slow | Gmail's native API path slips past 3.0 | Already mitigated by the §8 staging: 3.0 reaches Gmail over generic IMAP/SMTP with an app-specific password, so the release never waits on Google. Residual risk is Google removing app passwords — re-verify at P7 start; if that happens, Gmail is not claimed until L3b lands |
| Provider policy drifts between planning and P7 | A staged provider becomes unusable | Re-verify Google/Microsoft/Apple policy at P7 start as a checklist item in `LIVE_MAIL_PROVIDER_MATRIX.md`; the matrix, not this plan, is the shippable claim |
| Adding `network.client` weakens the privacy story | Market/positioning damage | Keep the Enterprise Offline configuration with no network entitlement (§2); make disabled-state proof a public artifact |
| ArchiveCore extraction destabilizes a 133k-LOC target | Schedule slip, regressions | Extract in three mechanical PRs (model → store/parsers → import/export), each with the full test suite + a 2.x library migration smoke; no behavior changes inside the extraction PRs |
| Synchronized groups (B2) make "not linked" impossible | Disabled modules still initialize | Registry + factory closures + eager-singleton removal + automated no-jobs/no-sockets assertions (P1, L1) |
| Force-quit during import corrupts checkpoints | Silent data loss — the worst failure mode | Checkpoint only after durable store commit; FTS reconciles separately; force-quit test at every boundary in P3 |
| 1 TB corpora and a 250 GB test Mac may not exist | P9 rows unverifiable | Mark **NOT TESTED** and withhold the matching claim; consider synthetic corpus generation + a rented/borrowed machine, recorded as such |
| Live Mail wrong-account send | User-visible, irreversible | Bind draft + credentials + send + Sent-mapping to one account ID; From shown twice; L9 acceptance test |
| iCloud Overflow proves infeasible | Feature cut late | §9 gate is explicit and does not block release; report honestly |
| Two big changes at once (restructure + Live Mail) | Review + regression risk | Phase order: ship-quality Pages 1–3 land and are frozen before P7's networking merges; 3.0 can still be cut without Page 4 if L1 or verification fails |

---

## 13. Deliverable documents (directive §8)

Created/updated during 3.0, each with executed evidence or an explicit NOT
TESTED marker:

- [ ] `PAGE_WINDOW_MATRIX.md` — all four pages, controls, states
- [ ] `MODULE_ACTIVATION_MATRIX.md` — disabled-resource + disabled-network measurements, migrations
- [ ] `SUPPORTED_FORMATS_AND_LIMITS.md` — supersedes `V2_FORMAT_MATRIX.md`
- [ ] `WORKFLOW_INVENTORY.md` — **51 rows**
- [ ] `ADAPTIVE_IMPORT_DESIGN.md`
- [ ] `STORAGE_TIER_FEASIBILITY.md`
- [ ] `IMPORT_RECEIPT_SPEC.md`
- [ ] `SCALE_RESULTS.md` — supersedes `V2_SCALE_RESULTS.md`
- [ ] `MAIL_CLIENT_HANDOFF_TESTS.md`
- [ ] `LIVE_MAIL_PROVIDER_MATRIX.md`
- [ ] `LIVE_MAIL_MULTI_ACCOUNT_TESTS.md`
- [ ] `NETWORK_AND_PRIVACY_MATRIX.md`
- [ ] `RELEASE_READINESS.md` — engineering-complete vs owner/Apple gates

---

## 14. Open items for the owner

1. **iCloud container identifier** and the Documents-vs-CloudKit choice (blocks P8 setup).
2. **Microsoft Entra app registration** (Application/client ID + redirect
   `msauth.com.ecosanskriti.mailin://auth`) — the one external item 3.0's Page 4
   needs. Separately: Google Cloud project + consent screen ownership and
   whether a restricted-scope/CASA budget exists — that decides 3.1's L3b, not
   3.0.
3. **Test hardware and corpora**: is a 250 GB Mac + ~1 TB of real mixed source
   data available? If not, P9 rows ship as NOT TESTED.
4. **Enterprise Offline SKU** confirmation (bundle id, price) — it is the
   mitigation for the privacy-claim change, so it should ship with 3.0.
5. Whether Page 4 may be cut from 3.0 late (if L1's zero-network proof fails)
   or the release waits — decides whether P7 merges to `main` or to a feature
   branch. Recommendation: feature branch, so Pages 1–3 can ship as 3.0 on
   their own schedule.

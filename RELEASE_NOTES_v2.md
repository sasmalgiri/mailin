# mailin v2.0.0 — Release Notes

**Status:** ready to ship · awaiting marketing-version + bundle-display-name
flip in Xcode (see `SHIP_v2_CHECKLIST.md`)

mailin v2 is a foundation rewrite of the storage, ingest, and indexing
layers under the same UI, with a new opt-in live-mail surface gated by a
build flag. v2 keeps the v1 user data intact — same Application Support
location, same Keychain service, same SwiftData store, same FTS5 index
files. Existing v1 users get an in-place upgrade.

---

## Headline changes

### 1. Streaming ingest with crash-resume
Re-built from the ground up. The old "parse whole archive into RAM, then
persist" pipeline is gone.

- `BulkImportCoordinator` now drains parsed messages in batches of 200
  through the new `MBOXParser.parseStreamingCallback`. Peak memory is
  bounded by batch size, not by source file size.
- Per-file SHA-256 + per-batch `ImportCheckpointStore` checkpoints.
  An import that crashes at 800 GB resumes from the last batch — not
  from the start of the file.
- Empty files still get a checkpoint so a re-drop doesn't re-hash them.
- PST and NSF parsers now use `Data(contentsOf:options: .mappedIfSafe)`.
  Multi-GB PST files no longer materialise in RAM. Caps raised:
  PST/OST to 50 GB, NSF to 64 GB.

### 2. Year-sharded FTS5 search
`FTSSearchIndex` is now a router. The monolithic `fts5_search.db` is
replaced by per-year shards under
`~/Library/Application Support/com.ecosanskriti.mailin/fts5/`
(`email_search_2024.db`, etc.).

- Time-bounded queries hit one shard; cross-archive queries fan out and
  merge by bm25 rank.
- Open SQLite handles are bounded to 20 with proactive LRU eviction,
  additionally driven by macOS / iOS memory-pressure signals.
- Public API unchanged — `indexBatch`, `search`, `clear`, `rowCount`
  callers (BulkImportCoordinator, IMAPSyncManager, ContentViewModel,
  MaxmailinSelfTest) work without modification.
- Legacy single-file `fts5_search.db` is migrated once into the
  unknown-year shard slot. No rebuild required.

### 3. Keyset pagination
`EmailStore.pageKeyset(beforeDate:beforeID:limit:)` lands and
`PaginatedEmailViewModel` adopts it. Deep pagination (email #1,000,000
in a multi-million-message archive) is O(log n) instead of O(n).
Composite cursor `(date, id)` ensures pagination is stable even when
multiple emails share a timestamp.

### 4. Robustness fixes from live-test logs
Bugs that surfaced when the v2 build was test-driven on macOS were
hunted from the unified log and fixed in this version:

- SwiftUI **multi-sheet conflict** at launch — Terms acceptance,
  Persona onboarding, and Getting Started no longer race for the same
  sheet slot. Single `.sheet(item:)` enum routes the launch gate;
  Getting Started defers until the gate completes.
- **Keychain on main thread** — `MailAccountStore` legacy migration
  no longer blocks the main actor on `SecItemCopyMatching`. Background
  task reads the legacy entries, then hops back to MainActor to apply.
- **FoundationModels 4096-token overflow** — `FoundationModelEngine`
  now caps prompt input at 12,000 chars with a clear truncation
  suffix. Eliminates the
  `Context length of 4096 was exceeded during singleExtend` failures.

### 5. Edge-case hardening
Round-trip audit fixes that don't show up in live testing but bite at
scale:

- `pageKeyset` uses a `(date, id)` composite cursor so date-ties at
  page boundaries don't skip or duplicate rows.
- `uidFetchSince` guards against `UInt64.max` overflow on the
  increment.
- `IMAPSyncManager` falls back to UIDVALIDITY=0 when the server
  doesn't advertise it (older Dovecot, some appliances) — never fails
  hard, just re-baselines every pass.
- `BulkImportCoordinator` clamps `batchSize` to `[1, 10_000]`.
- `FTSSearchIndex.year(for:)` clamps non-positive and far-future years
  to the unknown-year shard so we don't produce `email_search_-2.db`.

---

## What did NOT change

- v1 data layout. Same `~/Library/Application Support/com.ecosanskriti.mailin/`
  directory; same SwiftData store; same Keychain service
  `com.ecosanskriti.mailin`.
- The forensic suite — ChainOfCustody, Bates, GDPR, audit log, signed
  exports, EncryptedStorage, InvestigationReport, Duplicate, Entity —
  shipped in v1 and continues unchanged.
- The persona-driven UI: same Home, same persona filters, same toolbar,
  same export pipeline.
- AI / NLP: same Hybrid AI consent flow (Apple Intelligence + NL +
  optional cloud) — Cloud AI still defaults to off and requires
  explicit consent.
- Privacy policy claims: no telemetry, no analytics, no third-party
  SDKs. Network surfaces still require user-supplied credentials.

---

## Privacy posture — permanently offline by design

mailin v2 is **strictly offline**, exactly like v1. The product's
defining promise is that your archive never leaves the device. v2.0
ships with `OFFLINE_MODE` enabled on every build configuration; the
shipped binary contains no IMAP, no SMTP, no JMAP, no Gmail API, no
Microsoft Graph code. Live mail send and receive will never be added
to mailin — that's a deliberate product choice, not a roadmap item.

Network usage in v2.0:
- **None for mail.** The app never contacts an email server.
- **Cloud AI is opt-in, off by default.** As in v1, users may
  enable analysis via OpenAI or Anthropic with their own API key. No
  cloud AI activity occurs without explicit per-feature consent.
- **App Store / StoreKit** for in-app purchase verification.

If you're a power user who wants live mail with the same engine
foundation, look at the separate `maxmailin` developer-preview repo,
which is a different product with a different privacy story.

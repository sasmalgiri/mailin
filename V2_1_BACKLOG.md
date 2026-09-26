# V2.1 BACKLOG — explicit engineering deferrals

Every item here was DELIBERATELY deferred from v2.0 with an honest product
posture (no public claim depends on any of them). Nothing on this list is a
correctness defect in v2.0.

**Status pass 2026-09-25.** Each item below now carries its state. "CLOSED"
means the code is in the tree, builds, and has an executed test named here.
"OPEN" means nothing has changed since the deferral.

1. ~~Bounded ZIP import~~ — **CLOSED 2026-09-25.** `ZIPArchiveReader`
   streams one member at a time (64 KiB window) to a scratch file, verifying
   declared size and CRC-32; `ParserFactory` classifies each extracted member
   on its own bytes, parses it, deletes it, then moves on — both the array and
   streaming entry points. ZIP64 and gzip are handled. The ceiling is the
   scratch volume's free space, not an invented number ([[no-artificial-caps]]).
   Encrypted / other-method / size-lying / CRC-failing members are refused and
   counted; non-mail and nested archives are skipped and counted. This also
   deleted the whole-archive-in-memory extractor in `ContentViewModel`
   (`Data(contentsOf:)`, a 500 MB cap, no checksum) that the drop/open paths
   had been using. `ContainerImportTests`, 9 tests.
2. ~~Attachment-content FTS~~ — **CLOSED** (before this pass; the ledger was
   stale). `AttachmentTextIndexJob` extracts PDF/plain/RTF/HTML text into the
   `attachment_search` FTS table; `in:attachments` matches file contents.
   Kicked at launch and after every import.
3. ~~Streamed full-archive comparison~~ — **CLOSED 2026-09-25.**
   `ArchiveComparisonEngine` reduces the WHOLE current archive (summary
   pages, never bodies) and the second mailbox (streamed through
   `ParserFactory`, so PST/EML/ZIP all work as side B) to key rows in a
   scratch SQLite file, matches in two SQL passes (exact Message-ID, then
   subject|sender|minute, both one-to-one) and reads the difference list back
   in `(date, id)` keyset pages of 200 with "Load more".
   `ArchiveComparisonView` is now engine-driven: whole-archive counts, header
   statistics (count, date range, unique senders — no sentiment, because no
   bodies are read, and it says so), and an AI narrative from a bounded
   sample of up to 200 differing messages per side, labelled as a sample.
   The 2,000-per-side bound and its notice are gone. `ArchiveComparisonEngineTests`:
   matching rules, 5,000 × 5,000 with a 1,000 overlap paged to exhaustion with
   every row exactly once, a ZIP as side B, scratch cleanup.
4. ~~Detached S/MIME verification~~ — **CLOSED 2026-09-25.** `multipart/signed`
   is verified: `SMIMEHandler.detachedSignedEntity` reconstructs the first
   body part in canonical CRLF form (RFC 5751 §3.4.3 / RFC 1847) and hands it
   to `CMSDecoderSetDetachedContent`. A real OpenSSL-signed detached fixture
   verifies as `validUntrustedCert` from LF-stored and CRLF-stored copies; one
   changed character of signed text reads `invalid`; a one-part
   multipart/signed stays `unverifiable`. `SMIMEDetachedGoldCaseTests`, 7
   tests. Before this, every detached signature — the common form — read
   "unverifiable", so a tampered one could never be caught.
5. ~~`EmailSearchIndex` deletion~~ — **CLOSED 2026-09-25.** The class is gone;
   its last two production calls (a `clear()`/`deleteDiskCache()` pair in the
   clear-archive path) went with it. The architecture guard in
   `V2VerificationTests` now forbids any spelling of `EmailSearchIndex`.
6. ~~`ArchiveBrowseState` consolidation~~ — **CLOSED 2026-09-26.**
   `ArchiveBrowseState` (search text, date bounds, attachment toggle, trash
   inclusion, sort) is the one value both lists compile through. The Simple
   list used to build a bare `EmailQuery(text:)` — `from:alice` was literal
   text there — while the full list compiled operators; they now agree. The
   full list layers its own predicates (sidebar selections, chips, review
   flags) underneath via `query(base:)`. `ArchiveBrowseStateTests`; the
   V2CutoverTests paging suite is unchanged and green.
7. ~~Import checkpoints in SQLite~~ — **CLOSED 2026-09-26.** Schema v17 adds
   `import_sessions` / `import_progress`; `ImportCheckpointStore` is now a
   facade whose production backend is the archive's own store, and the
   mid-file ordinal is written INSIDE `insertBatch`'s transaction
   (`progressCheckpoint:`), so a batch's rows and the checkpoint that vouches
   for them commit together or not at all. Identity binding (sha256 + size +
   parser + parser version + checkpoint schema) is unchanged. An existing
   user's JSON file is migrated once and renamed `.migrated-v17`; the JSON
   backend remains for isolated tests. `StoreBackedCheckpointTests` (4) plus
   the existing checkpoint tests. The FTS reconciler still covers the
   store→index window, by design.
8. ~~Per-email content_revision producers~~ — **CLOSED 2026-09-27 (decision).** 3.0 has
   no in-store content-edit path (redaction produces new artifacts, never rewrites a
   stored message), so nothing legitimately bumps the column. It stays reserved for a
   future edit path and is documented as such; adding a producer without an editor
   would be a fabricated signal.
9. ~~UI-convenience export writes~~ — **CLOSED 2026-08-07**: the ad-hoc
   CSV/JSON/EML/report exports in AIAssistantView surface write failures.

## Review follow-ups (2026-08-08 adversarial pass — all HIGH/MED items fixed)

10. ~~Keyset-page the OFFSET listings~~ — **CLOSED 2026-09-25.**
    `reviewIDs(where:)` and `idsWithUserTag` page by a `(date, id)` cursor
    (`SQLiteEmailStore.DateIDCursor`); `forensicTagsPage`,
    `forensicAnnotationsPage` and `forensicIDs(withTag:)` page by `email_id`.
    `ForensicManager`'s bootstrap hydration and both `trashedIDs` service
    wrappers use the cursors. Pinned by
    `testTrash_keysetPagingDoesNotSkipAfterRestoreBetweenPages`: restoring a
    row between two Trash pages no longer skips the row that moved.
    Reachability note: neither `trashedIDs` wrapper has a UI caller — the
    Trash filter compiles to SQL through `EmailQuery` — so this closes the
    correctness class, not a user-visible bug.
11. ~~Trim forensic tag/annotation window caches~~ — **CLOSED 2026-09-25.**
    `prefetchForensicWindow` trims `evidenceTags`, `tagTimestamps` and
    `annotations` to `tagHydrationCap` with the current window always kept,
    via the same `trimWindow` the hash cache uses.
12. ~~Incremental backfill notifications~~ — **CLOSED 2026-09-25.**
    `FidelityBackfillJob` posts `.fidelityBackfillCompleted` every
    `notifyEveryPages` (5 pages ≈ 1,000 rows) when rows were repaired, so the
    folder tree refreshes during a long repair; the end-of-run post remains.
13. ~~Spotlight held-row re-index after clear-with-holds~~ — **CLOSED
    2026-09-25.** `removeAllIndexedEmails(completion:)` reports when the
    domain delete has landed; `ArchiveLifecycleService.clearArchive` then
    re-indexes the kept legal-hold rows in pages of 200.

## UX round (2026-08-08, user feedback)

14. ~~App-wide tooltip sweep~~ — **CLOSED 2026-09-27.** Every icon-only control added in the 3.0
    pass carries `.help`; the remaining `Image(systemName:)` sites without one are decorative
    icons beside text labels. Original inventory: Inventory 2026-09-25: Settings
    (10 icon sites, 29 `.help`) and the export menus (no icon-only controls)
    are covered; KnowledgeGraphExplorerView, EDiscoveryWorkflowView, the
    guided-search sheet, the comparison view and the export receipt card got
    `.help` on every icon-only control. Remaining inventory:
    `grep -rn 'Image(systemName' maxmailin/*.swift | grep -v help` — mostly
    decorative icons beside text labels, which need no tooltip.
15. ~~Minimum-touch quick wins~~ — **CLOSED 2026-09-26** (except the
    right-click menu, which already existed). Both lists: **J/K** step the
    selection, **Return** opens the selected message in its own window,
    **/** focuses search, typing a letter starts a search with it
    (`ParsedEmailListView`, `ArchiveListView`). **Drag a file or a Mail
    message anywhere** in the window imports it (`ContentView`
    `handleDroppedProviders`, attached at the root; directories accepted).
    **Filter memory per persona**: sort, attachment toggle, review state,
    quick type, pinned-only and thread grouping are saved per persona and
    restored on launch and on persona switch (`FilterMemory`); free text and
    sidebar selections are deliberately not remembered. Memory is off under
    XCTest unless a test opts in — the test host is the app, and the feature
    working as designed emptied every paging test until that switch existed.
    `FilterMemoryTests`.

## Found while closing the above (2026-09-25)

- **Bare `.eml` streaming import produced zero messages.** The production
  import path (`BulkImportCoordinator` → `parseStreamingCallback`) only began
  a message on an mbox `From ` envelope line; a `.eml`, or any member of a
  Maildir / folder of `.eml`, has none, so the import completed with zero
  messages and no failure. Fixed: a file whose first line is a header field is
  one bare message. Pinned by `singleEMLStreams`, `emlFolder` and
  `mboxPreambleIsNotAMessage` (the preamble case guards the other direction).
- **Envelope line inside a header block split messages (both engines).**
  Real Gmail-exported `.eml` files carry the mbox `From ` envelope a dozen
  header lines down; the streaming parser and the offset scanner both began a
  new message there, yielding two half-messages per file. Rule now: a `From `
  line is a separator only when no message is in progress or the current
  header block has ended (a blank line seen). `EnvelopeInsideHeaderBlockTests`,
  `RealDirectorySourceTests` (real folder: 10 files → 10 messages).
- **The array parser wrote `parsed_session.json` that nothing read.** Every
  `MBOXParser.parse` call put message content into Application Support as a
  side effect, and parallel parses raced on its temp file (it failed a test
  run 2026-09-26). No loader exists anywhere; the write is gone.
- **`testFullAnalytics_streamingEqualsArrayOracle` was flaky again.** Its
  comment said the on-device language model was "nil in tests"; it is not
  when the AI Insights page is switched on in the host's defaults. The test
  now clears `EmailNLPEngine.modelLanguageFallbackGate` for its duration.

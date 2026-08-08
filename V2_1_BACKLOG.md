# V2.1 BACKLOG — explicit engineering deferrals

Every item here was DELIBERATELY deferred from v2.0 with an honest product
posture (no public claim depends on any of them). Nothing on this list is a
correctness defect in v2.0.

1. **Bounded ZIP import** — ZIP archives are explicitly rejected with
   guidance today (§7.6). v2.1: streamed member extraction with a size
   ceiling, routed through ParserFactory per member.
2. **Attachment-content FTS** — attachment text is not indexed; the UI says
   so (`in:attachments` matches filenames only). v2.1: persisted extracted
   attachment text + dedicated FTS table.
3. **Streamed full-archive comparison** — ArchiveComparisonView compares
   explicitly bounded working sets (≤2,000/side, truncation surfaced).
   v2.1: key-walk comparison (message-id/hash digests) over both archives
   with paged difference lists.
4. **Detached S/MIME verification** — detached `multipart/signed` returns
   `.unverifiable` honestly (opaque signatures fully verified). v2.1:
   exact signed-entity byte reconstruction + CMS detached verify.
5. **`EmailSearchIndex` file deletion** — structurally bounded (5k ceiling),
   never constructed in production; ~10 files still reference its test-only
   helpers (`chunkSearch`, `expandByThread`). v2.1: delete the class and its
   remaining test-only call sites in one sweep.
6. **`ArchiveBrowseState` consolidation** — Simple + Advanced list VMs both
   sit on the repository; merging their filter state into one type is a
   refactoring nicety (see V2_UI_PARITY_MATRIX.md §28 note).
7. **Import checkpoints in SQLite** — checkpoints live in versioned,
   identity-bound JSON with THROWING persistence (fail-stop, tested).
   v2.1: move to `import_sessions`/`import_progress` tables so batch state
   and stored→indexed recovery share the store's transaction (§5.4's
   stronger variant; today's FTSReconciler backfill covers the crash window).
8. **Per-email content_revision producers** — the schema column exists
   (v2); no in-store content-edit path exists yet, so nothing bumps it.
   Wire it when in-place redaction/edit ships.
9. ~~UI-convenience export writes~~ — **CLOSED 2026-08-07**: the ad-hoc
   CSV/JSON/EML/report exports in AIAssistantView now surface write
   failures (toast/alert, partial-failure counts). Remaining `try?` sites
   are internal caches (conversation cache, metrics) — non-authoritative.

## Review follow-ups (2026-08-08 adversarial pass — all HIGH/MED items fixed; these lows remain)

10. **Keyset-page the OFFSET listings** — `reviewIDs`/`idsWithUserTag`/
    `forensicTagsPage` use LIMIT/OFFSET; concurrent restore/delete between
    pages can skip/repeat rows in the Trash listing.
11. **Trim forensic tag/annotation window caches** — `prefetchForensicWindow`
    trims only the hash cache; tags/annotations grow for the session in
    heavily-tagged archives (bounded by human tagging volume).
12. **Incremental backfill notifications** — one `.fidelityBackfillCompleted`
    per run; long repairs could refresh the folder tree every N pages.
13. **Spotlight held-row re-index after clear-with-holds** — the canonical
    clear de-indexes everything including kept legal-hold rows (they reindex
    on next launch pass).

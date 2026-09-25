# Reachability audit — 19 defects a green test suite did not catch

Status: all 19 addressed and committed. 494 tests pass, 0 fail, 1 skipped by
design. Two files are quarantined pending deletion (see the end).

## Why this document exists

The suite was green. The build was clean. Every one of these fifteen defects
was live at that point, and they all have the **same shape**:

> The code does something defensible. A comment, a UI string, or a doc claims
> something stronger. The tests check the behaviour that exists, so they pass.

Tests written against a function verify that the function works. They say
nothing about whether anything calls it. Fourteen of these fifteen were found
by asking one question of every surface — **"who actually calls this?"** — and
the fifteenth by asking it of my own code from the same week.

## The method

```sh
# For every declared function: does any production call site exist?
# Pattern must allow a leading '.', or it only finds free functions.
grep -rhoE "\b$name\s*\(" maxmailin/*.swift | wc -l   # vs. declaration count
```

Three traps in the method itself, all hit here:

1. **A pattern excluding a leading `.` finds nothing.** `[^a-zA-Z0-9_.]name\(`
   skips every method call on a receiver. It reported `dedupeShards` as dead
   when it is called at launch.
2. **Requiring a test caller hides the worst cases.** Filtering to functions
   that at least one test calls omitted `unarchiveEmail` — no caller, no test,
   and the UI promising it worked. The most dangerous dead code has no tests
   either.
3. **A call-pattern grep cannot see a function used as a value.**
   `onCompletion: handleArchiveImportResult` has no parentheses, so
   `\bname\s*\(` misses it. Confirm every candidate with a bare-name grep
   before acting: a function at exactly one bare occurrence is its own
   declaration and nothing else.

### Audit the type, not just the function

The two largest findings came from widening the unit. For each top-level type,
is it referenced in any file other than the one declaring it?

```sh
grep -rlw "$TypeName" maxmailin/*.swift | grep -v "^$declaringFile$"
```

Expect heavy noise — nested view types, `@Generable` model types, AppIntents
registered by the system, unused design-system modifiers. The signal is a type
that represents a whole *feature*, because its consumer should by definition be
elsewhere. That is how an entire enterprise deliverable (E3/E4) and two
quarantined files turned up after twelve function-level rounds had finished.

Noise to expect: SwiftUI protocol conformances (`makeNSView`, `placeSubviews`,
`makeBody`), unused design-system modifiers, and Page 4 / live-mail, which does
not ship. Signal: anything a UI string, doc comment, or checklist promises.

## The fifteen

| # | Claim | Reality | Fix |
|---|---|---|---|
| 1 | `LocatorReader` documented that it verified its source | Verified nothing | `verifySource(_:)` does a real full-file hash; `read`/`stream` documented as cheap and bounds-checked only |
| 2 | Both parsers shared a resume identity | They disagree on ordinals, so a resume could reorder | Identity carries `(parser, parserVersion)` |
| 3 | A header-only import reported **Complete** | Bodies were never decoded | `ImportShortfall.bodiesNotDecoded`; verdict is Partial |
| 4 | Queue showed "pending, running and finished" | `enqueue` was the only call; every import sat at Waiting forever | `markRunning` from `onFileProgress`, terminal states from `finishImport`, using the receipt's own verdict |
| 5 | "mailin will use the new location" | `productionDirectory` was hardcoded | Honoured, but only when the default path holds no `emails.db` — that condition is the feature's whole safety |
| 6 | Thunderbird import went through the import funnel | It bypassed guided import | Routed through `handleMultipleFiles`; invariant written into `parseSelectedFiles` |
| 7 | Orphan blobs were collected | `collectBlobOrphans`' only caller was a test; bytes leaked forever | Called at the end of every import, after the receipt persists |
| 8 | — | `deferredBodyCount`/`deferredBodyIDs` were dead; an archive could hold unsearchable messages with no way to find out | Storage screen reports the count |
| 9 | LAW-14: "a production/export can be blocked until the output is actually clean… a second pair of eyes" | Never called. `exportRedacted()` wrote the file whatever the rules missed | Validates every item and refuses to write, naming the surviving terms |
| 10 | — | `personRedactionRules`/`redactPerson` unreachable from the UI — the generator V3-D1 was a bug *in* | "Redact a Person" section; preview, export and log share one rule set |
| 11 | "restorable from the Trash view", "Trash is always restorable", "find it again with the Archived filter" | No Trash view, no Archived filter, and all three restore APIs uncalled. Trashing hid a message forever | `ReviewStateFilter`, always-visible Trash/Archived chips, per-row restore, `in:trash` restore in the SQLite surface |
| 12 | Legal hold seals the message; "Evidence Seal BROKEN" is logged on tamper | `verifyEvidenceSeal` was never called. Seals were written and never checked | "Verify Seals (n)" with per-row verdicts; the break is logged by the verifier itself |
| 13 | `blockedCapabilities()`: "surfaced in the matrix so a row is never mysteriously inert" | No caller | Banner naming each dependency-blocked capability and its cause |
| 14 | eDiscovery checklist: "Verify source file integrity" | `verifySourceFile` had no caller, so the instruction had no button | Settings ▸ Source File Integrity ▸ "Check a Source File Against Its Hash…" |
| 15 | — | `generateConcordanceLoadFile` was dead **and malformed**: U+0014 as both delimiter and qualifier, and missing BCC / SHA-256 / custodian / tag | Removed, with the reason recorded; format pinned by tests |
| 16 | E3 sealed case bundles + E4 team merge, recorded as shipped | The **whole of `CaseBundleService`** had no caller and no test. Neither could be reached from the app, and neither had ever been executed | Forensic Export ▸ Team handoff; 7 tests, which the implementation passed unchanged |
| 17 | Merge "skips identical artifacts" | Re-importing one bundle duplicated everything in it: the add path retitled an artifact, so the next pass compared the retitled local copy against the unlabelled incoming one. Three imports left four copies | Merged ids derived from (origin, sender); a genuine revision is still kept alongside |
| 18 | "Encrypted at-rest storage for sensitive email archive data" | `EncryptedStorageManager` has no caller, and keeps only the **first 2,000 characters** of raw source, restoring the truncation as if it were the original. ~1% of a real message, and every recomputed hash differs | Quarantined with a blunt header + 3 tests; recommend deletion |
| 19 | `PSTStreamingParser` protects against >2 GB PSTs "crashing on memory exhaustion" | No caller, and the premise expired at S1 — `PSTParser` mmaps, so only a correctness refusal remains. Its >2 GB branch throws `notYetSupported` for files that import today, so wiring it up would be a **regression** | Quarantined with the reason; covered by the same guard test |

Defects 15, 18 and 19 share the lesson worth remembering: **dead code is not
neutral.** Each carried the most authoritative name in its area — more obvious
than the path that actually ships — so the next person to need a load file, an
encrypted archive, or large-PST streaming would have found the broken one
first. Two of the three would have destroyed evidence if wired up.

## What the tests now cover

Every fix is pinned by a behavioural test, and where a fix could fail in both
directions, both are tested: the redaction gate has a pass-path test *and* a
block test, because falsely blocking a clean export is as much a defect as
leaking a name.

Three tests exist specifically to fail if a fix regresses into looking correct:

- `testValidatorDetectsAnActualLeak` — a validator that always passes proves
  nothing about the one that passes.
- `testExportGate_blocksWhenOnlyTheDefaultCategoriesAreApplied` — the person
  rules are load-bearing, not decorative.
- `testEvidenceSeal_fourVerdicts` — including `.noSeal`, so a held message
  with nothing recorded can never read as intact.

## Mistakes I made while auditing

Recorded because each produced a *passing* test that verified nothing — the
same failure as the defects themselves:

- A cloud-refusal test pointed at `~/Library/Mobile Documents`, which does not
  exist on a machine without iCloud Drive. It was testing the environment.
  Rebuilt with a real directory carrying the container marker.
- The shared `probeEmail` fixture has `rawSource: ""`, so a hash assertion
  against it compared against an empty string. `String.contains("")` is
  `false`, which is the only reason it surfaced at all.
- The quarantine guard scans the source directory for references. Had the path
  been wrong it would have scanned nothing and passed, so it now asserts it
  found the app (>100 files, including each quarantined file by name).

One assertion I wrote was simply too broad, and the failure taught something:
`blockedCapabilities()` is empty only for the chain under test, because a fresh
registry has the optional pages off and *their* defaults-on capabilities are
legitimately blocked. That is also why the matrix banner reports dependency
blocks only — page-off blocks would fill it on every fresh install.

## Quarantined, pending deletion

Both need a project-file change to remove, which I did not make. Both are
covered by `EncryptedStorageLossTests.testQuarantinedTypesStayUnused`, which
fails if anything starts referencing them.

- `maxmailin/EncryptedStorageManager.swift` (351 lines) — lossy "archive".
- `maxmailin/PSTStreamingParser.swift` — superseded; wiring it up regresses
  large-PST import.

## Still open

- **Streaming parser discards the real `From_` envelope.** Deliberately
  deferred: fixing it changes stored hashes and checkpoints. Pinned by a test
  that fails loudly if someone fixes it without migrating.
- **Archive *move* is not automated.** Documented, not implemented — it needs
  close → copy → reopen → verify count → only then delete.
- **PST/OST/NSF/MSG have no fixtures.** A real PST would close those formats
  the way `Sent.mbox` closed the mbox path.
- **Memory figures need a re-take** on a machine with disk headroom.

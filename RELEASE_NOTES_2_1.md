# mailin 2.1 — release notes (claims that the code delivers)

The five-studio + Researcher-persona work, re-numbered from "v3" to **2.1**.

This file replaces the earlier claim text. Three statements in the older plans
did not survive an audit of the code on 2026-09-24, and are corrected here:

| Old claim | Where | Correction |
|---|---|---|
| "All v3 feature work is code-complete and **behaviorally verified**" | `V3_RELEASE_PLAN.md` line 3 | Code-complete: yes. Behaviourally verified: **not when written** — no test in the target referenced any studio. `StudioBehaviourTests.swift` now exists but has **not been executed**. |
| "**6** researcher workflows" | `V3_PLAN.md` Phase 5 | There are **3**: `builtin.researcher.protocol`, `builtin.researcher.screening`, `builtin.researcher.coding` (`WorkflowEngine.swift`). |
| Gold cases 8 (TAR) and 9 (Bates PDF) closed | `V3_RELEASE_PLAN.md` R1.2 | Both were **open**. Tests are now written (`GoldCaseClosureTests.swift`), still **not executed**. S/MIME remains open. |

The rule applied below: a feature is listed only if it has a **Present** row
in `V3_JOB_COVERAGE_MATRIX.csv`, and it is described as *verified* only where
an executed check exists.

---

## What ships in 2.1

### Five studios

Each is a local-first JSON-backed studio with an evidence gate that blocks
posting a numbered document until the evidence is accounted for.

| Studio | What it does | Gate it enforces |
|---|---|---|
| **ACH matrix** | Competing hypotheses × evidence, rated CC/C/N/I/II; ranks by **fewest inconsistencies** (refutation, not support) | ≥ 2 hypotheses, ≥ 3 evidence rows, every cell rated, every uncited row marked as an assumption |
| **Reasoning studio** | 5W1H, five-whys, fishbone, root-cause candidates | Every 5W1H cell cited or explicitly UNKNOWN; a confirmed root cause needs a written rationale and a named decider |
| **Fact–Evidence matrix** | Facts linked to evidence with a Supports/Opposes stance; status = supported / contested / opposed / unsupported | A fact with no evidence blocks unless acknowledged as an open item; uncited evidence must be declared an assumption |
| **Evidence desks** | Admiralty reliability × credibility per source, contradictions, gaps; seeds sources from the archive with an auth-pass hint | A listed source must be rated on **both** axes; every gap must be acknowledged as an ABSENCE |
| **Action register (CAPA)** | Actions linked to causes, owners, statuses | Every action must name its cause; closing needs a named verifier, and closing *as effective* needs an effectiveness note |

The common principle, and the reason these are worth shipping: **the app never
makes the judgement.** It refuses to produce a numbered document until the
human has made it and cited it.

### Researcher persona

**3** built-in workflows — Research Protocol, Screening (Include/Exclude),
Extraction & Coding — plus the researcher surfaces wired into the existing
persona catalogues.

### Also in this line

- Forensic evidence plan gained a fourth operation, "Prioritise & Authorise".
- Defect **V3-D1** fixed: a standalone first name ("Priya will bring it.")
  survived person redaction because the rules covered the full name and the
  address but not a bare name token. Redaction is now case-insensitive and
  covers each name part; the LAW-14 validator re-scans the output.
- mbox export writes a real `From_` envelope and preserves attachments as
  base64 MIME parts, marked `X-Mailin-Reconstructed` where the record was
  synthesised rather than byte-copied. Partitioned export splits on a byte
  budget and never mid-message.
- **ZIP and gzip import** (2026-09-25): a Google Takeout archive or a `.gz`
  mailbox imports directly. Members stream one at a time to scratch, are
  checked against their declared size and CRC-32, parsed by their own format's
  parser, and deleted. Encrypted or damaged members are refused and counted;
  non-mail members and nested archives are skipped and counted. ZIP64 is
  supported. Executed: `ContainerImportTests` (9).
- **Detached S/MIME** (2026-09-25): `multipart/signed` messages are now
  cryptographically verified (see Verification below); before this every one
  read "unverifiable".
- **Bare `.eml` import fix** (2026-09-25): the streaming import path produced
  zero messages for a `.eml` with no mbox envelope line. Fixed and pinned.
- **Import receipt: Retry and attachment coverage** (2026-09-26): "Retry
  failed sources" re-imports the named sources that still resolve and says
  which do not; Recheck shows attachments by family and how far attachment
  content indexing has got.
- **Export receipts** (2026-09-26): every bulk export ends in a receipt —
  requested / written / outcome (complete, truncated, cancelled, failed) /
  SHA-256 / destination — shown in place of the progress bar and saved under
  Application Support/mailin/exports/receipts. `ExportReceiptTests`.
- **Advanced search** (2026-09-26): the guided sheet adds exact phrase, any /
  none-of words (FTS5 Boolean), attachment name or type (`filename:` operator,
  archive-wide in SQL), source file and tag; the composed query is shown so the
  syntax is learnable. `GuidedSearchCompositionTests`, `AttachmentFilenameSearchTests`.
- **Keyboard-first list, drop-anywhere import, filter memory per persona**
  (2026-09-26): see `V2_1_BACKLOG.md` #15.
- **Import checkpoints in the store** (2026-09-26, schema v17): rows and their
  resume checkpoint commit in one transaction. See `V2_1_BACKLOG.md` #7.
- **Envelope-inside-header fix** (2026-09-26): real Gmail `.eml` exports no
  longer split into two half-messages. See `V2_1_BACKLOG.md`, "Found while closing".
- **Whole-archive comparison** (2026-09-25): Archive Comparison no longer
  stops at 2,000 messages per side. Both sides are reduced to key rows in a
  scratch database, matched by Message-ID and then by subject, sender and
  minute, and the differences are paged. The second side may be any supported
  file, including a ZIP. Executed: `ArchiveComparisonEngineTests` (4).

---

## Coverage

`V3_JOB_COVERAGE_MATRIX.csv`: **64 Present · 11 Partial · 0 Absent**.

The 11 Partials are enhancements, not ship-blockers, and are marked **v3.1**:
cited dossier, timeline locators, issues register, reopen history, publish-gate
hard enforcement, renewal extraction, researcher catalogue view, periodisation.

**No store or website claim may cite a Partial row.**

---

## Verification status — executed vs written

This is the part the earlier notes got wrong, so it is stated plainly.

### Executed

| Check | Result |
|---|---|
| mbox import / search / export round-trip | 526 messages: attachment 298,901 / 298,901 bytes recovered; 50 of 526 search hits; 526 → 526 → 526 export, 94,929,888 bytes |
| Storage growth coefficients | store 1.243 ×, FTS 0.044 ×, total 1.286 × of source |
| Zero network activity (Release) | 0 network sockets; `OFFLINE_MODE` in both configurations, no network entitlement |
| Format classification / size policy | `SourceFormatClassifierTests`, `SourceSizePolicyTests` |
| Module gating, page routing, batch control, blob store, index coverage, import verdict | The corresponding unit-test suites |

### Executed 2026-09-25 (previously "written, not yet executed")

| Check | File | Result |
|---|---|---|
| One behavioural test per studio (5 classes, 16 tests) | `maxmailinTests/StudioBehaviourTests.swift` | 16 pass |
| Gold case #9 — Bates stamp visible on every page, via PDFKit read-back | `maxmailinTests/GoldCaseClosureTests.swift` | pass |
| Gold case #8 — predictive-coding ranking (relevant outranks irrelevant) | same | pass |
| Defect V3-D1 regression + validator | same | pass |
| **S/MIME gold case, opaque** — real OpenSSL self-signed `signed-data` through `CMSDecoder`: `validUntrustedCert`; tampered → never valid; truncated → unverifiable | `maxmailinTests/SMIMEGoldCaseTests.swift` | 4 pass |
| **S/MIME gold case, detached** (`multipart/signed`, the common form) — real OpenSSL detached signature verifies from LF- and CRLF-stored copies; one changed signed character → `invalid`; one-part message → `unverifiable` | same, `SMIMEDetachedGoldCaseTests` | 7 pass |
| **Directory sources** — Maildir (`cur`+`new`, `tmp` skipped), folder of `.eml`, Apple Mail `.mbox` package, empty Maildir refused; each through both parser entry points | `maxmailinTests/SourceFormatClassifierTests.swift`, `DirectorySourceImportTests` | 6 pass |

Running the directory-source check found a defect the code-read had missed:
the streaming import path returned **zero messages for any bare `.eml`**, with
no failure reported. Fixed and pinned (`singleEMLStreams`). See
`V2_1_BACKLOG.md`, "Found while closing".

### Still open

- **PST / OST / NSF / MSG import** — code paths exist; no executed fixture run
  is recorded. A real PST would close those formats the way `Sent.mbox`
  closed the mbox path. See `SUPPORTED_FORMATS_AND_LIMITS.md` §7.
- **Directory sources against a real client export** — executed 2026-09-26
  against the owner's real Gmail-exported `.eml` folder (10 files → 10
  messages, both parser paths) and the real 526-message `Sent.mbox` wrapped
  as an Apple Mail package (`RealDirectorySourceTests`, skip-if-absent). A
  Dovecot Maildir export has not been run; none is available on this machine.

---

## Release gate

Nothing in the store description, the website, or the whitepaper may assert a
capability unless it has a **Present** matrix row **and** an executed check.
As of 2026-09-25 the studio behaviour tests and both gold-case files have run
and passed, so "behaviourally verified" is available for the five studios,
person redaction, Bates stamping, predictive-coding ranking and S/MIME
verification (opaque and detached, self-signed fixtures). It is NOT available
for PST/OST/NSF/MSG import.

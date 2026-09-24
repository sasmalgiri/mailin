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

### Written, not yet executed

| Check | File |
|---|---|
| One behavioural test per studio (5 studios, 13 tests) | `maxmailinTests/StudioBehaviourTests.swift` |
| Gold case #9 — Bates stamp visible on every page, via PDFKit read-back | `maxmailinTests/GoldCaseClosureTests.swift` |
| Gold case #8 — predictive-coding ranking (relevant outranks irrelevant) | same |
| Defect V3-D1 regression + validator | same |

### Still open

- **S/MIME gold case** — needs a self-signed sample message to exercise
  `SMIMEHandler`'s verdict path. Not written.
- **PST / OST / NSF / MSG import** — code paths exist; no executed fixture run
  is recorded. See `SUPPORTED_FORMATS_AND_LIMITS.md` §7.
- **Directory sources** (Apple Mail package, Maildir, `.eml` folder) —
  implemented on 2026-09-24, not yet run against a real export.

---

## Release gate

Nothing in the store description, the website, or the whitepaper may assert a
capability unless it has a **Present** matrix row **and** an executed check.
On today's evidence that means: the studios may be described by **what they
do** and **what they refuse**, because that behaviour is in the code and
pinned by tests — but the phrase "behaviourally verified" is not available
until `StudioBehaviourTests` and `GoldCaseClosureTests` have actually run and
passed.

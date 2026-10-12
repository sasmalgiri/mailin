# mailin 3.1+ — Deleted-email recovery · Scripting & automation · Team review

Plan written 2026-10-13, revised the same day after studying how Aid4Mail Investigator, Metaspike (FEC/FEI),
Magnet AXIOM and Intella (Investigator / Connect) solve each feature. The 3.0 rules in `CLAUDE.md` apply unchanged:
offline-first, never destroy data, counts before whole-archive actions, honest receipts, no hidden caps, new
engines behind switches (off until tested), 10 languages, a test that fails without each change.

Status key: `[ ]` to do · `[~]` implemented, untested · `[x]` done (commit).

---

## 0. What we may and may not reuse (legal)

| Source | Licence | How we use it |
|---|---|---|
| Aid4Mail, Metaspike, Magnet AXIOM, Intella **products** | proprietary | **Never copy code, binaries, databases or text.** We learn from their *public* manuals, feature pages and blogs, and build our own design |
| **[MS-PST]** — Microsoft's published PST/OST file-format specification (Open Specifications Promise) | free to implement | **The authoritative source** for folder tables, allocation maps, heap-on-node and property contexts used by R5–R7 |
| **libpff** and its format notes (libyal) | LGPL-3.0 (library) | Reference reading only. **Not linked into the app**: LGPL relinking terms conflict with App Store distribution |
| **vound-software/intella-crawler-scripts** sample scripts | **MIT** | Their *logic* may be ported to our bundled scripts (S7) with attribution in `THIRD_PARTY_NOTICES.md` |
| **pst-testgen** | MIT | Its answer-key idea (manifest of expected counts) shapes R0; the tool itself needs Windows + Outlook, so we build our own fixtures |
| Thunderbird `X-Mozilla-Status` flag meanings | public documentation | Implemented from the documented bit values |

## 1. What exists in mailin today (code inventory, 2026-10-13)

| Area | What is there | Gap |
|---|---|---|
| **Recovery — PST/OST** | `PSTParser.readAllMessages` walks every message node in the node B-tree, so Deleted Items and still-listed soft-deleted messages are imported | Nothing is **marked** deleted; `folderPath` is never filled (no folder tree); unallocated data not recovered |
| **Recovery — mbox** | Gmail Takeout `X-Gmail-Labels` (incl. Trash) kept as tags | Thunderbird `X-Mozilla-Status & 0x0008` (expunged, still in the file until Compact) imported as an ordinary email |
| **Recovery — EMLX** | Apple Mail flag `0x02` → tag "Deleted" | Not a recovery state; not on the receipt |
| **Recovery — NSF / carving** | none | No Notes deletion stubs; no carving |
| **Scripting — Shortcuts** | 8 App Intents | Text results only (not chainable); **Search stops at 10 and says "Found 10"**; no tag / hold / Bates / export / verify actions |
| **Scripting — rules & jobs** | Automation Rules (if-then), guided jobs with "Save as Variant", command palette | Not callable from outside the app; no import-time hooks |
| **Scripting — plugins** | `MailinPlugin` protocol + sandboxed runner | **No plugin is registered** — ships empty; compiled-in only |
| **Team — exchange** | `CollaborationManager` shared-folder `.mailinreview` files | Merge = "local wins unless empty": disagreements silently dropped; tags + notes only |
| **Team — sessions** | `CollaborativeReviewActivity` (SharePlay) | Network — dormant in 3.0 Private |
| **Team — batches** | `ReviewBatchManager` | Local only; no assignee, status, check-out or QC |

## 2. How the leaders solve it (public documentation)

### Deleted-email recovery
| Product | Approach |
|---|---|
| **Aid4Mail Investigator** | "Unpurged mail" (deleted but still in the file/server until compaction/expunge) restored automatically; filter `Type:Unpurged`; PST/OST without Outlook (6.1.4+), mbox, IMAP \Deleted, Exchange Recoverable Items; **MIME carving** from disk images and corrupted mailboxes |
| **Intella** | Optional "Recover deleted emails, files and Notes deletion stubs" (**off by default** since 2.7.1 — slow, can time out); recovered items go to a **`<RECOVERED>`** folder, items outside the root to **`<ORPHAN ITEMS>`**; a **"Recovered" facet**; PST, OST, EDB, NSF stubs, NTFS images; file carving via PhotoRec on E01/DD images |
| **Magnet AXIOM** | Recovers from the whole evidence image (deleted files, unallocated space); header/footer **carving templates**; app-specific carvers (e.g. Gmail on Android) |
| **Metaspike FEC** | Collects Exchange/M365 **Recoverable Items** (deletions, purges) and server history records that show *when* a message was deleted or marked unread (needs a live mailbox) |
| **libpff / [MS-PST]** | *Orphans* (node present, not linked into the folder tree) vs *recovered* (rebuilt from unallocated, 64-byte-aligned blocks). Outlook 2016+ drops Shift-deleted items at once — often nothing to recover |

### Scripting & automation
| Product | Approach |
|---|---|
| **Aid4Mail** | Python at a fixed stage of a **5-stage pipeline** (source folders → pre-acquisition filter → post-acquisition filter → **script filter/modifier** → AI filter); scripts can rename outputs, redact content, OCR images, and **read the AI's classifications**; **10 bundled scripts** with PDF guides, configurable without code; a public ChatGPT script generator |
| **Intella** | **Crawler scripts** (Python, Groovy, Java) run *during indexing* with hooks `itemFound` / `itemProcessed` returning *include / exclude*, adding custom columns, enriching data; samples (MIT) for hash/IP/type/size/date/domain filters, SHA-256 columns, IP/MAC extraction |
| **Magnet AXIOM** | **Custom artifacts** in **XML templates (no code)** or Python; a **Custom Artifact Generator** (no-code); a community **Artifact Exchange** |
| **Apple platform** | App Intents `AppEntity` + `EntityPropertyQuery` → automatic **Find** action in Shortcuts; macOS `shortcuts run` gives a command line; JavaScriptCore runs scripts with no network objects |

### Team review
| Product | Approach |
|---|---|
| **Intella Connect** | Web server for 10/25 concurrent users; batches with statuses **IN_PROGRESS / IDLE / COMPLETED / ARCHIVED**, assignment permission, **read-only** when the batch is someone else's or completed, **"Review later"**, coding layouts guarded by rules, mutually exclusive fields flagged as **conflicts**, multi-user tags, **redaction profiles**, AI tasks that tag batches |
| **Magnet AXIOM** | **Portable Case**: export a subset to stakeholders who need **no licence**, they tag/comment, the examiner **merges tags and comments back**; cloud Magnet Review for live collaboration |
| **Relativity / Everlaw** | Check-out/check-in, review criteria define "done", **QC / second-level review** by a separate group on a sample, **overturn tracking** and per-reviewer error rate with a confidence measure, privilege pass, AI-vs-human disagreement queue |

## 3. Our angle — better, not just equal

1. **Recovery you can defend.** Every recovered email records *how* it was found (flag value, folder, byte offset,
   method, intact or partial) and each receipt counts each kind. Intella puts items in a folder; we also prove where
   each came from.
2. **Deletion analysis.** Deletions on the timeline against hold and custodian-notice dates — a burst before a hold
   is a spoliation signal; none of the four shows this as a ready report.
3. **One recovery switch per source, with a time estimate** (Intella's lesson: recovery is slow) — the import
   preview says "deep recovery adds about N minutes for this 4 GB PST".
4. **Scripts that are offline, sandboxed and provable** — every scripted change carries the script's SHA-256 and the
   email-set fingerprint ("re-run and prove"). A **no-code recipe builder** (AXIOM's XML-template lesson) for
   people who do not program, an **on-device** script assistant (Aid4Mail uses public ChatGPT).
5. **Team review with no server and no extra licence.** Step one is a **Review Pack** (AXIOM Portable Case lesson):
   send a subset to a lawyer or translator who opens it in the **free** tier, codes it, sends it back, and the codes
   merge with a record of who decided what. Step two is a full shared-folder case with signed per-reviewer logs and
   a visible conflict queue — Intella-Connect-class review without a web server.

---

## R. Deleted-email recovery (target 3.1)

| ID | Item | Done means | Status |
|---|---|---|---|
| R0 | **Ground-truth fixtures + manifests** (pst-testgen idea): PST/OST with Deleted Items, Recoverable Items, orphaned nodes and freed blocks — built with our `PSTWriter` and then unlinked/freed per [MS-PST]; Thunderbird mbox with `X-Mozilla-Status` 0x0008 / 0x0009 / 0x000b; mutt/pine `Status`/`X-Status: D`; Apple Mail EMLX flag 0x02 in Deleted Messages; Gmail Takeout Trash; NSF with deletion stubs; a damaged mbox; a raw blob with embedded MIME | Each fixture's manifest lists expected live / deleted-folder / unpurged / orphan / carved counts; generated, never real mail | [ ] |
| R1 | **Recovery provenance model**: per email `recoveryState` ∈ {live, deletedFolder, flaggedDeleted, unpurged, orphan, carved, deletionStub} + `recoveryEvidence` (folder path, flag value, byte offset, method, intact/partial). Schema bump with snapshot first (rule 2); old rows = live | Migration verified one-for-one; old archives unchanged | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R2 | **Find them**: sidebar **Recovered ▸ Deleted folders · Unpurged · Orphans · Carved · Deletion stubs** with counts (Intella's `<RECOVERED>` / `<ORPHAN ITEMS>`, but by *kind*); filters `is:recovered`, `recovery:unpurged` …, negation, AI and Shortcuts can use them | Golden: each filter equals the manifest | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R3 | **mbox**: Thunderbird `X-Mozilla-Status & 0x0008` → unpurged (flag value kept as evidence); `Status`/`X-Status` with `D` → flaggedDeleted; Gmail `Trash`/`Deleted` labels → deletedFolder | Fixture counts match; nothing previously imported is dropped | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R4 | **EMLX**: flag 0x02 and Deleted Messages / Trash mailboxes → recovery states (old "Deleted" tag kept, rule 16) | Fixture counts match | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R5 | **PST/OST folder tree** per [MS-PST] hierarchy tables: every message gets its real `folderPath` (benefits every PST import); Deleted Items, **Recoverable Items (Deletions / Purges / Versions)**, Junk identified | Folder paths equal the fixture | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R6 | **PST orphans**: message nodes in the node B-tree but in no folder's contents table → orphan | Fixture orphans exact | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R7 | **PST deep recovery** (switch, preview, **off by default per source** with a time estimate): walk allocation-map free regions at 64-byte alignment for heap-on-node / property-context signatures; rebuild intact items; incomplete ones → carved + partial with offsets. Source opened read-only; SHA-256 before = after | Freed fixture items recovered or reported partial; fuzzed (P3 harness); 1 GB PST memory-flat | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R8 | **NSF deletion stubs**: Notes stubs listed (they hold no body — said so) | Fixture stubs listed | [✗] **not feasible yet** (2026-10-13): our NSF reader is a heuristic item scanner with no note-header / RRV-bucket parsing, so a deletion stub cannot be told from a damaged note. Needs a real NSF note-table reader first; until then stubs are not listed and the limits doc says so |
| R9 | **Carving** (switch, preview): stream any file for RFC 5322 header runs, plus **user-defined header/footer carving templates** (AXIOM lesson) for odd formats; each candidate verified (parsable headers + body boundary) before it counts | Blob fixture: every embedded message found; zero false positives on 1 GB of random data; memory flat | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R10 | **Recovery report and receipt**: per source "X live · Y deleted-folder · Z unpurged · N orphan · M carved (K partial) · S stubs"; source hash before/after; time spent; exported with the chain of custody | Receipt round-trips; numbers equal the manifest | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |
| R11 | **Deletion analysis** (innovative): deleted/recovered mail on the timeline with hold / custodian-notice dates; "deleted within N days before the hold"; per-custodian deletion bursts; section in the investigation report | Golden: planted deletions before a hold counted exactly | [~] hold-date counts + by-month implemented, untested; per-custodian bursts and report section open |
| R12 | **UI and limits**: "Recovered" badge with the evidence line ("unpurged — X-Mozilla-Status 0009 at byte 1,204,331"); import preview shows the recovery switch and its time estimate; limits stated (compaction destroys unpurged mail; Outlook 2016+ leaves no orphans; carving is best-effort) | UI check; 10 languages; SUPPORTED_FORMATS_AND_LIMITS.md updated | [~] implemented 3e4b9cb+; tests in RecoveryTests / PSTRecoveryTests (ac36340, 29d9313) |

## S. Scripting & automation (target 3.1)

| ID | Item | Done means | Status |
|---|---|---|---|
| S0 | **Bug fix now**: Shortcuts "Search Emails" returns the exact total ("Found 1,284; showing the first 10") | Test: 25 matches → says 25 | [~] 3e4b9cb — first tests c833a97 |
| S1 | **App entities**: `EmailEntity`, `MatterEntity`, `DocumentEntity`, `TagEntity`; `EntityPropertyQuery` over the whole archive (sender, recipient, subject, dates, tag, attachment, **recovered**) → automatic **Find Emails** in Shortcuts, paged | Find equals SQL count; 100k memory-flat | [~] EmailEntity (no Matter/Document/Tag entities yet) — first tests c833a97 |
| S2 | **Action intents** through `OrgPolicy` and count-before-action: import files (no UI), run saved search, tag/untag, place/release hold, assign Bates, export (CSV, PDF, mbox, EML, PST, load file) to a folder, verify integrity, run a guided job, build investigation report, export audit trail; results as files/entities so actions chain | Each intent tested on a disposable archive; refused for a role that may not; audited only after it happened | [~] count / tag / hold / CSV export; import, Bates, PDF/mbox/PST, verify, report intents open — first tests c833a97 |
| S3 | **Long runs from Shortcuts** via the scope engine (progress, cancel, resume, receipt "started by Shortcuts"); Mac folder-watch automation documented | Interrupted run resumes | [~] tag/hold run through ScopeJob.runIDs; folder-watch documented — first tests c833a97 |
| S4 | **Command line for free**: `shortcuts run "mailin Export" -i … -o …` documented | Verified example | [~] SHORTCUTS_AUTOMATION.md; example not yet run |
| S5 | **Pipeline stages** (Aid4Mail + Intella lesson): scripts can run **at import** (`itemFound` before storing → include/exclude; `itemProcessed` after parsing → enrich, add custom columns, tag) or **on demand** over a scope; one run order shown to the user: source filter → script → AI → store | Import-time exclusion recorded in the receipt ("12 excluded by script X v3"); nothing silently dropped | [~] post-commit import hook (set-aside = Trash, never dropped; script_runs row per script+source); receipt lines not yet shown in the import receipt — first tests c833a97 |
| S6 | **mailin Scripts** (switch, preview): JavaScript in JavaScriptCore with a small API (`archive.find`, `email.fields`, `email.ai` — the AI classification, `tag`, `note`, `column`, `report.add`); no network objects; CPU/time/memory watchdog; writes are proposals shown with counts (dry run first) | Hostile scripts (loop, huge allocation, network attempt) stopped and reported | [~] ScriptEngine.swift: JSC, eval/Function removed, loop-guard watchdog + memory ceiling, dry run → apply; email.ai not exposed yet; instrumenter ignores regex literals (a quote inside a regex can hide a loop from the guard) — fix in test pass — first tests c833a97 |
| S7 | **Provable runs**: script SHA-256 + version + email-set fingerprint + changes recorded; "Re-run and prove" | Same script + archive → same fingerprint and changes | [~] script_runs + Re-run and prove — first tests c833a97 |
| S8 | **Bundled script library** (offline): ported from the MIT Intella samples — hash list exclude, IP filter, type/size filter, date filter, domain filter, SHA-1/256/512 columns, IP extraction; plus Aid4Mail-class scripts — attachment risk score, integrity verification, entity catalogue, relationship map, keyword proximity, silence / date-gap detector, privilege screen, PII redaction rules, custodian summary. Each configurable without code | Golden test + one-page help per script; attributions in THIRD_PARTY_NOTICES.md | [~] 12 scripts written fresh (no Intella code copied; THIRD_PARTY_NOTICES.md); help pages and golden tests open |
| S9 | **No-code recipe builder** (AXIOM XML-template lesson): pick a stage, conditions and actions from menus → saved as a script; the generated code is viewable | Every bundled script can be rebuilt as a recipe | [~] RecipeBuilderView; "every bundled script as a recipe" not yet true (hash/IP scripts need functions) — first tests c833a97 |
| S10 | **On-device script assistant**: a sentence → Foundation Models drafts a script → shown for review, never run unseen | Drafts compile for the bundled goals | [~] ScriptAssistant (Foundation Models, macOS/iOS 26) — first tests c833a97 |
| S11 | **Script files** `.mailinscript` export/import (hash-verified) for sharing inside a team — no online exchange (offline rule) | Tampered file refused | [~] ScriptFile export/import, SHA-256 checked — first tests c833a97 |
| S12 | **Plugins**: the empty compiled-in system becomes script packages or is retired behind its switch; no dead screen | No empty plugin UI | [~] plugin empty state points to Scripts when on |
| S13 | **App Review note**: scripts are user-authored, local, never downloaded (guideline 2.5.2) | Text in the submission checklist | [~] AppReviewNotes.md Q&A added |

## T. Team review without a server

| ID | Item | Done means | Status |
|---|---|---|---|
| T0 | **Review Pack** (target 3.1 — AXIOM Portable Case lesson, smallest useful step): export a scope + chosen coding fields as a sealed `.mailinpack`; the recipient opens it in **any** mailin, including the **free tier, with no licence**; codes, tags, notes; returns a signed response file; the examiner merges it — every decision recorded with who and when; disagreements with existing codes go to a conflict list | Round trip on two installs; tampered pack or response refused; nothing overwritten | [~] ReviewPack.swift + ReviewPackView.swift (Settings ▸ Review Pack), untested. Open: the reviewer path is behind the Professional-page switch, so free-tier reviewers cannot reach it yet (needs a .mailinpack document type in Info.plist — owner, pbxproj); response signatures prove integrity, not identity (identity is T2) |
| T1 | **Shared case folder** (3.2): NAS / file server / external drive; read-only evidence copy + manifest + one append-only log per reviewer; works with the network unplugged | Two instances on one share reach the same state | [~] TeamCase.swift: .mailincase folder, read-only evidence pack, per-device logs — first tests c833a97 |
| T2 | **Reviewer identity**: examiner name + per-device Ed25519 key; MDM role where managed; entries signed and hash-chained | Tampered entry rejected and reported | [~] Ed25519 device key + name + OrgPolicy role per entry, signed and hash-chained; MDM identity not wired — first tests c833a97 |
| T3 | **Operation log + deterministic merge** (Lamport clocks): tags, coding, notes, batch actions, QC — the case is the fold of all logs; nothing overwritten (rule 1); multi-user tag semantics as in Intella (a tag stays while any reviewer holds it, history shows each) | Property test: any interleaving → same state | [~] deterministic fold (Lamport, author, seq); tag held while any reviewer holds it; property test open |
| T4 | **Conflict queue**: different codes on one email, or mutually exclusive fields both set → conflict with both decisions; a lead resolves; history keeps both | Planted disagreements all appear | [~] conflicts = differing codes, lead resolves by entry; mutually exclusive field sets not modelled (single-choice codes only) |
| T5 | **Batches** (Intella lesson): statuses in progress / idle / completed / archived; assign permission by role; check-out lease file with expiry; **read-only** when the batch is someone else's or completed; **"Review later"**; reopening jumps to the first uncoded item; "done" = coding rules met | Two reviewers can never hold one batch; expired lease reclaimable | [~] batches, O_EXCL lease files with 4 h expiry, read-only when not yours / completed, Review later, first-uncoded jump; batch permission by role not yet |
| T6 | **Coding layouts with rules**: fields, required choices, mutually exclusive sets per matter | Invalid coding cannot be saved | [ ] only single-choice codes from the manifest; layouts with required fields not built |
| T7 | **QC / second-level review**: sample % per reviewer into a QC queue for a different group; **overturn tracking**, per-reviewer error rate with a confidence interval | Planted overturns exact; interval matches the formula | [~] deterministic QC sample, qcCode op, overturn rate + Wilson 95 % interval; QC-group restriction and QC coding UI open |
| T8 | **AI-vs-human disagreement queue**: predictive-coding score strongly against the human code → QC candidate | Fixture disagreements surface | [ ] not built (needs predictive-coding scores in the case) |
| T9 | **Privilege pass** and privilege log from the merged, resolved state; **redaction profiles** shared across the team | Log equals resolved decisions | [~] privilege log CSV from the standing (agreed/resolved) codes; shared redaction profiles open |
| T10 | **Team dashboard**: batches, throughput, open conflicts, overturn rate | Numbers equal the logs | [~] dashboard in TeamCaseView (coded, conflicts, team, batches, QC); throughput over time open |
| T11 | **Merged team audit trail** with reviewer + role; JSONL export (extends 3.0) | Chain verifies | [~] merged audit JSON Lines export of verified entries |
| T12 | **Robust on shared drives**: atomic writes, partial-write detection, offline queueing, clock skew | Fault tests: share unplugged mid-write, two writers, skewed clocks | [~] atomic manifest/lease writes, torn-last-line detection, tamper stops a log; fault tests open |
| T13 | **Production stays with the lead** (Examiner+ on the merged state) | Role test | [~] apply-to-archive lead-only + OrgPolicy .produce; existing codes never replaced |
| T14 | **Migration**: old `.mailinreview` files import as log entries; old exchange one switch away (rule 14) | Nothing lost | [~] .mailinreview import into the case as marked entries in your own log; old exchange untouched (rule 14) — first tests c833a97 |

## F. Also worth adopting (from Metaspike FEI — forensic analysis, offline)

| ID | Item | Done means | Status |
|---|---|---|---|
| F1 | **Hidden timestamps** decoded from MIME boundaries, Message-IDs (incl. historical Gmail formats) and Outlook **Thread-Index**; one timeline of every timestamp with its source and UTC value | Fixture timestamps decoded exactly | [~] ForensicSignals.swift (Thread-Index, Outlook/JavaMail boundaries, Message-ID epochs, Received, Date); historical Gmail Message-ID formats not decoded — first tests c833a97 |
| F2 | **Missing-DKIM detector**: a bundled table of when major providers began DKIM signing; a message from such a provider after that date without a signature is flagged | Planted cases flagged, others not | [~] DKIMExpectations table (conservative dates, to be checked against sources in the test pass); in the risk score when on — first tests c833a97 |
| F3 | **Offline DKIM / ARC verification** against a **key cache** the examiner imports (or captured at collection); never a live DNS lookup unless an online toggle is on | Known-good and tampered fixtures verify / fail correctly | [~] DKIMVerifier rsa-sha256 / ed25519-sha256, simple/relaxed, key cache imported from a text file; ARC not yet — first tests c833a97 |
| F4 | **Removed-attachment and tampering signals** folded into the existing risk score; **Received-header trace view** | Fixture signals raised | [~] TamperingSignals + Received trace view in ForensicSignalsView — first tests c833a97 |

---

## 4. Order and gates

1. **S0** (bug fix, 3.0.x update).
2. **R0 → R1 → R3/R4 → R5/R6 → R10 → R2 → R12** — gate: every manifest matches; 1 GB rows memory-flat.
3. **S1 → S2 → S3/S4** — gate: every intent role-checked and audited; Find equals SQL counts.
4. **T0 Review Pack** — gate: round trip, tamper tests.
5. **R7, R8, R9, R11** (preview switches) — gate: fuzzing clean, zero false positives on random data.
6. **S5 → S6 → S7 → S8 → S9 → S10 → S11–S13** — gate: hostile-script tests.
7. **F1–F4**.
8. **T1 → T14** (3.2 / 4.0) — gate: merge property tests and shared-drive fault tests.

Every item: new code in new files, behind a capability switch (off until its gate passes), strings in 10
languages, a failing-without test, zero warnings, committed separately.

## 5. Decisions for the owner

1. **JavaScript scripts (S6)** inside the app — recommended, behind an off-by-default switch; alternative is
   Shortcuts + recipes only.
2. **Team storage (T1)** — shared folder only (recommended, fully offline), or plus optional iCloud Drive (online,
   off by default).

## Sources

Aid4Mail: [email recovery](https://www.aid4mail.com/features/email-recovery) ·
[unpurged mail](https://www.aid4mail.com/support/solutions/articles/what-is-unpurged-mail) ·
[6.2 Python scripting](https://www.aid4mail.com/blog/aid4mail-6-2-python-scripting) ·
[filtering guide](https://www.aid4mail.com/docs/filtering-guide).
Intella: [crawler scripts (MIT samples)](https://github.com/vound-software/intella-crawler-scripts) ·
[file recovery FAQ](https://support.vound-software.com/help/en-us/3-faq/103-file-recovery-in-intella-how-it-works-and-what-to-expect) ·
[Connect reviewer manual 3.0](https://connect.vound-software.com/docs/connect/3.0/Intella%20Connect%20Reviewer%20Manual.html) ·
[Connect editions](https://www.vound-software.com/connect).
Magnet AXIOM: [Portable Case](https://www.magnetforensics.com/blog/deep-dive-portable-case-part-one/) ·
[open a portable case](https://docs.magnetforensics.com/docs/axiom/html/Content/en-us/sharing-evidence/portable-case/open-portable-case.htm) ·
[custom artifacts & Python](https://www.magnetforensics.com/blog/magnet-axioms-custom-artifacts-now-supports-python-development/) ·
[Artifact Exchange](https://www.magnetforensics.com/resources/getting-started-with-magnet-artifact-exchange/).
Metaspike: [FEI](https://www.metaspike.com/forensic-email-intelligence/) ·
[timestamps](https://www.metaspike.com/timestamps-forensic-email-examination/) ·
[DKIM in forensics](https://www.metaspike.com/leveraging-dkim-email-forensics/) ·
[FEC](https://www.metaspike.com/forensic-email-collector/).
Formats & tests: [libpff (LGPL)](https://github.com/libyal/libpff) ·
[PFF format notes](https://github.com/libyal/libpff/blob/main/documentation/Personal%20Folder%20File%20(PFF)%20format.asciidoc) ·
[pst-testgen (MIT)](https://github.com/oblomsky42-dev/pst-testgen) ·
[email-date-range](https://github.com/oblomsky42-dev/email-date-range) ·
[X-Mozilla-Status flags](https://vincent.bernat.ch/en/x-mozilla-status).
Review practice: [Everlaw assignments](https://support.everlaw.com/hc/en-us/articles/210330166-Sample-Assignment-Workflow-Responsiveness-and-Privilege-Review) ·
[Everlaw reviewer analytics](https://support.everlaw.com/hc/en-us/articles/360001037171-Evaluate-Your-Reviewers-Using-Project-Analytics) ·
[Relativity Case Metrics](https://help.relativity.com/RelativityOne/Content/Relativity/Case_Metrics/Case_Metrics.htm).
Apple: App Intents (entity queries, Find actions) and JavaScriptCore documentation.


## Test pass 2026-10-13

- Package: RecoveryTests (16), PSTRecoveryTests (2), ForensicSignalsTests (10) — package suite 86/0 (3 skipped).
- App: V31ScriptTests (9), V31ReviewTests (5), V31ShortcutsTests (3), 3.1 previews-off test; full app suite 863 passed / 0 failed (14 skipped, 25 not run = scale, StoreKit and UI tests that need the owner, as before).
- Defects the tests found and fixed: the carver let one message swallow the next across binary data; DKIM dropped the `=` of `b=` and an extra CRLF (`"\r\n"` is one Swift Character); our PST writer left every message's parent folder at 0 (now [MS-PST] nidParent), and orphan detection would have called such PSTs all-orphans; a script-library save that failed silently.
- 225 new strings translated into all 10 languages (keys-1013a–d.py), placeholder order checked; Hindi "X of Y" uses positional placeholders.
- Still open (not claimed): R0 full fixture set with manifests (NSF, OST, freed PST blocks for R7), R7 deep-scan test, 1 GB carving memory run, S1 100k memory run, Shortcuts intents on a device, T12 fault tests on a real share, T6/T8 not built, instrumenter does not parse regex literals, free-tier reviewer path needs a .mailinpack document type (owner, Info.plist).

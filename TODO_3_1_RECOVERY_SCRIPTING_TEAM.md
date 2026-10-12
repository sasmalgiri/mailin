# mailin 3.1+ — Deleted-email recovery · Scripting & automation · Team review

Plan written 2026-10-13 after the owner asked to add the three features a competitor comparison showed missing
(Aid4Mail Investigator, Metaspike, Intella, Relativity, Everlaw). The 3.0 rules in `CLAUDE.md` apply unchanged:
offline-first, never destroy data, counts before whole-archive actions, honest receipts, no hidden caps, new
engines behind switches (off until tested), 10 languages, a test that fails without each change.

Status key: `[ ]` to do · `[~]` implemented, untested · `[x]` done (commit).

---

## 0. What exists today (code inventory, 2026-10-13)

| Area | What is there | Gap |
|---|---|---|
| **Recovery — PST/OST** | `PSTParser.readAllMessages` walks every message node in the node B-tree (`nid & 0x1F == 0x0C`), so Deleted Items and still-listed soft-deleted messages are imported | Nothing is **marked** as deleted; `folderPath` is never filled (no folder tree); data left in unallocated blocks is not recovered |
| **Recovery — mbox** | Gmail Takeout `X-Gmail-Labels` (incl. Trash) kept as tags | Thunderbird `X-Mozilla-Status & 0x0008` (expunged, still in file until Compact) is imported as an ordinary email — not marked |
| **Recovery — EMLX** | Apple Mail flag `0x02` → tag "Deleted" | Not a recovery state, not filterable as such, not on the receipt |
| **Recovery — carving** | none | No carving of MIME messages from damaged files or raw images |
| **Scripting — Shortcuts** | 8 App Intents (open, import, search, stats, sentiment, ask AI, security report, digest) | Return text only (no entities, not chainable); **Search stops at 10 and says "Found 10"** (a hidden cap); no actions for tag / hold / Bates / export / verify / jobs |
| **Scripting — rules & jobs** | Automation Rules (if-then), guided jobs with "Save as Variant", command palette | Not callable from outside the app |
| **Scripting — plugins** | `MailinPlugin` protocol, sandboxed runner with deadline | **No plugin is registered anywhere** — the system ships empty; plugins are compiled-in Swift, users cannot add their own |
| **Team — exchange** | `CollaborationManager`: shared folder, each examiner exports a `.mailinreview` file, others import | Merge rule is "local wins unless local is empty": disagreements are silently dropped, not recorded; covers evidence tags + notes only (not coding, batches, holds) |
| **Team — sessions** | `CollaborativeReviewActivity` (SharePlay) | Needs FaceTime/network — dormant in 3.0 Private |
| **Team — batches** | `ReviewBatchManager` | Local only; no assignee, no check-out, no QC |
| **Team — roles** | `OrgPolicy` roles from MDM, role in every audit entry, JSONL audit export | Per device only; no merged team audit |

## 1. How the leaders solve it (research summary)

- **Recovery.** Aid4Mail "unpurged mail": messages flagged deleted but still in the file until compaction; a
  filter `Type:Unpurged`; recovery from PST/OST without Outlook, from mbox, IMAP; plus **MIME carving** from disk
  images and corrupted mailboxes. libpff distinguishes **orphan items** (node still in the PST, no longer linked into
  the folder tree) and **recovered items** (rebuilt from unallocated index entries / 64-byte-aligned unallocated
  blocks). Honest limit: Outlook 2016+ drops Shift+Deleted items from the indexes at once — nothing to recover
  (test with 1,800 deletions found none). Thunderbird: `X-Mozilla-Status` bit `0x0008` = expunged, data stays until
  Compact. Forensic practice: hash the source, work on a copy, re-hash at the end; never run repair tools first;
  test against files with a known answer (pst-testgen).
- **Scripting.** Aid4Mail 6.2: Python filter/modifier scripts at a fixed pipeline stage, 10 bundled ready-to-run
  scripts (attachment risk scoring, integrity verification, entity catalogue, relationship mapper …), scripts can
  read AI classification results, and a (cloud) ChatGPT script generator. Apple platform: App Intents
  `AppEntity` + `EntityPropertyQuery` give Shortcuts an automatic **Find** action over the app's data and let
  actions chain; macOS `shortcuts run` gives a command line for free; JavaScriptCore runs sandboxed scripts with
  no network APIs.
- **Team review.** Relativity/Everlaw: batches or queues with **check-out/check-in**, review criteria that define
  "done", **QC / second-level review** by a separate group on a sample, **overturn tracking** and per-reviewer
  error rate with a confidence measure, mutually exclusive codes, AI-vs-human disagreement as a QC queue,
  privilege review as its own pass, a decision log.

## 2. Our angle (what makes it better, not just equal)

1. **Recovery you can defend.** Every recovered email carries *how* it was found (flag value, folder, file
   offset, method) and the receipt counts each kind — "312 live, 41 in Deleted Items, 9 unpurged, 3 carved
   (partial)". Competitors recover; we also *prove* where it came from.
2. **Deletion analysis.** Deleted mail plotted on the timeline against key dates (legal hold, custodian notice):
   a cluster of deletions just before a hold is a spoliation signal no consumer or mid-market tool shows.
3. **Automation that stays offline and provable.** Scripts and Shortcuts run on the device; every scripted change
   is audited with the script's hash and the email-set fingerprint, so a run can be re-done and proven.
   An on-device AI writes a first draft of a script from a plain sentence (Aid4Mail uses public ChatGPT).
4. **Team review with no server.** A shared folder (office NAS, file server, USB) is enough. Each reviewer writes
   a signed, append-only log; the case is the deterministic merge of all logs. Disagreements become a visible
   conflict queue, never a silent overwrite. Works with the network unplugged.

---

## R. Deleted-email recovery (target 3.1)

| ID | Item | Done means | Status |
|---|---|---|---|
| R0 | **Ground-truth corpora**: PST with Deleted Items + orphaned nodes + freed blocks (built with our `PSTWriter`, then nodes unlinked/freed programmatically), Thunderbird mbox with `X-Mozilla-Status` 0x0008/0x0009/0x000b, Apple Mail EMLX with flag 0x02 in a Deleted Messages mailbox, Gmail Takeout with Trash label, a damaged mbox and a raw image with embedded MIME | Each fixture has a manifest of expected live/deleted/recovered counts; fixtures in tests, generated, not real mail | [ ] |
| R1 | **Recovery provenance model**: per email `recoveryState` ∈ {live, deletedFolder, flaggedDeleted, unpurged, orphan, carved} + `recoveryEvidence` (folder path, flag value, byte offset, method, partial yes/no). Schema bump with snapshot first (rule 2); old rows default `live` | Migration test (snapshot, one-for-one); existing archives unchanged | [ ] |
| R2 | **Search and filters**: `is:recovered`, `recovery:unpurged` etc., a "Recovered" smart folder, negation (`-is:recovered`), counts in the sidebar | Golden test: each filter equals the manifest | [ ] |
| R3 | **mbox**: Thunderbird `X-Mozilla-Status & 0x0008` → unpurged (flag kept as evidence); mutt/pine `Status`/`X-Status` containing `D` → flaggedDeleted; Gmail `Trash` label → deletedFolder | Fixture counts match; nothing previously imported is dropped | [ ] |
| R4 | **EMLX**: flag 0x02 and the Deleted Messages / Trash mailbox → recovery states instead of a plain tag (tag kept for compatibility, rule 16) | Fixture counts match; old tag still present | [ ] |
| R5 | **PST/OST folder tree**: parse the hierarchy table so every message gets its real `folderPath` (also improves normal imports); identify Deleted Items, Recoverable Items (Deletions, Purges, Versions) and Junk | Folder paths equal the fixture; existing import tests unchanged | [ ] |
| R6 | **PST orphans**: message nodes present in the node B-tree but in no folder's contents table → `orphan` | Fixture orphans found exactly | [ ] |
| R7 | **PST deep recovery** (switch, preview): walk allocation-map (AMap) free regions at 64-byte alignment for heap-on-node / property-context signatures; rebuild what is intact; anything incomplete is `carved` + `partial`, with the offset. Never modifies the source; runs on a read-only copy | Fixture freed messages recovered or reported partial; fuzzed (P3 harness) — no crash on hostile input; memory flat on a 1 GB PST | [ ] |
| R8 | **MIME carving** (switch, preview): stream any file (damaged mbox, unknown blob, disk-image extract) for RFC 5322 header runs; each candidate verified (parsable headers + body boundary) before it counts | Raw-image fixture: every embedded message found, no false positives on random data; 1 GB stream memory flat | [ ] |
| R9 | **Recovery report and receipt**: per source "X live, Y deleted-folder, Z unpurged, N orphan, M carved (K partial)"; source SHA-256 before and after (unchanged); exported with the chain of custody | Receipt fields round-trip; report numbers equal the manifest | [ ] |
| R10 | **Deletion analysis** (innovative): recovered/deleted mail on the timeline, overlaid with legal-hold and custodian dates; "deleted within N days before the hold" count; included in the investigation report | Golden: planted deletions before a hold date are counted exactly | [ ] |
| R11 | **UI**: "Recovered" badge in the list and detail with the evidence line ("unpurged — X-Mozilla-Status 0009 at byte 1,204,331"); import preview states that recovery will run and its limits ("Outlook 2016+ removes Shift-deleted items; nothing to recover there") | V5-style UI check; strings in 10 languages | [ ] |
| R12 | **Honest limits on screen and in docs**: compaction destroys unpurged mail; modern Outlook leaves no orphans; carving is best-effort and marked partial | Text present; SUPPORTED_FORMATS_AND_LIMITS.md updated | [ ] |

## S. Scripting & automation (target 3.1)

| ID | Item | Done means | Status |
|---|---|---|---|
| S0 | **Bug fix now**: "Search Emails" Shortcuts action stops at 10 and reports "Found 10" — return the exact total ("Found 1,284; showing the first 10") | Test: archive of 25 matches → says 25 | [ ] |
| S1 | **App entities**: `EmailEntity`, `MatterEntity`, `DocumentEntity` (numbered WF/RPT/EXP records), `TagEntity`; `EntityPropertyQuery` for emails (sender, recipient, subject, date range, tag, has attachment, recovered) — Shortcuts gets an automatic **Find Emails** action over the whole archive, paged | Find returns the exact SQL count; 100k archive stays memory-flat | [ ] |
| S2 | **Action intents**, each through `OrgPolicy` and the count-before-action rule (rule 4): Import files (no UI), Run saved search, Add/remove tag, Place/release legal hold, Assign Bates, Export (CSV, PDF, mbox, EML, PST, load file) to a chosen folder, Verify integrity, Run a guided job, Build investigation report, Export audit trail. Results returned as files/entities so actions chain | Each intent: unit test on a disposable archive; refused for a role that may not; audit entry written only after the action happened | [ ] |
| S3 | **Long runs from Shortcuts** go through the scope engine (progress, cancel, resume, receipt); Mac folder-watch automation documented ("when a file is added to Intake, import it and run Keyword Sweep") | Interrupted run resumes; receipt says "started by Shortcuts" | [ ] |
| S4 | **Command line for free**: document `shortcuts run "mailin Export"` with input/output files — no extra binary, stays sandboxed | Doc + one scripted example verified on the Mac | [ ] |
| S5 | **mailin Scripts** (switch, preview): user-written JavaScript run in JavaScriptCore with a small, read-mostly API (`archive.find(query)`, `email.fields`, `tag()`, `note()`, `report.add()`); no network objects exist in the context; CPU/time/memory limits with a watchdog; every write is a proposal shown with counts before it applies (dry run first) | Hostile scripts (infinite loop, huge allocation, network attempts) are stopped and reported; a script cannot touch files outside its output | [ ] |
| S6 | **Provable script runs** (innovative): each run records the script's SHA-256, its version, the email-set fingerprint and the changes; "Re-run and prove" reproduces it | Same script + same archive → same fingerprint and same changes | [ ] |
| S7 | **10 bundled scripts** (match Aid4Mail's set, offline): attachment risk score, integrity verification, entity catalogue, relationship map, keyword proximity sweep, date-gap / silence detector, sender-domain report, privilege screen, PII redaction rules, custodian summary | Each has a golden test and a one-page help | [ ] |
| S8 | **On-device script assistant** (innovative): describe the goal in a sentence → Foundation Models drafts the script → shown for review, never run unseen | Draft compiles for the 10 bundled goals; nothing runs without the user's OK | [ ] |
| S9 | **Plugins**: the empty compiled-in plugin system becomes "script packages" (S5) or is retired behind its switch; no dead UI | No visible plugin screen with nothing in it | [ ] |
| S10 | **App Review note**: scripts are written by the user, stored locally, never downloaded; the capability is described in review notes (guideline 2.5.2) | Note text in the submission checklist | [ ] |

## T. Team review without a server (target 3.2 / 4.0)

| ID | Item | Done means | Status |
|---|---|---|---|
| T1 | **Shared case folder**: a case lives in a folder on a NAS, file server, external drive or (online, opt-in) iCloud Drive: read-only evidence copy + manifest + one append-only log per reviewer. No server, works with the network unplugged | Two app instances on one shared folder reach the same state | [ ] |
| T2 | **Reviewer identity**: examiner name + a per-device Ed25519 key (Keychain); role from MDM where managed; each log entry signed and hash-chained | Tampered or unsigned entry is rejected and reported | [ ] |
| T3 | **Operation log + deterministic merge**: tag add/remove, coding field set, note, batch check-out/in, QC decision — each with a Lamport clock; the case state is the fold of all logs, identical on every machine; nothing is ever overwritten (rule 1) | Property test: any interleaving of the same logs → the same state | [ ] |
| T4 | **Conflict queue** (innovative vs. the current silent merge): two reviewers coding one email differently → a conflict item with both decisions, resolved by a lead; history keeps both; mutually exclusive code sets enforced | Planted disagreements all appear; resolution recorded | [ ] |
| T5 | **Batches with check-out**: lead creates batches; a reviewer checks one out (lease file with expiry in the shared folder), checks it in; "done" = review criteria met (Everlaw-style) | Two reviewers can never hold one batch; an expired lease is reclaimable | [ ] |
| T6 | **QC / second-level review**: random sample % per reviewer into a QC queue for a different reviewer group; **overturn tracking** and per-reviewer error rate with a confidence interval | Planted overturns counted exactly; interval matches the formula | [ ] |
| T7 | **AI-vs-human disagreement queue**: predictive-coding score strongly against the human code → QC candidate | Fixture disagreements surface | [ ] |
| T8 | **Privilege pass**: privileged-coded emails form their own review pass; privilege log built from the merged, resolved state | Log equals the resolved decisions | [ ] |
| T9 | **Team dashboard**: progress per batch, per-reviewer throughput, open conflicts, overturn rate | Numbers equal the logs | [ ] |
| T10 | **Merged team audit trail**: every operation with reviewer, role and time; JSONL export for a SIEM (extends the 3.0 export) | Export round-trips; chain verifies | [ ] |
| T11 | **Robust on shared drives**: atomic file writes, partial-write detection, offline queueing (keep working when the share disappears, sync when it returns), clock skew tolerated | Fault tests: share unplugged mid-write, two writers at once, skewed clocks | [ ] |
| T12 | **Production stays with the lead**: Bates and productions only by Examiner+ on the merged state; reviewers cannot produce | Role test | [ ] |
| T13 | **Migration from 3.0 review files**: existing `.mailinreview` exchanges import as log entries; the old exchange stays one switch away (rule 14) | Old files import with nothing lost | [ ] |

---

## 3. Order and gates

1. **S0** (bug fix, ships in a 3.0.x update).
2. **R0 → R1 → R3/R4 → R5/R6 → R9 → R2 → R11/R12** — gate: every fixture's manifest matches; 1 GB rows memory-flat.
3. **R7, R8, R10** (preview switches) — gate: fuzzing clean, no false positives on random data.
4. **S1 → S2 → S3/S4** — gate: every intent role-checked and audited; Find equals SQL counts.
5. **S5 → S6 → S7 → S8 → S9/S10** — gate: hostile-script tests green.
6. **T1 → T2 → T3 → T4 → T5 → T6 … T13** — gate: merge property tests and shared-drive fault tests green.

Every item: new code in new files, behind a capability switch (off until its gate passes), strings in 10
languages, a failing-without test, zero warnings, committed separately.

## 4. Rough size

| Track | Size | Notes |
|---|---|---|
| R (recovery) | large — PST deep recovery and carving are the hard parts | R1–R6 + R9 are the high-value core |
| S (scripting) | medium — App Intents is mostly wiring; the JS runner needs careful limits | |
| T (team) | very large — new data model, merge, sync, QC | 3.2 / 4.0 |

## 5. Decisions for the owner

1. **JavaScript scripts (S5)** — user-written scripts inside the app. App Review allows user-authored local code,
   but it is a judgement call; the alternative is Shortcuts-only automation (S1–S4) with no scripting language.
2. **Team review storage (T1)** — shared folder only (fully offline), or shared folder plus optional iCloud Drive
   (online, off by default).

Sources: [Aid4Mail email recovery](https://www.aid4mail.com/features/email-recovery),
[What is unpurged mail](https://www.aid4mail.com/support/solutions/articles/what-is-unpurged-mail),
[Aid4Mail 6.2 Python scripting](https://www.aid4mail.com/blog/aid4mail-6-2-python-scripting),
[Aid4Mail filtering guide](https://www.aid4mail.com/docs/filtering-guide),
[libpff recovery API](https://manpages.ubuntu.com/manpages/resolute/man3/libpff.3.html),
[PFF format](https://github.com/libyal/libpff/blob/main/documentation/Personal%20Folder%20File%20(PFF)%20format.asciidoc),
[email-date-range (orphan vs recovered; Outlook 2024 test)](https://github.com/oblomsky42-dev/email-date-range),
[pst-testgen](https://github.com/oblomsky42-dev/pst-testgen),
[X-Mozilla-Status flags](https://vincent.bernat.ch/en/x-mozilla-status),
[Everlaw assignment workflow](https://support.everlaw.com/hc/en-us/articles/210330166-Sample-Assignment-Workflow-Responsiveness-and-Privilege-Review),
[Everlaw reviewer analytics](https://support.everlaw.com/hc/en-us/articles/360001037171-Evaluate-Your-Reviewers-Using-Project-Analytics),
[Relativity Case Metrics (overturns)](https://help.relativity.com/RelativityOne/Content/Relativity/Case_Metrics/Case_Metrics.htm),
[Lexitas review best practices](https://www.lexitaslegal.com/resources/document-review-people-processes-and-technology),
Apple App Intents (entity queries, Find actions) and JavaScriptCore documentation.

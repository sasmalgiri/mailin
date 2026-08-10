# mailin Workflow Engine — Detailed Plan (SAP-style process orders)

Status: PLAN — awaiting approval before schema v8. Author date: 2026-08-10.

## 1. The concept (SAP → mailin)

SAP separates the **master recipe / routing** (how a job is done — a reusable
template of operations) from the **process order** (one execution of that
recipe, with its own number, confirmations per operation, and a settlement /
completion). We build the same split:

| SAP | mailin | Persists as |
|---|---|---|
| Routing / master recipe | **WorkflowDefinition** | `workflow_definitions` + `workflow_operations` (master data) |
| Process order | **WorkflowInstance** (`WF-YYYY-####`) | `workflow_instances` (transaction) |
| Operation confirmation (CO11) | **OperationConfirmation** (who/when/result/note) | `workflow_confirmations` |
| Material number | Work-element numbers already issued (SRC-####, BATCH-####, CUST-####, Bates, Message-ID) | existing |
| Material/goods document | Documents already issued (IMP/VRD/EXP/RPT/STY/CLN) | `documents` (v7, shipped) |
| Change documents | HMAC audit chain (shipped) | `forensic_audit` |
| Reversal (storno) | reversal document referencing the original | `documents.reverses` (v8) |

The workflow instance is the **day-to-day work record beyond the audit trail**
the user asked for: a durable, reopenable, reportable, printable object that
says exactly what was done, by whom, in what order, and what it produced.

## 2. Grounded persona workflows (researched)

Templates are modeled on the canonical frameworks, trimmed to what mailin can
actually do against an email archive. Each operation, when confirmed, posts the
document type it already knows how to post.

### Forensic Investigator — "Evidence Intake & Review"
Framework: **NIST SP 800-86** (Collection → Examination → Analysis → Reporting)
+ chain-of-custody discipline.
1. **Receive & Identify** — record case, custodian, source; import. → posts `IMP`
2. **Preserve & Hash** — compute/verify per-email SHA-256; seal. → hash artifact
3. **Examine** — code evidence tags, flag items of interest.
4. **Analyze** — extract IOCs / anomalies over the set.
5. **Document & Report** — daily activity report. → posts `RPT`
Identifiers: CASE (user), SRC-####, Item #, Bates, SHA-256.

### Legal / eDiscovery — "Production Run"
Framework: **EDRM** (Review → Analysis → Production phases).
1. **Assemble Batch** — create/assign a review batch. → BATCH-####
2. **Review & Code** — responsive / non-responsive / privileged.
3. **Privilege Log** — annotate every privileged doc (defensibility gate).
4. **Bates & Redact** — stamp production numbers.
5. **Produce** — export the set; defensibility summary. → posts `EXP` + `RPT`
Identifiers: BATCH-####, Bates (ACME-00001), PROD numbers, privilege-log entries.

### IT Administrator / SOC — "Phishing Incident"
Framework: **NIST SP 800-61** (Detection & Analysis → Containment → Post-incident).
1. **Intake** — reported email auto-imports (watch folder). → posts `IMP`
2. **Analyze** — headers/auth, URLs, attachment hashes; IOC extract.
3. **Verdict** — Confirmed / Safe / Needs-info. → posts `VRD` (the ticket's number)
4. **Contain** — export IOC blocklist for gateway/firewall. → posts `EXP`
5. **Close** — incident note; metrics.
Identifiers: INC (= WF number), VRD-####, IOC list, EXP-####.

### Journalist / Researcher — "Story Build"
Framework: ICIJ-style (Obtain/verify → Search → Cross-reference → Annotate →
Source/fact-check → Publish).
1. **Ingest & Verify** — import leak/FOIA set; provenance receipt. → posts `IMP`
2. **Find Leads** — search; identify threads of interest.
3. **Annotate Findings** — one claim per annotation (becomes a cited finding).
4. **Compile Story** — build the cited Markdown story file. → posts `STY`
5. **Fact-check & Version** — save versioned. → posts `STY`
Identifiers: WF number, STY-#### (version), source Message-IDs as citations.

### Personal — "Archive Cleanup"
Framework: personal lifecycle (Backup → Dedupe → Categorize → Purge → Export).
1. **Import / Backup** — bring in the archive. → posts `IMP`
2. **Dedupe** — archive-wide duplicate removal. → posts `CLN`
3. **Categorize** — labels / folders.
4. **Export** — final backup. → posts `EXP`
Identifiers: WF number only (personal work stays light).

## 3. Data model (schema v8)

New tables (all additive; migration follows the tested v-by-v pattern):

```
workflow_definitions(def_id TEXT PK, name, persona, builtin INT, created_at, created_by)
workflow_operations(def_id, seq INT, key TEXT, title, hint, posts_doc_type TEXT NULL,
                    PRIMARY KEY(def_id, seq))
workflow_instances(wf_number TEXT PK, def_id, title, status TEXT,   -- open|released|confirmed|reversed
                   created_at, created_by, updated_at, reverses TEXT NULL)
workflow_confirmations(wf_number, seq INT, confirmed_at, confirmed_by,
                       result TEXT, note TEXT, doc_number TEXT NULL,
                       PRIMARY KEY(wf_number, seq))
```

Plus the v8 lifecycle additions folded in from task #41:
- `documents` gains `created_by TEXT`, `reverses TEXT NULL`, `reversed_by TEXT NULL`
- `doc_notes(doc_number, created_at, created_by, note)` — append-only notes

`WF-YYYY-####` numbers come from the existing `doc_counters` range machinery
(type `WF`), so they share the never-repeat/never-skip guarantee.

## 4. Engine (pure + actor)

- `WorkflowDefinition` / `WorkflowOperation` / `WorkflowInstance` /
  `OperationConfirmation` value types.
- `WorkflowCatalog` (pure): the five built-in templates above; user clones/edits
  stored as non-builtin definitions.
- Store actor APIs: `createInstance(defID:title:)→WF#`, `confirmOperation(wf:seq:
  result:note:docNumber:)`, `openInstances()`, `instance(wf:)` with confirmations,
  `reverseInstance(wf:reason:)`. All transactional; each confirmation echoes to the
  audit chain and stamps `created_by` = examiner.
- `WorkflowReportBuilder` (pure, tested): renders an instance to plain text /
  Markdown — header (WF#, definition, who, status), each operation with its
  confirmation and posted document number, footer. Printable.

## 5. UI

- **Work Center → Workflows tab** (5th tab): "Start a workflow" (pick a template
  for your persona) · "Open runs" (resume) · lookup any `WF-…`.
- **WorkflowRunnerView** (own window): the operation checklist for one instance —
  each step shows its hint, a Confirm button that runs the real tool (or records a
  manual confirmation), the posted document number inline, and who/when once done.
  Reopen continues where left off. Reverse (with reason) posts a storno.
- **Documents tab** rows expand to detail: who/when, notes (+ add), Reverse,
  Trace (audit entries citing the number, and the WF that posted it).
- **Print**: `WorkflowReportBuilder` output → macOS `NSPrintOperation` / iOS print.
- **Definition editor** (Pro): clone a built-in, rename, reorder/add/remove
  operations — "configure as per specific works."

## 6. Delivery (three commits, each green)

1. **Engine + schema v8**: tables, migration, counters(WF), store APIs,
   WorkflowCatalog, WorkflowReportBuilder + document lifecycle (who/notes/reversal).
   Tests: migration continuity v7→v8, instance lifecycle, confirmation ordering,
   reversal (no double-reverse), report rendering, who round-trip.
2. **Runner UI + Workflows tab + per-persona templates wired** to real tools;
   Documents-tab detail (notes/reverse/trace). Tutorials.
3. **Definition editor + print + report export**; final full verification
   (unit suite + macOS click-through + iOS build).

## 7. Scope guards (honest)

- Single-user / single-Mac; instances record `created_by` from examiner name, not
  multi-user routing/approvals (needs the collaboration layer first — stated in UI).
- v1-migrated data has no pre-v8 workflow history; instances start from now.
- Built-in templates are opinionated but fully editable; we don't force a rigid
  process on anyone.
- No new network surface; everything is local, preserving the privacy promise.

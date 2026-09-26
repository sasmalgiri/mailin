# Page / window matrix (3.0, directive §8)

Every page, its windows and sheets, the controls in each, and the states a control can be in.
Written 2026-09-27 against the code on `v3-architecture`. "Reachable from" names the click path;
a surface with no path is a defect (see `REACHABILITY_AUDIT.md`).

Legend for states: **idle · loading · empty · populated · running · paused · error · done**.

## Page 1 — Archive (always on)

| Window / sheet | Reachable from | Controls | States | Code |
|---|---|---|---|---|
| Three-pane shell | first launch with an archive; Tools ▸ Inbox | sidebar (Mailboxes: All / Received / Sent / With attachments / Pinned / Trash; Sources; Labels & Folders; Saved searches + Save current search), list (search field, date scope, J/K, Return, context menu Trash/Restore), detail (prev/next) | loading · empty ("No emails yet") · no results (with index-coverage line) · populated · load earlier/more | `ArchiveThreePaneView`, `ArchiveSidebar`, `ArchiveListPane`, `ArchiveDetailHost` |
| Tools hub | Tools toolbar button | persona-grouped feature list | populated | `ContentView.hubSidebar` |
| Guided import sheet | File ▸ Open, drop anywhere, Detect Thunderbird / Apple Mail, handoff sheet | file list with classifier verdicts; Choices (duplicates, originals, attachment indexing); Space; What to expect; How it will run; Cancel / Start | examining · ready · refused (space) · nothing supported | `GuidedImportSheet` |
| Import queue | toolbar during import; File ▸ Import queue | Pause / Resume / Cancel All / Clear finished; per row: progress, stage, throughput, ETA (estimate), batch envelope, indexed %, Stop this file, Move up/down; pause-reason banner | waiting · running · paused (user / pressure / volume detached) · finished (Complete/Partial/Failed) · failed · stopped · cancelled | `ImportQueueView`, `BulkImportCoordinator.LiveStats` |
| Import receipt | banner after import; File ▸ Last Import Receipt…; Retry by file name | counts, verdict, FTS state, signature, Retry | complete · partial · failed | `ImportReceiptView` |
| Guided search sheet | ⌘K "Guided search", Search menu | people, subject, dates, attachments, filename, phrase, any/none, source, tag; composed query preview | idle · composed | `GuidedSearchView` |
| Export pre-flight sheet | every export button | destination, folder layout, collision rule, attachments folder, mbox split, space estimate vs free; Cancel / Start or Resume | estimating · ready · insufficient space | `ExportPreflightSheet` |
| Export run / receipt card | bottom overlay | progress + Cancel; receipt: verdict, SHA-256 copy, Reveal, Save receipt, Resume | running · complete · truncated · cancelled (resumable) · failed (resumable) | `ExportRunCenter`, `ExportProgressOverlayView` |
| Mail-client import sheet | File ▸ Import from Apple Mail or Thunderbird… | client picker, steps, Detect on this Mac, Choose a folder…, Import found | idle · detected · nothing found | `MailClientImportSheet` |
| Mail-client export sheet | File ▸ Export to Apple Mail or Thunderbird… | client picker, folder, Export and verify; result + client steps, Reveal | idle · writing · reading back · verified · mismatch | `MailClientExportSheet` |
| Archive location | Settings ▸ Storage | folder, footprint, fallback banner, Choose a folder…, Move the archive there now (plan, progress, receipt), Delete the copy on this Mac… | current · proposing move · moving · moved · fallback copy shown | `ArchiveLocationView`, `ArchiveRelocator` |
| Measure an import | About ▸ Measure an import… | Choose…, offset engine toggle, Measure, progress + Cancel, result table, Copy / Save JSON | idle · measuring · result · error | `ImportMeasurementView` |
| Settings ▸ Modules / Features | Settings | page switches, capability switches with maturity, running jobs list | per switch: on · off · blocked by dependency · unavailable (edition / org) | `ModulesSettingsView`, `CapabilityMatrixView` |

## Page 2 — AI Insights (off by default)

| Window / sheet | Reachable from | Controls | States | Code |
|---|---|---|---|---|
| Page shell | page switcher (after enabling) | scope bar: Ask / Summaries / Reports tabs, source menu, date menu, semantic index menu (Build / Pause / Resume / Delete, status) | tab-dependent; index: off · indexing N% · paused · complete · stopped (model unavailable) | `AIInsightsPageView` |
| Ask | shell | question field, model/route, answer with [E#] citations, Show sources | idle · retrieving · answering · answered · abstained | `AIAssistantView` |
| Provenance ("How this answer was made") | Show sources | routing, evidence, Citations [E#] → message with Open, KG, findings, synthesis, hashes | populated | `AIProvenanceView` |
| Summaries | shell | period picker, Generate, sections, Save to documents | idle · generating · populated | `AIDigestView` |
| Reports | shell | title, author, date range, sections, Generate, Save PDF | idle · generating · saved · error | `ReportBuilderView` |
| Cloud consent sheet | any cloud request (compiled in only when `OFFLINE_MODE` is off) | provider, model, bytes, excerpt, Don't Send / Allow for This Session / Send Once; org hard-off notice | pending · resolved | `CloudAIConsentSheet` |
| Activation sheet | tapping an inactive page tab | feature matrix, Enable / Not now | shown · enabling | `PageActivationSheet` |

## Page 3 — Professional Workflows (off by default)

| Window / sheet | Reachable from | Controls | States | Code |
|---|---|---|---|---|
| Page shell | page switcher | Studios strip (Hypothesis Matrix, Fact–Evidence, Action Register, Evidence Desks, Reasoning Studio), Tools strip (Custodians & Holds, Chain of Custody, eDiscovery, Bates, Redaction, Review Batches, Investigation Report), Production…; Work Center below | — | `ProfessionalPageView` |
| Work Center | shell | Workflows (catalog, start/resume, variants) · My Work · Intake Register · Jobs · Documents (table / readable, notes, CSV) · Reports | loading · populated · empty per tab | `WorkCenterView` |
| Workflow runner | Workflows tab | steps with fields and gates, Launch tool, Confirm step, posted documents | step locked · step open · confirmed · complete | `WorkflowRunnerView` |
| Studios (5) | strip / runner | per studio | per studio (see `V3_PLAN.md`) | `ACHMatrixStudioView` etc. |
| Production window | Production… | title, case number, scope operators, exclude tag, withhold held, Bates prefix/start/padding, folder, Produce; record (number, counts, Bates range, pages, families, manifest hash, Reveal) | idle · producing N/M · record · error | `ProductionWindowView` |
| Tool windows | strip | as in the Archive hub | as in the hub | `ProfessionalDestinationView` |

## Page 4 — Live Mail (off by default; feature branch)

| Window / sheet | Status |
|---|---|
| Not built in this configuration | `PageNotBuiltView` states so in plain words. See `LIVE_MAIL_PROVIDER_MATRIX.md` for what the feature branch adds. |

## Cross-page

| Surface | Reachable from | Notes |
|---|---|---|
| Page switcher | top of window | all four tabs always visible; inactive tab asks before enabling; Page-1-only install shows no chrome |
| Feature Guide | ? toolbar button, ⇧⌘/ | searchable |
| Command palette | ⌘K | executes destinations incl. Guided search |

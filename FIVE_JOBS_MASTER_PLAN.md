# mailin — consolidated next-release master plan

**Prepared:** 5 November 2026  
**Updated:** 6 November 2026 — Outlook and Office compatibility expanded into the five-job requirements; 20 additional acceptance cases added; LIFE-06, five-job identity and the scale-evidence decision retained.  
**Purpose:** one implementation and acceptance brief for the next archive-focused release.  
**State:** planning consolidated; app changes and release acceptance are not established by this document.

This replaces the earlier fragmented mailin scope descriptions with one governing plan. It combines the archive-focus review, source-gap analysis, five-job implementation plan, format clarification, removal of artificial limits, and the later preservation, recovery, privacy, usability and access checks. Earlier reviews remain evidence and history; they are not separate competing backlogs.

**Execution scope:** 30 core work items, six cross-cutting LIFE checks and ten release gates, now including the owner's expanded Outlook/Office compatibility goal in sections 4 and 13. Preserve these IDs; the 20 COMP cases are additional acceptance evidence under them. No version number, price or delivery date is implied. Required formats are implementation targets, not claims that the current app already supports them.

| Classification | Meaning |
|---|---|
| Required | Must be implemented or demonstrated to work before claiming this next release completes the five jobs |
| Fix | A specific problem was found in the reviewed source; confirm its state on the actual release branch, then resolve or demonstrate the intervening fix |
| Complete or verify | Required outcome whose present implementation needs inspection and end-to-end evidence; reuse passing code |
| Proposed addition | A recommendation awaiting an explicit scope decision; not an existing capability or silently adopted release promise |
| Later / frozen | Preserve existing customer rights and working features, but do not expand this area during the focused release unless a core requirement depends on it |

## Contents

1. Release goal and customer success contract
2. Source baseline, confirmed gaps and evidence boundaries
3. Feature retention, default experience and commercial positioning
4. Input, attachment and output format matrices
5. The 30 core implementation items
6. The six LIFE acceptance checks
7. Delivery sequence and dependencies
8. Fixtures, performance, usability and recovery validation
9. Ten release gates and the evidence tracker
10. Adopted decisions, proposals and deferred expansion
11. Implementation handoff and release deliverables
12. Owner decisions and final-release closure, 6 November 2026
13. Researched Outlook and Office completion pass, adapter choices and 20 acceptance cases

## 1. Release goal and meaning of completion

**The next mailin release is dedicated to making all five archive jobs fully functional end to end: open large archives, preserve folders, search messages and attachments, identify duplicates safely, and verify exports.**

All five are required release outcomes for the full licensed product. This goal does not change pricing or existing trial entitlements; any trial restriction must be clear before a job starts and must not masquerade as successful full processing. Stop expansion of unrelated AI, analytics, investigation studios, personas and live-mail features during this release. Preserve existing customer data, professional records, holds and purchased capabilities. Existing extras may remain optional; they must not block ordinary archive work.

This is an update to the implementation plan, not a statement that the app has been changed or that acceptance tests have passed. No version number or delivery date is implied.

### 1.1 No arbitrary ceilings or hidden omissions

Remove arbitrary scope ceilings and silent shortcuts from the five jobs. In particular:
- Every imported folder must be reachable; no fixed 200-label ceiling.
- Full-archive duplicate analysis must process the entire declared selection; no 5,000-message ceiling.
- Every supported text-bearing attachment must be indexed in full through chunks/pages; no permanent first-500,000-character cutoff. The same rule applies to message-body indexing. A bounded work unit is acceptable; a hidden permanent content cutoff is not.
- Every selected export record must be accounted for. Verify payload correspondence and preserve a durable per-file verification inventory after completion.
- Large imports must not need RAM proportional to the complete archive. Use bounded parsing, storage and background jobs throughout the pipeline.
- An unfinished, damaged, locked, unsupported or resource-paused item must remain visible and must never contribute to a misleading “everything complete” result.

No software can promise infinite storage, every possible format, perfect OCR or decryption without the required credentials. Keep protective parser/decompression budgets, permission boundaries and format constraints. Use resumable work and explicit partial states when they apply. Do not advertise “unlimited,” “all files” or “no limitations” without a precise, tested scope.

A missing required feature is a release blocker; adding a disclaimer alone does not complete it. An inherently unreadable or unsupported input is handled explicitly rather than invented, silently skipped or counted as success. Do not quietly remove an existing advertised capability to make the checklist pass.

### 1.2 Customer success contract

| Outcome | Release requirement |
|---|---|
| Open | Every advertised source family has a working import path, real-file fixtures where obtainable, complete accounting, bounded-memory operation and tested interruption recovery. Corrupt/unreadable input remains explicitly partial or failed. |
| Preserve | All source folders/labels, nested relationships and message memberships remain reachable and distinguishable, including after deduplication and export. Preserve empty folders when represented by the source. |
| Search | Search messages and supported attachment contents completely; directly open the matching document and parent email. Integrate OCR with stated language/image-quality coverage. Incomplete indexing remains visible. |
| Duplicates | Process the complete selected archive; use full content/attachment comparison for the declared class; preserve source occurrences; make cleanup recoverable and respect holds. |
| Export | Produce the exact selected set, reconcile its content and attachments, retain hashes/inventory, and demonstrate use in each promised destination. “Written,” “verified” and “partial” remain distinct outcomes. |

Required attachment coverage for this release: TXT/CSV, HTML, RTF, text PDFs, DOCX, XLSX, PPTX, supported JPEG/PNG/TIFF images and scanned PDF pages through OCR. Test embedded/attached email where already advertised. Audit the existing advertised list for additional types; do not imply unimplemented legacy formats are covered. Search text extraction and OCR language support are separate capabilities.

Inventory every currently advertised import/export format, including MBOX, EML/EMLX, directory archives, PST/OST, MSG, NSF and compressed containers where claimed. Record supported variants, encryption/credential cases, metadata fidelity and independent fixture evidence. No nominal parser-only support with zero real-file validation should be promoted as fully verified.

## 2. Source baseline and confirmed gaps

The reviewed repository is [sasmalgiri/mailin](https://github.com/sasmalgiri/mailin).

| Source | Observed baseline | Interpretation |
|---|---|---|
| `v3-architecture` | `a8e875883b7888fb59efc093402996370ad37594`; commit dated 9 October 2026; project 3.0/build 602 | Primary source for the technical findings below; v3 app target `maxmailin`, shared core `Packages/ArchiveCore` |
| `main` | `5fb4cc334c39c92f5e10bca909f0a0ea7418a16c`; later support/site edits dated 21 October 2026; project 2.0/build 211 | A later repository timestamp does not establish that this is the newer app implementation |
| Distributed App Store app | Exact source commit not established in this review | Do not equate branch code, website version copy and the shipped binary |

Before editing, identify the actual release branch, local uncommitted work, build target, commit and intended candidate. Preserve newer work and carry relevant fixes forward. This consolidation is not a fresh repository audit or an executed Mac/iPhone/iPad acceptance test.

### 2.1 Findings that drive the backlog

| Finding at the reviewed baseline | What is established—and what is not | Requirement |
|---|---|---|
| Binary archive parsing materialises a complete result before batching | PST/OST/NSF/MSG fallback paths do not gain bounded upstream memory merely from batched writes. This is not evidence that every MBOX path has the same behavior. [Parser fallback](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/EmailParserProtocol.swift#L376) | OPEN-02 |
| Sidebar requests at most 200 labels/folders | A visibility/access ceiling is confirmed; this alone does not prove folders were lost during import. [Sidebar](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/ArchiveSidebar.swift#L143) | FOLD-01 |
| Ordinary attachment indexing lacks modern Office extraction and integrated image OCR | Existing PDF extraction uses embedded text. Separate OCR elsewhere does not demonstrate ordinary-search integration. [Extractor](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/AttachmentTextIndexJob.swift#L164) | FIND-01, FIND-02 |
| An attachment can be marked attempted without searchable text | Attempted extraction must not imply searchable coverage; message-level coverage infrastructure already exists and should be retained. [Index job](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/AttachmentTextIndexJob.swift#L151) | FIND-03 |
| Attachment text keeps only the first 500,000 characters; message indexing also has a body budget | Chunking must remove permanent prefix-only coverage for supported content. Visible partial coverage is useful but does not complete the full-content goal. [Attachment cutoff](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/AttachmentTextIndexJob.swift#L151) · [Format limitations](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/SUPPORTED_FORMATS_AND_LIMITS.md) | FIND-07 |
| One duplicate content scan stops at 5,000 messages | A separate archive-wide Message-ID scan also exists. Do not describe every duplicate path as limited to 5,000. [Content scan](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/DuplicateManagerView.swift#L405) | DUP-02 |
| “Exact” groups can use Message-ID or a short body-prefix fingerprint | Complete body/attachment equality is not established. This is a classification defect, not an observed customer-loss incident. [Grouping](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/DuplicateManagerView.swift#L434) · [Archive-wide ID query](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/SQLiteEmailStore.swift#L2877) | DUP-01, DUP-03 |
| Folder export offers flat/by-year layouts | A metadata path alone does not reproduce the selected source-folder tree. [Export request](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/ExportRequest.swift#L20) | FOLD-05, OUT-03 |
| The per-file folder manifest is removed on successful export | Receipts, hashing and resume checks already exist; preserve them and add durable final inventory plus semantic reconciliation. [Finalisation](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/ArchiveExportService.swift#L591) | OUT-04, OUT-07 |
| Large-message locators may depend on uncopied original sources | Missing originals are documented as errors; do not infer they are silently empty. A self-contained archive mode must remove this dependency for its declared scope. [Source-reference behavior](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/SUPPORTED_FORMATS_AND_LIMITS.md#L126) | OPEN-01, LIFE-01 |
| Real-file and scale evidence is uneven across formats | The checked report records no real OST/NSF run and limited genuine directory-export validation. MBOX scale results and synthetic layouts cannot prove those paths. [Format evidence](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/SUPPORTED_FORMATS_AND_LIMITS.md#L233) | OPEN-06, format matrix |
| Batch-boundary drive recovery does not cover every during-write failure | The scale record includes an observed process failure during a write. Test durable recovery after reattachment and process restart separately. Do not erase existing successful low-disk/batch-boundary evidence. [Scale results](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/SCALE_RESULTS.md) | OPEN-03, LIFE-02 |

### 2.2 Foundations to reuse

Retain working MIME parsing, SQLite storage/FTS, import checkpoints, source/label identity, message-search coverage, export receipts/manifests, recovery, safe previews, purchase restoration and optional module activation. The v3 shell already defaults to Archive; simplification builds on that foundation. Existing relevant code is neither absent by default nor verified merely by its presence.

The [archive-focus review](https://chatgpt.com/library?file_id=libfile_9924e74506e48191a80231c5c1794745&account_id=personal) remains the historical product/source rationale. Its selected public-discussion evidence is qualitative; it is not representative demand measurement or paying-customer usage analytics.

## 3. Feature retention and product presentation

The five jobs define the default product. Supporting reliability, preservation and privacy are part of those jobs. Optional professional functions remain available to existing users and must keep their data and entitlement commitments.

| Feature family | Recommendation | Reason |
|---|---|---|
| Reliable format parsing and MIME decoding | Core | Determines whether email and attachments are actually usable |
| Import progress, pause/resume, error receipts | Core | Users need to trust large jobs and recover from failures |
| External-drive storage and existing safe relocation | Core where supported | Large archives must fit and remain recoverable; a new guided relocation workflow is a later enhancement |
| Familiar message viewer and source/folder browsing | Core | Opening an archive includes reading and finding its contents |
| Ordinary search and filters; preserve existing saved searches | Core | Everyday retrieval should work without AI; new saved-search conveniences remain later enhancements |
| Attachment preview, content extraction, relevant OCR and bulk save | Core | Directly supports retrieval and preservation |
| Exact-duplicate grouping and reversible cleanup | Core | Helps manage repeated imports without discarding distinct evidence |
| Import/export counts, hashes and verification receipts | Core | Establishes what the app actually did |
| Privacy controls, safe HTML, backup/recovery and purchase restoration | Core | These protect the archive and customer access |
| Basic statistics: messages, size, date range, indexing status | Keep small and contextual | Helps explain the archive without creating another dashboard destination |
| Tags, pins, optional conversation grouping and archive comparison | Secondary archive tools | Useful when they shorten retrieval or migration work |
| Local AI search assistance or source-linked summaries | Optional AI module | Can save time, but should not replace deterministic search or be required for ordinary use |
| Near-duplicate suggestions | Optional, review-based | Similarity is not identity and should not drive automatic removal |
| Redacted sharing | Optional advanced export | A specific professional need, with genuine redaction verification |
| Bates numbering, legal holds, custodians and chain-of-custody management | Existing Professional module | Useful to a narrower buyer group; preserve current records and commitments |
| eDiscovery productions and specialised reports | Existing Professional module | Retain for proven users, with narrower claims and explicit scope |
| Hypothesis/fact matrices, Five Whys, reasoning/action/evidence studios | Freeze expansion; keep accessible to existing users | These belong to investigation work and dilute the archive utility's core positioning |
| Sentiment, relationship graphs, predictive insights, large executive dashboards | Hide from the default journey; validate before further investment | Customer value is less directly established for the five archive jobs |
| Live mail, sending, multi-account sync, calendar and general inbox management | Defer as a separate product decision | They introduce a different recurring job, reliability burden and competitive set |
| Cloud AI or broad cloud-sync expansion | Defer unless customers establish a concrete need | Adds data-flow and support obligations without being necessary for local archive retrieval |
| More personas and broad workflow catalog expansion | Freeze | More entry choices do not demonstrate an easier archive task |

Keep legal holds and integrity constraints effective even when their UI module is disabled. Simplifying navigation must not accidentally remove a protection on existing data.

When a convenience appears under “Later” in section 5, that means new development or expansion is deferred. It does not authorise removing an existing working capability. Existing held records, professional outputs, saved settings and purchased modules remain part of upgrade regression coverage.

### 3.1 Default customer experience

The normal app opens into one familiar workspace:
- Sources and folders on the left.
- Messages in the middle.
- Message and attachment preview on the right.
- Import, Search and Export as the primary actions.
- Duplicates as a straightforward secondary tool; retain an existing attachment browser where available.
- Import/index/export status in context, with details available when needed.

Advanced modules remain available through a clearly labelled secondary entry or Settings. Existing users can restore their preferred workspace. No persona selection, case creation, reasoning method or AI setup is required to read an archive.

A product-description draft can lead with:

> Open your email archives, find messages and attachments, review duplicates and export with a clear verification record.

Place supported formats and actually measured limits immediately after that promise. Show archive-specific screenshots first. Professional workflows and optional AI come later in the listing, with accurate availability and privacy wording.

Do not use “all attachments searchable,” “unlimited archive size,” “exact duplicates” or “verified export” as blanket claims where the implementation or test evidence has narrower coverage.

### 3.2 Commercial positioning

The core purchase trigger is recovering usable old mail and documents: open, find, preserve and export them confidently. Some users need a one-time migration; others repeatedly archive and retrieve material. Recurring pricing needs continuing value such as maintained compatibility, repeated archive work and dependable support. More screens do not establish that value.

Keep current Personal/Professional rights, lifetime purchases where applicable, restoration behavior and the adopted trial policy. This plan sets no new prices and does not revive superseded historical purchase-guard instructions. Observe consenting customers doing actual tasks before removing extras or changing the offer. No feature-level evidence established that nobody uses the extras.

Website, onboarding, screenshots, plan descriptions and in-app capabilities must describe the same verified scope. Do not add tracking to a privacy-led product merely to collect feature-use evidence.

### 3.3 Owner-approved identity: the five archive jobs

**Adopted 6 November 2026:** mailin's main identity is an email archive product defined by the five jobs. AI and Professional tools are optional additional capabilities. They do not lead the default workspace, onboarding, screenshots, description or purchase explanation. Preserve existing customer rights, records and protections while changing presentation.

Recommended public identity: **mailin: Email Archive Manager**. This is a proposed display name, not a completed App Store rename or a change to bundle identity/purchases. A proposed subtitle is **Open, search and export email**.

The main product explanation:

> Open your email archives, preserve their folders, find messages and attachments, review duplicates safely, and export with a clear verification record.

| Main promise | What the customer should see |
|---|---|
| Open email archives | Import supported files, read mail and see honest progress/recovery. Explain size handling using the qualified capacity wording in section 3.4. |
| Preserve folders | A complete source/folder tree with original locations and memberships. |
| Find messages and attachments | Simple search and Advanced Search in the same workspace, with active filters, actual match evidence and coverage states. |
| Review duplicates safely | Clearly distinguished copy classes, differences and recoverable actions that preserve source relationships and holds. |
| Export with verification | Clear selection, appropriate format choices, preserved folder mapping and understandable written/verified/partial results. |

Apply this identity consistently:

- **Default app:** open directly into the archive workspace. Keep sources/folders, message list and preview; make Import, Search, Duplicates and Export easy to find. Folder preservation lives in the ordinary archive workflow.
- **Additional tools:** place existing AI/Professional capabilities in a labelled secondary destination or Settings. No case creation, persona choice, AI setup or professional-workflow selection is needed for the five core jobs. Retain holds and integrity rules even when their interface is hidden.
- **Onboarding:** show a short first-import path and sample archive, followed by relevant guidance as each job is used. Optional modules are introduced only when requested or useful.
- **Store and website:** lead with the five jobs. The first five screenshots demonstrate import/read, folder structure, attachment-content search, safe duplicate review and verified export, in that order. Use actual candidate screens and non-private demonstration data.
- **Description and help:** explain supported formats, searchable attachment types, verification meaning and practical capacity openly. Optional AI and specialist features appear later, with accurate availability and purchase requirements.
- **Purchase screen:** explain the archive work and existing plan rights clearly. Do not imply that an AI or Professional module is required for ordinary paid archive functionality. This presentation decision does not change prices or existing entitlements.
- **Review notes and translations:** update the app, screenshots, onboarding, website, descriptions and relevant localisations together. Explain the new search workflow and adopted data-access policy to reviewers.

Before release, a new user must be able to identify the five main jobs and start importing without entering an optional module. Existing specialist users must still find their previously available tools and records.

### 3.4 Capacity claims and the 100 MB test record

**The product goal remains removal of artificial limits in the five core jobs. No new 100 MB product cap has been adopted.** The owner's intent is a final release with complete core workflows, not a special 100 MB edition.

The reported 100 MB runs describe test inputs, not an established maximum supported file size and not a demonstrated MacBook Air hardware limit. The actual Mac model, memory, free disk, app configuration and measured resource use are needed to diagnose a hardware or implementation bottleneck. Apple's profiling guidance supports measuring memory use rather than inferring capacity from one fixture size. [Memory profiling](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)

Keep these distinctions:

| Statement | Evidence and treatment |
|---|---|
| “The full version has no preset archive-size or message-count cap.” | Permitted proposed wording only after the actual candidate's relevant import, indexing, query, paging and export paths are audited for product-imposed ceilings and regression-tested. State that available resources and supported-format constraints still apply. Existing disclosed trial policy is separate. |
| “Every selected item is processed and accounted for.” | Requires complete-scope tests and honest partial/blocked states. Do not equate queued work, a first result page or an attempted extraction with completion. |
| “Tests included 100 MB fixtures.” | Describe exact formats, composition, hardware, build and results. The present report mentions synthetic MBOX/PST/EML-directory/MSG runs; it does not establish every 100 MB archive or every format. |
| “It can handle unlimited everything.” | Not supported. It implies capacity and coverage beyond finite device resources, format constraints, unavailable credentials and supported content. A statement about testing 100 MB does not substantiate that universal claim. |
| “Larger archives are not yet validated by this test matrix.” | A transparent statement about evidence. It is not a feature lock, a new billing limit, or a claim that larger archives necessarily fail. |

Recommended capacity wording, **after the cap audit passes**:

> The full version has no preset archive-size or message-count cap. Processing capacity depends on available storage, memory and the supported archive format. See the tested-workload matrix for the files, devices and results we have verified.

Put the test record beside relevant compatibility/capacity information rather than using a distant disclaimer to contradict the main promise. Do not state “100 MB maximum” unless a real adopted product or format constraint establishes it. Keep parser/decompression safety budgets, cancellation and visible resource-paused states.

Apple's metadata rules require descriptions and screenshots to reflect the core experience and prohibit unverifiable claims in subtitles. Use qualified, evidence-backed wording throughout. [App Review Guidelines, section 2.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata)

## 4. Format support: inputs, attachments and outputs

**Expanded 6 November 2026:** the owner's request makes Outlook interoperability and Office attachment retrieval core strengths of the five-job release. OLM import, legacy Office extraction, common Office variants, and searching inside compressed attachments are now required work, not later suggestions. Section 13 defines the new acceptance cases and implementation sequence. The 30 core IDs remain; reopen affected rows for the broader contract while retaining valid evidence for their earlier scope.

Keep separate evidence for **opening/importing**, **preserving original content and folders**, **extracting/searching**, **comparing duplicates**, **exporting**, and **independent verification**. A recognised extension, a preview, a library's advertised format or a passing synthetic import does not prove all six.

The historical source notes in section 2 describe the older reviewed commit. The subsequent agent report and the owner's 6 November screenshot report newer functionality, but the local unpushed candidate has not been independently audited in this document. The screenshot reports modern DOCX/XLSX/PPTX extraction, while explicitly marking older Office/OpenDocument/iWork as not read, compressed attachment contents as not searched, and protected Office/PDF as locked. Do not describe all Microsoft Office support as absent; do not infer broad compatibility from the three modern extensions.

### 4.1 Incoming mail and archive formats

These are required families for the expanded mail-archive contract. Publish a version/variant matrix for each; "required" describes the target, not current readiness.

| Input family | Required result and current evidence boundary |
|---|---|
| Outlook PST | Read ANSI and Unicode variants, enumerate real folder hierarchy and all accessible mail/attachments/properties, preserve source identity, and support checkpointed processing. Parser and synthetic 100 MB execution are reported; real-origin fidelity and variant coverage still need evidence. |
| Outlook OST | Read the local records actually present, including tested compressed variants; distinguish complete local records, headers/stubs and unavailable data. A shared PST parser is not OST acceptance evidence. Never equate an offline cache with an entire server mailbox. |
| Outlook for Mac OLM | Required direct archive import, with folders, mail, original attachments, available categories and dates. No OLM reader was established by the historical review or supplied implementation report. Do not route an OLM ZIP envelope through a generic ZIP reader and claim semantic OLM support. |
| Outlook MSG and OFT mail items | Decode supported Unicode/ANSI MAPI message variants, recipient tables, available SMTP/Exchange address forms, plain/HTML/compressed-RTF bodies, inline parts, embedded messages and attachments. Validate OFT separately; its extension alone is not proof of MSG compatibility. MSG support is reported; the complete variant contract is not demonstrated. |
| MIME EML and nested EML directories | Single and batch import; original relative paths, encodings, long/Unicode names, inline content, nested messages, large parts and stable source identity. Preserve original MIME bytes where available. |
| MBOX, including extensionless mailboxes | Explicit mbox variants and From-line escaping, complete MIME content, Gmail labels, multiple mailbox files and source identity. Retain the reported streaming/import work. |
| Apple Mail EMLX and exported mailbox packages | Real exports and EMLX fixtures, required companion data, folders, inline resources and supported message flags. Do not mistake a live profile's indexes for self-contained mail. |
| Maildir and supported Thunderbird layouts | cur/new, flags, nested folders, supported profile/export structures and source mapping. Preserve tags/labels separately from physical membership. |
| Existing NSF support | Reconcile every advertised variant against real Notes/Domino fixtures; structured mail/folder/attachment fidelity is required for a full-support badge. A heuristic salvage result stays partial and separate. The Microsoft focus does not waive an existing promise. |
| ZIP/ZIP64, TAR, TGZ/TAR.GZ and GZip mail bundles | Enumerate members, dispatch by actual content, validate the enclosed mail format, preserve paths and reconcile every member. Test multipart export sets where the source tool emits them. GZip decompression alone is not TAR extraction. |
| 7z, RAR/RAR5 and other declared compressed mail bundles | Use the same safely isolated container traversal as attachment search; certify compression/encryption/solid/split variants individually. Missing volumes and unsupported methods are explicit recoverable states. |
| Live Outlook profiles/OLK files, Outlook web/Microsoft 365 accounts, DBX/other historical stores | Publish the actual intake route: an explicitly tested direct adapter or guided export to a supported archive. Do not claim direct support for every profile/version or online mailbox. Live account synchronization remains outside the five-job scope; obtaining an archive is an intake step. Historical formats without an adapter remain visibly unclaimed. |

Outlook archives also contain contacts, appointments, tasks and notes. Inventory these objects and retain the original store in self-contained preservation mode. Preserve/export existing supported non-mail objects and their associated files without forcing them into fake messages. A mail conversion must disclose non-mail omissions; it is not a complete Outlook-profile backup. This does not require rebuilding Outlook's calendar or contact-management application.

Microsoft distinguishes PST and OLM archive workflows, and documents version-specific Outlook import behavior. Its OST documentation also explains that only a subset of a server mailbox may be cached. These facts require explicit source and destination versions in mailin's compatibility tests. [Outlook Mac import](https://support.microsoft.com/en-us/outlook/import-email-messages-contacts-and-other-items-into-outlook-for-mac) · [OST cached subset](https://learn.microsoft.com/en-us/troubleshoot/outlook/user-interface/only-subset-items-synchronized)

### 4.2 Attachment preservation and searchable content

For every accessible attachment, preserve original bytes, original name, declared and detected type, parent relationship, source locator, size and digest. Retain an original Office file unchanged even when its searchable text or preview is generated. The expanded contract adds the following extraction targets; no row is a statement of existing implementation.

| Family and explicit extensions | Required search content and treatment |
|---|---|
| Word: DOC, DOCX, DOCM; DOT, DOTX, DOTM; supported Word XML variants | Main text, tables, headers/footers, footnotes/endnotes, text boxes, comments and tracked-change text with current/deleted/revision distinctions. Test older binary generations separately from OOXML, including Strict/Transitional variants where claimed. |
| Excel: XLS, XLSX, XLSM, XLSB; XLT, XLTX, XLTM; supported SpreadsheetML | Sheet/cell addresses, stored strings/numbers/dates, cached displayed results, comments/notes, hidden sheets/rows/columns and available formulas as a separately labelled field. Never run formulas, VBA, DDE, external links or data refresh. Missing cached results and unsupported formula extraction are explicit partial coverage. |
| PowerPoint: PPT, PPTX, PPTM; PPS, PPSX, PPSM; POT, POTX, POTM | Slide text, tables, text boxes, speaker notes, comments, hidden slides and available chart labels. Label slide/notes/hidden content; do not execute macros or active objects. |
| Other Microsoft business documents: OneNote ONE/ONEPKG; Visio VSD/VSDX and declared templates; Project MPP/MPT/XML; Publisher PUB; Access MDB/ACCDB | Part of the broad Office-compatibility target: extract stored text and embedded supported documents with page/shape/task/table/row context as applicable. Enumerate exact tested versions and properties. Do not execute queries, database code, project calculations or linked-data refresh. An internet notebook link or linked Access table is not local document content. These adapters are new requirements, not established capabilities. |
| OpenDocument: ODT/ODS/ODP, templates and declared flat-XML variants | Corresponding document/table/slide text, annotations, embedded objects and original structure context. Do not classify these as unsupported merely because they are not Microsoft formats. |
| iWork: Pages, Numbers, Keynote | Full stored body/table/slide text for explicitly tested generations, with relevant annotations and embedded files. Identify legacy packages versus newer IWA-based generations. A thumbnail/metadata-only extractor cannot pass this row. |
| PDF | Full embedded text with page association, annotations/form text where extractable, and OCR for scanned/mixed pages. Preserve the file and signatures; do not rewrite it to create the search index. |
| Images and scanned documents | OCR for the declared image formats and tested languages; include JPEG/PNG/TIFF and ordinary screenshot/scan formats supported by the chosen decoder. Label recognition as derived, record coverage and allow retry. OCR does not prove every visible word was recognised correctly. |
| TXT/CSV/TSV, HTML, RTF, JSON/XML/logs, calendar/contact text | Encoding-aware full text with meaningful structural context; safe HTML, no external entity resolution or spreadsheet execution. Do not flatten structured data in a way that invents associations. |
| Attached EML/MSG, MIME message parts, TNEF/winmail.dat | Recursively expose supported messages and actual enclosed attachments; preserve outer and inner bytes and their lineage. TNEF is a message/attachment encoding, not an ordinary document whose visible filename is sufficient. |
| ZIP/ZIP64, 7z, RAR/RAR5, TAR/TGZ/GZip and declared common compression methods | Search supported contents recursively, at both import-container and attachment levels. Preserve the outer archive and member paths; test supported encryption, split-volume and solid variants individually. Safety-paused members remain partial/unknown and resumable, not silently skipped. |
| Embedded Office/OLE/package objects | Decode supported embedded files into child documents with independent types/hashes/coverage. Keep the enclosing Office file and relationships; do not execute an object or follow an external link. |
| Password-protected PDF/Office/containers | Accept the user's password for supported encryption schemes, retry only affected items, and reveal exact progress/coverage. The common PDF and Office password route is required; "locked forever" is not completion when a valid password is supplied. Scheme-level gaps remain explicit until implemented. |
| Other readable binary attachments, including audio/video/executables/CAD | Preserve/export originals and search filenames/available metadata. Spoken-word transcription, executable behavior and arbitrary proprietary-format interpretation are separate capabilities, not implicitly covered by "attachment search." Never execute an attachment. |

**Depth is part of support.** "Searches Excel" must not mean only the first sheet; "searches Word" must not mean only paragraphs in the main body. Hidden, historical and annotation text needs distinct evidence labels and filters. Document revisions and comments must not be quoted as current body text. The exact extraction contract and acceptance cases are in section 13.

Signatures, passwords, S/MIME/OpenPGP encryption, Microsoft rights management, remote links and damaged records are conditions across formats. Preserve originals; distinguish signature integrity from trust, decryption from permission, and an external reference from locally preserved content. Implement user-supplied credential/key workflows for supported schemes; protected enterprise content requires rights-aware authorization, not a password guess or a generic Office parser. Do not fetch remotely or persist decrypted text without the relevant user choice and rights.

### 4.3 Outgoing formats

Import and export are separate capabilities. The latest implementation report says PST export exists; that supersedes the historical statement that it was absent from the reviewed export enum, but it is still a report requiring independent verification.

| Output | Required role and verification |
|---|---|
| EML in source/folder directories | Portable mail with complete attachments and an explicit original-folder/membership mapping. Preserve original MIME when available; label regenerated MIME from MAPI/OLM as a conversion. |
| MBOX per folder, with safe partitioning where necessary | Portable mailbox output with MIME/envelope correctness, independent-reader checks, folder map and durable inventory. A single MBOX does not encode a complete hierarchy by itself. |
| PST | Required Outlook destination for the expanded Microsoft bridge. Verify the reported writer or complete it; validate actual Outlook readability, folders, bodies, attachment digests and declared property mapping. Test the declared PST generation/size strategy; split safely for destination constraints without losing selection accounting. |
| MSG | Retain and verify the reported existing writer for individual Outlook items, including embedded messages, bodies, recipients and attachments. Creating an OLE file is not enough. |
| Original attachments and optional expanded members | Preserve exact bytes/names through safe collision handling; each file maps to its message and container/member chain. Expanded or converted derivatives must never replace the original attachment silently. |
| Full mailin preservation package/backup | Preserve the database, original/retained source material, blobs, mappings, extraction records and necessary metadata through a documented inventory and clean-profile restore. This is the way to keep information that a destination mail format cannot represent. |
| PDF/HTML, CSV/JSON and existing specialist outputs | Viewing/report/extract roles remain explicit; verify their declared fields and attachments. They are not a substitute for a mail-preserving archive or a backup. |
| OLM output | Not required merely because OLM input is required: the tested PST/EML/MBOX routes provide portability. If mailin advertises an OLM writer or a named destination requires one, it becomes a separately tested writer requirement; do not imply it exists. |
| OST/NSF native-store output | No implicit promise to manufacture a live cache or native database. Preserve original stores and provide the tested portable-mail route. |

Verification has three distinct results: **file bytes checked**, **selected mail/content reconciled**, and **destination compatibility tested**. File hashes alone cannot prove that the importer omitted nothing or that another app can read the mail. Keep source-specific metadata that cannot be expressed in the target in a documented sidecar/preservation package and disclose that mapping. Never label a lossy transformation as a byte-for-byte original.

### 4.4 Evidence required for each format

Each matrix row needs exact extension/container variant, originating application/version, fixture permission/hash and known truth; import counts/folders/items; extracted text and section coverage; nested attachment digests/lineage; duplicate comparisons; output field transformations; destination reader/version; interruption behavior; and build/commit/platform.

Publish independent columns for preserved, readable/previewable, content-searchable, exportable, and independently verified. Use implemented, tested, partial, unsupported and not executed distinctly. For the expanded required families, "unsupported but disclosed" is an honest current state, not a completed requirement.

Real format-fidelity fixtures can be small. Preserve the owner's 100 MB scale-evidence decision; format correctness and scale are separate tests. Do not mark the 100 MB synthetic matrix as evidence for real OST/OLM/legacy Office or protected/nested documents it never contained.

## 5. Thirty core implementation items

The “Status” column below describes source evidence at review time; it is not current execution progress. Track actual implementation and verification states separately in section 9. All 30 items are required even where the status is “Complete or verify.”

### 5.1. Open large archives reliably

**Customer outcome:** “I can open my old mail, start reading it, and know whether the import finished correctly.”

| ID | Status | Required work |
|---|---|---|
| OPEN-01 | Complete or verify | Preflight detects the actual archive/container format, readable access, available destination storage and relevant limitations. Distinguish corrupt, unsupported, inaccessible and encrypted inputs. Do not request account credentials to open an ordinary local archive. |
| OPEN-02 | Fix | Use bounded parsing/storage and cancellable work in every required ingest path, including PST/OST/NSF/MSG, the new OLM reader and nested containers. Resolve historical whole-result materialisation and keep database writes, indexing and UI browsing bounded too. A batch writer cannot fix an upstream parser that retains the whole archive. |
| OPEN-03 | Complete or verify | Persist import checkpoints and restart without creating unintended repeated records. Detect changed source content before resuming. Recover after force quit, low disk, permission loss and external-drive removal; never overwrite the original archive. |
| OPEN-04 | Complete or verify | Allow browsing of committed messages while remaining work continues, when safe for that format. Distinguish “mail imported” from “attachment text still indexing.” If no reliable total is available, show processed counts/bytes rather than a fabricated percentage. |
| OPEN-05 | Complete or verify | Produce a per-source import receipt: discovered records where knowable, imported occurrences, intentionally skipped records, unreadable items and unresolved regions. Duplicate grouping is a classification on imported occurrences, not an extra count to double-count. Unknown source totals remain unknown. |
| OPEN-06 | Complete or verify | Exercise Release builds on real and synthetic fixtures across format, file size, message count, largest attachment, nesting, disk type and hardware. Record first-message time, total time, peak memory and temporary disk use separately. |

A damaged source may prevent a precise completeness claim. In that case, preserve an explicit partial/unknown result and the relevant source location; do not infer that successfully parsed records represent everything in the file.

Use the engineering benchmark matrix in section 8.1, beginning with small ground-truth fixtures before the larger tiers. Include very large individual messages/attachments and test their reading, indexing and export paths too. A header-only import does not establish complete content usability. For an external database, a drive removal during a write may terminate the process; verify durable recovery from outside that process after reattachment and relaunch, rather than relying only on a batch-boundary pause test.

**Later:** queue several archives, import a selected mailbox where the format permits, detect changed/new records in a new snapshot of a previously imported source, and offer a guided move to external storage. Reuse source identity so incremental imports cannot silently merge unrelated archives.

**Acceptance:** after interruption and resume, independently known message/attachment identities and counts reconcile; the original file remains unchanged; the UI stays usable within recorded hardware limits. Every exception is visible.

### 5.2. Preserve and expose the entire folder structure

**Customer outcome:** “My mail is still organised, and I can tell where every message came from.”

| ID | Status | Required work |
|---|---|---|
| FOLD-01 | Fix | Replace the 200-entry sidebar ceiling with lazy loading, pagination or a searchable complete tree. Do not render tens of thousands of rows at once simply to remove the cap. Every imported folder must remain reachable. |
| FOLD-02 | Complete or verify | Preserve original source identity, parent/child paths, names and folder memberships. Keep same-named folders from separate archives distinct. Preserve empty folders when the source represents them; disclose when it does not. |
| FOLD-03 | Complete or verify | Represent multiple labels/memberships separately from message content. A message in two labels must not become two unrelated messages, nor should deduplication erase one of its locations. Explain unique-message versus folder-occurrence counts. |
| FOLD-04 | Complete or verify | Keep original location metadata immutable. User-created tags, saved searches and renamed display labels must not rewrite historical paths. Preserve the full parent chain through messages, attachments, winmail.dat, compressed members and embedded documents, as well as direct attachment-to-message relationships. |
| FOLD-05 | Complete or verify | Test Unicode names, nesting, repeated names, long paths and filename/case collisions on export. Use safe output names plus a mapping back to original names when exact filesystem naming is impossible. Never let source names escape the export directory. |

**Later:** folder pinning, saved virtual folders, side-by-side comparison of two archive snapshots, and a user-controlled combined view across sources. Combined views should retain the original locations.

**Acceptance:** test at least 10,000 folders/labels, including empty and nested examples, identical names in two sources, and messages with multiple memberships. Every expected folder is reachable; each message shows the correct original location(s). Folder export preserves or explicitly maps the structure.

### 5.3. Search messages and attachment contents

**Customer outcome:** “I can find the actual message or document, understand why it matched, and see whether the search covered everything relevant.”

**Owner-adopted implementation direction, 5 November 2026:** make FIND-04's advanced search builder explicit while completing FIND-01 through FIND-07. SQL and full-text indexing remain internal implementation tools. Ordinary users get simple search and a visual builder. Active filters, evidence for each match and incomplete-indexing disclosure are required. This amendment changes only the search workstream; the other four jobs, format decisions, entitlement policy and ten release gates remain unchanged.

#### 5.3.1 Reuse the existing search foundation

The following observations are from the already reviewed commit, `a8e875883b7888fb59efc093402996370ad37594`. Reconcile them against the actual release branch before changing code. They are source observations, not newly executed runtime results.

| Existing component | What to retain and what to address |
|---|---|
| [GuidedSearchView.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/GuidedSearchView.swift) | Already offers sender, recipient, subject, dates, phrase, any/none words, attachment name, source and tag inputs. Extend this form. Its composer only adds excluded words when positive free text exists; a sender/subject-only search can therefore leave a populated exclusion unused. Make every visible condition executable or visibly invalid. |
| [ArchiveQueryCompiler.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/ArchiveQueryCompiler.swift) and [EmailRepository.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/EmailRepository.swift) | Existing operator parsing, `EmailQuery`, structured fields and paginated execution are the starting point. Repeated scalar operators currently assign the same field again; grouped conditions need a representation that preserves every condition rather than overwriting one. |
| [FTSSearchIndex.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/FTSSearchIndex.swift) | Reuse indexing, sharding, reconciliation and ranked pagination where correct. The current free-text builder splits on whitespace and adds a prefix to its last term. Verify/rework phrase, grouping and literal-input semantics; do not assume the UI's wording already matches execution. |
| [SearchMatchFields.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/SearchMatchFields.swift) and [SearchMatchFieldChips.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/SearchMatchFieldChips.swift) | Retain the useful match-label interface. Replace heuristic attribution, including the fallback that labels an unexplained free-text result as Body. Retrieve the actual matching field/document/chunk instead. |
| [SearchCoverage.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/SearchCoverage.swift) and [SearchCoverageBadge.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/SearchCoverageBadge.swift) | Coverage UI already exists. Extend it to relevant message fields and attachments, selected scope and extractor versions. Failed counter reads currently become zero or no badge in these paths; failure must become “Coverage unavailable,” never a complete-looking result. Collapsing details must retain the incomplete-status indicator. |
| [AttachmentTextIndexJob.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/AttachmentTextIndexJob.swift) | Extend the existing job with required Office extraction, OCR, durable per-item states and complete chunked indexing. A new query interface alone cannot expose text absent from the index. |
| [ArchiveDataService.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/ArchiveDataService.swift) and [ArchiveListViewModel.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailin/ArchiveListViewModel.swift) | Keep central access scope, list paging and query-revision handling. New conditions must use the same archive service and adopted entitlement policy, with no parallel access path or revival of superseded numeric trial limits. |

**Scope decision:** no raw SQL console, natural-language-to-SQL dependency, new AI model project or cloud search service for this release. Existing optional AI remains separate and retains customer commitments. Core search must pass with AI disabled and without network access. This does not disable on-device OCR needed for attachment search.

#### 5.3.2 The seven implementation requirements

These remain the same seven FIND identifiers; the following detail is their implementation specification, not a separate product backlog. “Fix” and “Complete or verify” describe the reviewed baseline, not completed work.

| ID | Status | Required work |
|---|---|---|
| FIND-01 | Fix and expand | Complete all required attachment extractors and section-depth contracts in section 4.2, including old/new Office variants, OpenDocument/iWork, supported embedded mail/documents, nested container contents and credential-based processing. Store full extracted text with stable parent/child identity, engine version and actual page/sheet/cell/slide/section context. See section 13 for implementation options and acceptance cases. Never execute macros, formulas, queries or remote content. |
| FIND-02 | Fix | Connect OCR for supported JPEG/PNG/TIFF and scanned PDF pages to ordinary search. Process mixed text/scan PDFs without duplicating equivalent text; label OCR results, record language/model revision where available and retain original bytes. Test actual advertised languages/image classes. |
| FIND-03 | Fix | Persist honest processing/coverage states per message field and attachment, including queued, running, text extracted, processed with no text found, unsupported, locked, failed, cancelled, paused, partial and stale. Show scope-relevant coverage and recovery actions. A missing counter or failed coverage query is unknown, not zero. |
| FIND-04 | Complete or verify | Extend the existing guided form into the visual advanced search builder specified below. Support field filters, all/any/exclude conditions, clear source/folder scope, active editable filters, defined dates and attachment predicates through one validated query model. All visible conditions must reach execution. |
| FIND-05 | Fix | Return actual match evidence: field/section, matched condition, parent message, exact attachment/member identity and available location/snippet. Open the matching document, including nested children, at a real location or an accurately labelled extracted-content anchor. Remove invented Body attribution. Filter-only results explain passed filters without inventing a text hit. |
| FIND-06 | Complete or verify | Keep extraction and queries bounded, cancellable and recoverable. Validate typed conditions, bind SQL values, safely compile text expressions and retain central scope enforcement. Enforce resource budgets visibly; never substitute a bounded first-page scan for complete search. |
| FIND-07 | Fix | Replace permanent prefix-only indexing with complete logical-document/chunk indexing for supported message and attachment text. Remove the 500,000-character attachment cutoff and former body cutoff. Verify phrase matches across chunk boundaries without matching across unrelated documents, attachments or messages. |

#### 5.3.3 What the user sees

**Simple search:** one familiar search box, Search/Return action, current source/folder scope and an Advanced Search button. Ordinary text is treated as user text, not SQL or implicit Boolean commands. Existing expert operator syntax remains available through an explicit compatible syntax path; display its recognised filters. Preserve existing saved queries, but do not silently reinterpret an old advanced query as a different simple query.

**Advanced Search:** open the existing guided sheet/panel with the current query populated. Use normal labels, date pickers and source/folder selectors. The form offers “Match all,” “Match any” and “Exclude” condition groups. An empty group has no effect. The group structure and a plain-language summary make the effective logic visible; multiple populated groups combine with AND. Exclude means none of the excluded conditions may match. If nested groups are exposed, preserve their structure explicitly in the query model and summary.

| Field/control | Required behavior |
|---|---|
| Sources and folders | Select exact source/folder identities from the existing complete hierarchy. Keep identical names in different sources distinguishable; nested-folder inclusion is explicit. Do not use a source filename substring as a substitute for a folder selection. |
| Sender and recipients | Search names or addresses with a labelled matching mode. Support any recipient and, where data is available, To/Cc/Bcc selection. Retain original header values; an unavailable Bcc field must not be invented. |
| Subject and message body | Offer word/phrase conditions with defined behavior. Search the whole supported body, including content beyond former indexing limits. |
| Message date | Show the date basis and time zone. Use “On or after” and “On or before” calendar dates with inclusive user-facing boundaries. Define behavior for missing/invalid dates; never silently replace sent date with import date. |
| Has attachments | Any / Yes / No, so an unchecked toggle cannot ambiguously mean either Any or No. |
| Attachment name | Match the original filename using a labelled text rule, including repeated names, Unicode and punctuation. |
| Attachment type | Choose a declared file-type/MIME classification. Treat a filename extension as supporting metadata, not proof of file contents; disclose unknown/conflicting classification where relevant. |
| Attachment content | Search extracted/OCR text separately from the filename. Type/name/content conditions inside one attachment group apply to the same attachment. |
| Tags/labels and existing filters | Retain currently supported non-AI filters and original source memberships. Do not add new analytics fields to deliver this builder. |
| Sort | Keep useful existing sorts and stable pagination. Relevance may be used for text searches; a filter-only query uses a clearly stated order. |

The basic form should cover common work without requiring nested expressions or operator knowledge. Complex conditions that cannot be represented in the current form must remain visibly represented in an advanced condition view, or require explicit editing; opening the builder must never discard them.

**Active filters:** show removable/editable chips for the applied conditions and a separate visible scope indicator. Preserve group meaning when summarising chips: a row of flat chips must not hide whether conditions are AND, OR or excluded. Removing a chip reruns the resulting query; Cancel in the editor leaves the applied query unchanged. “Clear filters” clears conditions while retaining the visibly selected archive/folder scope; “Search all sources” is a separate deliberate action. Prevent a stale result from a cancelled query replacing the latest results.

**Example — a document inside an email:**

| User selection | Value |
|---|---|
| Source | Work archive |
| Sender | supplier@example.com |
| Date | 1 January through 31 March 2026, displayed time zone |
| One attachment group | Type is PDF **and** content contains the phrase “purchase order” |
| Exclude | Subject contains newsletter |

Expected result: a message whose qualifying PDF actually contains the phrase. A message with an unrelated PDF plus a DOCX containing the phrase must not pass that attachment group. The result shows the matching PDF and available page context; its parent email opens directly.

**Empty states:** distinguish “No matches in the fully indexed searchable scope,” “No matches found yet; indexing is incomplete,” “Search failed” and “Some conditions could not be evaluated.” Never show an indexing failure as an ordinary empty archive. “Fully indexed” describes coverage of the declared search representation, not guaranteed perfect OCR recognition or support for arbitrary attachment types.

#### 5.3.4 One query model, with explicit meaning

Extend the existing structured query and repository rather than building another search engine. Use a typed expression representation for fields, operators, values and groups; the builder must not depend on concatenating a display string and hoping it reparses identically. An expression tree is an implementation option, not a new user-facing concept.

The same validated model must drive the applied chips, plain-language summary, query execution, coverage scope, match explanations, count calculation and the existing export-selection handoff. Keep a versioned representation for compatibility with existing saved queries. Code names for any new internal types are implementation choices.

Required rules:

1. **Scope is enforced outside user Boolean groups.** Archive/source access, selected folder membership, trash visibility and adopted entitlement restrictions apply to all branches of an OR or exclusion. Apply the same scope to rows, counts, snippets, attachment opening and exports. Do not change pricing/access policy as part of this work.
2. **Preserve every condition.** Multiple sender conditions must remain multiple conditions with the selected grouping. Reject invalid dates/operators inline; never run a different query by dropping an unsupported condition. Empty search with no filters returns ordinary browsing.
3. **Define the search unit.** Default rows represent stored message identities and retain source occurrences; search does not perform deduplication. Multiple matching chunks or attachments do not multiply one message into unexplained duplicate rows. A match drawer/list may show each attachment separately.
4. **Correlate attachment conditions.** Type, filename and content in one attachment group must match one attachment ID. For a positive group, one qualifying attachment is enough. For an excluded attachment group, no qualifying attachment may match; incomplete relevant attachments can leave that test unknown.
5. **Define text semantics.** Separate ordinary words from phrase mode and deliberate expert syntax. A phrase must occur in order in the same logical text document. All words in an attachment-content condition may span chunks of that attachment, but cannot be assembled from different attachments. General “anywhere in this message” word searches may use the declared message-plus-attachment scope; label that scope.
6. **Do not call a stemmed/prefix result exact.** Decide and test case, accent, word-boundary, punctuation and normalisation behavior for English, Bengali and Hindi. Keep original text for rendering. Automatic prefix/stemming must not silently change an explicit literal or phrase condition. If tokenisation loses meaningful punctuation, use verified candidate matching or a bounded, cancellable fallback for the promised mode; do not silently return a different meaning. Phrase wording must state whether it uses token adjacency or literal substring equality.
7. **Use correct date boundaries.** Convert the chosen start day and the start of the day after the chosen end into the displayed time zone's instants; use an inclusive start and exclusive end internally. Preserve original date/time-zone evidence. Test daylight-saving boundaries and missing dates.
8. **Keep negative conditions honest.** “Text does not contain X” is established only when the relevant content has been evaluated sufficiently to rule out X under the declared matching rules. A positive hit can establish a match before all unrelated content finishes indexing; a missing hit in incomplete content cannot establish absence.
9. **Use three outcomes for uncertain conditions:** match, no match, and not yet evaluable. NOT of an unknown condition remains unknown. An ALL group is false if any member is false, true if all are true, otherwise unknown. An ANY group is true if any member is true, false if all are false, otherwise unknown. Use these rules for unsupported, locked, stale or unfinished relevant content rather than treating missing index rows as negative evidence.
10. **Expose confirmed matches and unresolved coverage separately.** Do not present unresolved exclusions as confirmed matches. State when more results may appear after indexing. Count at message level; label unfinished counts “matches found so far” or “counting” instead of presenting a final total. For metadata-only queries, unrelated attachment indexing does not make the metadata query incomplete.
11. **Handle concurrent work.** Capture query identity and scope/index generation for paging. Do not mix pages or explanations from different queries. When new imports/indexing change results, show an update state and refresh consistently; use the existing stable-selection contract for export. Do not hold a long database snapshot that causes unbounded journal growth merely to keep the screen stable.

**Query safety and responsiveness:** SQL structure, columns and operators come from an allowlist; bind all user values. Escape literal text for the text-search grammar separately—parameter binding does not itself prevent text from being interpreted as search operators. Preserve existing scope enforcement rather than allowing direct user SQL. Use indexed metadata filters, bounded pages and streaming set operations; do not materialise all matching IDs or full message bodies in RAM. An explicit content verifier may stream candidate content, but must not operate only on visible rows. Cancellation must target the requesting query without aborting an unrelated import.

SQLite documents bound parameters and interruptible progress callbacks; use the appropriate mechanisms through the existing repository/connection ownership. These are implementation building blocks, not evidence that mailin already implements every rule above. [SQLite parameters](https://www.sqlite.org/c3ref/bind_blob.html) · [SQLite progress callbacks](https://www.sqlite.org/c3ref/progress_handler.html)

#### 5.3.5 Extraction, complete indexing and safe migration

Use existing tables/jobs where sound. The following are required data relationships, not a demand for a second database or a wholesale schema rewrite.

| Record/relationship | Information needed |
|---|---|
| Searchable document | Stable message/attachment/MIME-part identity, parent relationship, field kind, source identity and original content revision/hash |
| Text chunks | Document ID, chunk order, complete searchable text, global positions/offsets and available page/sheet/slide/section context; distinguish extracted text from OCR |
| Processing state | Extractor/OCR/tokeniser revision, attempted/completed revision, queued/running/final state, processed units/known totals, failure reason and retry/checkpoint information |
| Search generation | Query/scope identity and index revision sufficient to prevent stale result, count or cursor reuse |
| Match evidence | Matched clause, document/field, relevant span and parent/attachment location; enough to explain the actual result |

**FIND-01:** DOCX extraction should address the agreed text-bearing components, including main body/tables and available headers, footers, notes and text boxes. XLSX needs sheet identity and stored cell values/shared strings; distinguish formula text and stored results without evaluating formulas. PPTX needs slide text/tables and supported speaker-note text with location labels. Inventory known skipped text-bearing components and keep coverage partial where the promised component scope was not completed. Do not infer support for DOC/XLS/PPT, macros or embedded binary objects from DOCX/XLSX/PPTX support.

**FIND-02:** detect text-bearing versus image-only PDF pages; use OCR where required and supported. Keep OCR text separate from source bytes and record actual runtime language availability. A processed OCR page may still have recognition errors; execution coverage and recognition accuracy are different measurements. If exact image highlight coordinates are unavailable, show a labelled recognised-text snippet/page instead of fabricating a box. Reuse existing OCR services if suitable. [Apple Vision](https://developer.apple.com/documentation/vision/recognizing-text-in-images?changes=_9)

**FIND-07:** chunking is a work/memory boundary, never a permanent content cutoff. Preserve token/Unicode boundaries and logical document order. Find words at document ends and phrases crossing chunks. Fixed overlap alone is insufficient for an arbitrarily longer phrase: use positions or a streamed adjacent-chunk verification path that cannot prefilter the true match away. Do not allow phrases to bridge two attachments or two messages. No normal required-format item may finish as fully indexed while a known text tail remains unprocessed.

**Atomicity and resume:** publish a completed document revision only when its required chunks and state agree. Partial indexing may return confirmed hits if labelled; unfinished content remains visible. Stop obsolete jobs from publishing over a changed source/attachment revision. Keep query results tied to the correct content generation. Extracted/indexed data must not outlive a deleted parent incorrectly, and cleanup must not invalidate active jobs.

**Migration:** add compatible schema/index revisions and run resumable backfill over existing archives. Do not require reimporting all mail merely to obtain newly supported extraction. Reuse available original/managed bytes and the existing missing-source/relink behavior. Preflight additional disk space; preserve a working old index where safe while labelling stale/incomplete coverage until replacement is ready. Interrupted migration/backfill must resume without duplicate documents. Test current archives, professional records, holds and saved queries through upgrade.

**FIND-06:** use bounded memory, task concurrency, decompression/nesting limits and cancellable time budgets. Resource-paused, locked, unsupported or failed items remain visible with actionable next steps. A guard stopping an extraction cannot count as successful full processing. The required attachment families and processing depth are the expanded contract in sections 4 and 13; resource safety does not defer those extractors.

SQLite FTS5 provides phrase/Boolean querying and snippet/highlight primitives. The document/chunk relationships, coverage rules and cross-boundary correctness above are mailin requirements to implement and test, not automatic guarantees supplied by the engine. [SQLite FTS5](https://sqlite.org/fts5.html)

#### 5.3.6 Match explanations and indexing disclosure

**For each result, show enough to answer “Why is this here?”**

- Label the actual matched field: Subject, Message body, Attachment filename, Attachment text or OCR text. Display other satisfied metadata filters separately.
- Include a short safely rendered snippet from the matching text and highlight actual spans. Do not highlight excluded words or a condition that did not contribute to the successful OR branch.
- For an attachment, show its name, parent message and available page/sheet/slide/section. Distinguish two attachments with the same filename by stable identity and context.
- Open the matching attachment/location where supported, with a reliable route to its parent email and source folder. If a precise location cannot be shown, say so and still open the correct document.
- A filter-only result can say “Matches sender and date filters.” It must not fabricate a text highlight. If stored match evidence is unavailable, show an explanation-unavailable state and recover it; never guess Body.
- Render snippets as escaped/attributed text. Keep safe-viewer protections; a highlighted HTML fragment must not activate script, macros, tracking URLs or remote images.

**Coverage is a property of the current query and scope.** Reuse the current coverage UI, adding the relevant body/attachment states. Keep the summary available above both results and empty states, with a detail action and per-item status. Do not put it behind the AI or Professional module.

| Coverage state | User-facing meaning and action |
|---|---|
| Complete for the declared searchable scope | All required processing for this query's relevant content has finished. No unsupported/blocked part is silently counted as searched. OCR accuracy remains separately qualified. |
| Queued / indexing | Show known processed/remaining counts and the affected scope; search confirmed indexed content now. If the denominator is unknown, show activity/counts rather than an invented percentage. |
| Partial / stale / resource-paused | Explain that some content or a newer revision remains unsearched; offer Resume/Retry or rebuild actions appropriate to the cause. |
| Processed with no text found | Explain that the extractor/OCR returned no text, not that the file is empty or proves the absence of all human-readable content. |
| Unsupported | Retain filename/metadata search and original-file access; identify that internal contents are not searchable with current support. |
| Locked / missing source / failed / cancelled | Identify affected items, retain the reason and offer supported actions such as Reconnect, Retry or Resume. Do not imply the app can decrypt every protected format. |
| Coverage unavailable | Show that completeness could not be checked, with Retry/details. Never convert the error into zero pending items or suppress the warning. |

Counts must refer to the selected source/folder/access scope or clearly label a broader denominator when exact query-specific coverage cannot yet be calculated. For complex Boolean queries, do not pretend a simple global percentage is exact query coverage. Relevant unknown parts make absence/exclusion conclusions uncertain under section 5.3.4.

Use stage-specific wording such as “Messages imported; attachment indexing continues.” A small persistent incomplete-state indicator remains even if the user collapses details. Errors describe what is safe and the next action. Add VoiceOver labels and keyboard focus behavior for chips, groups, highlights, coverage and recovery actions; help cannot depend on hovering or colour alone.

#### 5.3.7 Implementation sequence within FIND-01–07

| Step | Work and existing components | Exit evidence |
|---|---|---|
| 1. Define the executable contract | Reconcile actual branch; inventory query fields and source/attachment identities. Write fixtures for date boundaries, grouping, exclusions and same-attachment matching. Extend existing query/repository types only as needed. | Every form condition has a defined execution rule, coverage requirement and expected test result. |
| 2. Make execution and state truthful | Update query compiler, repository/FTS paths, central scope and coverage models. Fix dropped conditions, exclusion-only behavior, failed coverage counters and stale-query replacement. | Query conditions are preserved; no scope escape or complete-looking error state; tests pass with AI off. |
| 3. Complete the searchable corpus | Implement required Office extraction/OCR, per-item state/versioning, full chunk indexing and resumable backfill. Work on small real fixtures before scale tiers. | Required supported text, document tails and cross-chunk phrases are found with correct parent identity and honest OCR/unsupported states. |
| 4. Finish the builder and active filters | Extend GuidedSearchView and list integration; bind form, chips, summary and execution to one model. Preserve existing expert queries and saved-query compatibility. | Apply, Cancel, edit, remove and clear operations change exactly the intended query; keyboard/VoiceOver flows work. |
| 5. Return evidence with every match | Extend result records and match-field UI; retrieve actual spans/locations, apply safe highlights and open correct attachments. | Every highlighted/labelled hit is supported by executed-query evidence; repeated names and filter-only searches are correct. |
| 6. Verify migration, scale and user success | Exercise the acceptance matrix below, existing search regression suites, real formats and master-plan benchmarks. Test offline/AI-disabled use, interruption, upgrade and existing export handoff. | All FIND requirements have candidate-specific evidence and no search-caused regression in the other four workflows. |

Reuse and extend the existing [V2SearchTests.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailinTests/V2SearchTests.swift) and [SearchMatchFieldsTests.swift](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/maxmailinTests/SearchMatchFieldsTests.swift) where applicable. Add integration/UI tests for behavior the unit suites cannot establish. These are proposed execution steps; this planning update did not run the app or its tests.

#### 5.3.8 Required acceptance cases

These are test cases attached to the existing FIND IDs, not extra release-scope identifiers. Expected result IDs and content locations must come from independently constructed fixtures or a trusted independent oracle, not from the same search implementation being tested.

| Case | Requirement mapping | Pass condition |
|---|---|---|
| Basic text and field filtering | FIND-04 | Simple and builder queries with equivalent declared semantics return the same expected message set across the full selected archive. |
| Group logic and repeated fields | FIND-04 | All/Any/Exclude combinations, repeated senders and parentheses/group boundaries preserve meaning. No condition is overwritten or ignored. |
| Exclusion with no positive text | FIND-03/04 | Sender/date/subject-only filters plus an exclusion work. An exclusion-only query uses the scoped universe and does not drop the exclusion or admit unknown content as verified absence. |
| Incomplete negative evidence | FIND-03/04 | Locked, unsupported, stale and not-yet-indexed relevant text produce unknown exclusion outcomes. Completing indexing updates the confirmed result set correctly. |
| Scope protection | FIND-04/06 | OR, exclusion and text-only queries cannot escape selected sources/folders, trash rules or adopted access scope; counts/snippets/open/export agree. |
| Same-attachment correlation | FIND-04/05 | A PDF plus an unrelated DOCX containing the term fails a PDF-content group; a matching PDF passes. One message with several hits is not accidentally multiplied. |
| Dates and missing metadata | FIND-04 | End-date inclusivity, time zones, daylight-saving transitions and missing dates match the documented rule. Absent Bcc is not fabricated. |
| Punctuation and deliberate syntax | FIND-04/06 | Quotes, apostrophes, parentheses, colons, percent/underscore characters, paths and SQL-looking input cannot change query structure or cause silent broadening. Test meaningful punctuation such as C++ and invoice identifiers under the declared matching mode. |
| Phrase correctness | FIND-04/07 | Ordered phrase, nonadjacent words, stemming/prefix differences and reversed words are distinguished according to the stated mode. A phrase never bridges unrelated attachments/messages. |
| Required extraction types | FIND-01 | Known strings appearing only inside each required supported attachment type are found with correct parent and available component context. |
| Scans and mixed PDFs | FIND-02/05 | OCR hits reach ordinary search, open the correct page/document and are labelled. No duplicate equivalent hit is caused by both OCR and embedded text; measured OCR failures remain visible. |
| Languages and Unicode | FIND-01/02/04/07 | English, Bengali and Hindi extracted text pass deterministic fixtures; OCR language coverage is tested separately. Combining marks and chunk boundaries do not corrupt matching or highlight ranges. |
| Former cutoffs and long phrases | FIND-07 | Targets beyond 500,000 attachment characters, the former body budget and cross-chunk boundaries are found. A phrase longer than the chosen overlap still works. Large source-locator messages participate once their content is processed. |
| Match explanation truth | FIND-05 | Attachment-only, body-only, subject-only, metadata-only and OR-branch cases name actual evidence; no unexplained hit is guessed to be Body. Excluded words are not highlighted as reasons for inclusion. |
| Repeated names and navigation | FIND-05 | Two same-named attachments and same-named folders in different sources open the right identities; highlights/snippets correspond to the selected result. |
| Safe rendering | FIND-05/06 | HTML/script-like content stays inert in snippets and previews; highlights do not fetch remote resources or execute embedded content. |
| Coverage/error states | FIND-03 | Pending, no-text, unsupported, failed, locked, stale, cancelled and unavailable coverage are visibly distinct. Counter errors cannot yield “complete” or a misleading ordinary zero-result screen. |
| Query-relevant coverage | FIND-03/04 | A metadata-only query remains complete when its metadata is complete despite unrelated attachment jobs; attachment-content queries disclose the relevant gaps and denominator. |
| Paging, count and cancellation | FIND-04/06 | Every expected match is reachable without hidden first-N truncation; paging/counts agree at a stable generation. Cancelling an old query cannot replace new results or abort an unrelated import. |
| Upgrade and backfill | FIND-01/02/03/07 | Existing archives and saved queries remain usable; interrupted reindexing resumes without duplicate parts, lost originals or false full-coverage states. |
| Scale and responsiveness | FIND-04/06/07 | Run the master's declared datasets/hardware, record p95 warm search and cold/background performance, peak memory and index disk cost. Existing performance targets remain targets until measured; heavy fallbacks show cancellable progress. |
| AI independence and privacy | FIND-01–07 | All core cases pass offline with AI disabled; there is no model/network dependency and no message/attachment/query-text telemetry introduced. |
| Existing export handoff | FIND-04/05 | Export receives the intended stable message selection, with known search incompleteness disclosed. Exporting all found rows does not imply the search found every possible match. Existing OUT requirements remain unchanged. |
| User task | FIND-03/04/05 | Representative users build the supplied sender/date/PDF-content search, edit/remove a filter, open the correct attachment and recognise a deliberately incomplete search without developer coaching. Use the master's pilot target; fix misleading or destructive outcomes. |

#### 5.3.9 Completion and boundaries

Search is complete for this release only when all seven FIND rows have executed evidence tied to the actual candidate, the required supported content is searchable in full, every applied condition is honoured, match explanations are grounded and incomplete coverage remains visible. Test AI-disabled operation, compatibility with existing queries and the other four archive workflows. Source code presence, a successful compile or a demonstration on a few messages is insufficient.

Deliver within the existing master-plan release package:

1. Updated guided form, active filters, query model/compiler and repository integration.
2. Required extractors/OCR integration, versioned coverage states and complete resumable indexing/backfill.
3. Evidence-backed result explanations, safe highlights and correct parent/attachment navigation.
4. Automated/integration/UI results for the acceptance cases, measured scale evidence, and any remaining blocker.
5. Updated in-app search help and advertised coverage consistent with the tested implementation.

**Later:** new saved-search management, search-within-results, a separate attachment-only browser, typo/synonym expansion and optional natural-language assistance. Retain existing working features. The named document formats and compressed-attachment search in section 4.2 are now required under the 6 November expansion. Raw SQL editing and AI-generated SQL are not required.

The earlier Advanced Search amendment expanded FIND-04 and its FIND-01–07 dependencies without adding formats. The later 6 November Outlook/Office decision explicitly broadens the format and acceptance contracts in sections 4 and 13 across the same five jobs. The 30 core IDs, six LIFE checks and ten gates remain; AI/analytics expansion remains excluded.

### 5.4. Identify duplicates without losing information

**Customer outcome:** “Show me repeated copies without hiding a different version or losing where a message came from.”

| ID | Status | Required work |
|---|---|---|
| DUP-01 | Fix | Stop presenting Message-ID-only or truncated-body matches as proven identical copies. Relabel them as candidates until complete comparison is available. Do not permit an unverified candidate group to drive bulk permanent removal. |
| DUP-02 | Fix | Remove the 5,000-message bound from complete-archive content analysis using a cancellable, resumable indexed job. Surface scan errors instead of converting a partial stream into a complete-looking result. Before release, whole-scope scanning must pass; a truthful temporary warning alone does not close this requirement. |
| DUP-03 | Fix | Separate byte-identical copies, explicitly defined content-equivalent copies, similar messages and unresolved candidates. Use complete bodies, relevant headers, MIME structure and attachment bytes/metadata for the appropriate class. Message-ID is one clue, not the full comparison. |
| DUP-04 | Complete or verify | Preserve every source occurrence, folder membership, annotation and hold. Start with grouping or hiding repeated display entries. Storage consolidation and record deletion are separate actions and must not be confused. |
| DUP-05 | Complete or verify | Provide differences, a survivor preview, recoverable removal and a durable change receipt. Do not modify original archive files. Respect legal holds even when the Professional interface is disabled. Estimate reclaimable physical bytes honestly: hidden rows do not necessarily free space. |

For a byte-identical classification, compare available original message bytes using a modern digest such as SHA-256 and confirm equality before destructive consolidation. Where a proprietary format does not provide original RFC message bytes, name the compared representation and its limits; a generated EML does not become the original source. A normalised fingerprint is useful for candidate grouping, but differences excluded by normalisation still need to be retained and explained.

RFC 5322 describes Message-ID as a message identifier and explicitly permits certain added transport/resent headers without changing it. Thus even valid same-ID occurrences need not have identical bytes. The classification and cleanup rules above are product recommendations based on that distinction. [RFC 5322 §3.6.4](https://www.rfc-editor.org/rfc/rfc5322.html#section-3.6.4)

**Later:** duplicate-attachment storage consolidation, repeated-import detection, cross-archive comparison and near-duplicate review. Introduce shared attachment storage only with tested references, backup, deletion and migration behavior.

**Acceptance:** the adversarial fixture set must produce no false “identical” classifications for same-ID/different-attachment, same-prefix/different-body, missing-ID or changed-header cases. True identical copies beyond item 5,000 are found. Undo restores memberships and annotations. No source archive is edited.

### 5.5. Verify exports from selection to destination

**Customer outcome:** “I can use the exported mail elsewhere and see exactly what was preserved or omitted.”

| ID | Status | Required work |
|---|---|---|
| OUT-01 | Complete or verify | Offer clear mail-preserving EML/MBOX/PST/MSG choices according to the verified writer matrix, original-attachment output, full preservation backup, and human-readable reports. Explain that PDF/CSV reports are not automatically restorable mail archives. Complete the required Outlook export route; do not list unverified writers as supported. |
| OUT-02 | Complete or verify | Snapshot the selected messages and memberships before writing. Exporting a filtered view must not drift because background import/search changes. Let users decide whether the export includes unique messages or each folder occurrence and disclose any intentional duplication. |
| OUT-03 | Complete or verify | Preserve supported headers, bodies, inline MIME parts, attachments, names and source/folder mapping. Record format-induced changes and omissions. Verify decoded attachment bytes, not filenames alone. |
| OUT-04 | Complete or verify | Extend existing receipts/manifests into a clear reconciliation of selected, written, checked, excluded and failed items. Reopen/reparse all outputs for a full-verification status; a sampled check must say sampled. Verify exported payload against source records as well as output-file integrity. |
| OUT-05 | Complete or verify | Exercise destination compatibility in appropriate actual versions of Windows/Mac Outlook for the promised PST/MSG route, and Apple Mail/Thunderbird for the declared EML/MBOX route. An independent reader or known fixture oracle must prevent a shared importer/exporter bug from validating itself. Record exact versions, import steps, field mapping, folders and attachment reconciliation. |
| OUT-06 | Complete or verify | Make cancellation, full disk, partial output and resumable jobs explicit. Use a partial-work area and finalise only after the chosen checks pass. Resume must validate existing files and never overwrite unrelated output. |
| OUT-07 | Fix | Preserve a final per-file verification inventory instead of deleting all per-file hashes after successful folder export. Finalise the resume journal into a durable portable manifest linking output files to source records, selection identity, attachment checks and any transformations. A successful write or unchanged file hash alone must not imply semantic reconciliation. |

Apple Mail documents MBOX import and export, making it a sensible first concrete destination to verify. This does not imply mailin already produces compatible output or that every original label maps perfectly into MBOX. [Apple Mail import/export](https://support.apple.com/en-gb/guide/mail/mlhlp1030/16.0/mac/27)

Expose verification as separate questions: “Were files written?”, “Do their bytes match the recorded output hashes?”, “Does their content reconcile to the selection?”, and “Was this format tested in the intended reader?” The interface can summarise these without making users inspect technical details. A successful export does not certify authenticity, legal admissibility, or recoverability in every email application.

**Later:** additional destination presets and a standalone verifier that can check output without purchasing mailin. Retain and test existing partitioned-export support; final verification inventories are required now under OUT-07. Treat an independent verifier as a trust feature, not a claim of third-party certification.

**Acceptance:** export a folder, a filtered search and selected messages; independently reconcile message identities, membership mapping and attachment contents. Re-import and open representative outputs in the stated destination application. Introduce a modified/missing output file and confirm verification fails. Export a partial source and preserve that limitation in the receipt.

## 6. Six acceptance checks spanning the five jobs

These are required acceptance conditions within the five workstreams. Source-independent preservation and whole-archive backup/restore receive explicit treatment. Except for the documented source-reference dependency below, these are requirements to verify, not newly proven defects in the current app.

| Check | Requirement and acceptance evidence |
|---|---|
| LIFE-01: self-contained preservation | Offer a clearly identified self-contained archive mode that copies and verifies all required source/message/attachment bytes into managed storage. A separate linked-source mode may save space but must explain its dependency before import. For the self-contained test, detach the original test source, restart and read/search/export every expected message, including deferred large messages. Linked mode must detect a missing or changed source, show affected items and support verified relinking; it cannot claim to be an independent backup. |
| LIFE-02: full backup, restore and migration | Back up a consistent archive state including database, external blobs, source copies or an explicit linked-source inventory, folder memberships, annotations, holds, job state and verification records. Rebuildable indexes may be omitted if their rebuild and coverage states are tested. Restore on a clean device/user profile without relying on the old machine's paths or caches. Define encrypted-backup/key recovery and receipt-signature portability honestly; a device-key mismatch is not proof that content was altered. Exercise schema upgrades and recovery from a failed upgrade using a known-good backup. |
| LIFE-03: field-level fidelity and consistent jobs | Maintain a named field contract covering available From/To/Cc/Bcc, original and normalised dates/time zones, Message-ID/thread headers, MIME bodies, inline Content-ID links, attachments, original filenames, folder memberships and supported flags. Preserve originals alongside normalised search representations; disclose absent or transformed fields. Test two simultaneous jobs and an import running during search, duplicate review and export. Stable selections and post-run counts must reconcile, and deletion/cleanup must not invalidate another job's inputs. |
| LIFE-04: privacy and safe handling across the entire archive | Verify the actual protection of databases, search/OCR indexes, blobs, previews, temporary extraction files, backups and logs. Document encryption and key behavior rather than treating local processing as sufficient proof of protection. Default previews must not execute scripts/macros or fetch tracking resources; opening external content is explicit. Test malformed MIME, decompression/path attacks and bounded extraction. Diagnostic exports are user-reviewed and omit message bodies, attachments and identifying metadata by default. |
| LIFE-05: usable recovery and assistance | Provide a short first-import guide, a sample archive, contextual help, keyboard/VoiceOver support and clear recovery actions such as Reconnect, Retry failed items, Rebuild index and Restore backup where applicable. Show the job's scope, stage and remaining work; do not present a frozen estimate as certainty. Errors should explain what happened, what data is safe and the next useful action. Include these states in the existing usability pilot; a long onboarding carousel is not required. |
| LIFE-06: ownership and access policy | **Owner adopted the recommended policy on 6 November 2026:** keep reading and basic portability export of already imported data available after subscription expiry; new paid work remains governed by the plan. Imported data must never be automatically deleted because an entitlement changes. Define and test reading, searching, new imports, exports, offline entitlement checks, expiry, refund and purchase restoration separately using section 12.2. The policy decision is closed; implementation and verification remain required. Preserve existing prices, trial rules and purchased/lifetime rights. |

**Why LIFE-01 matters now:** the reviewed format document says oversized messages can retain byte locators into the original source, and that those originals are referenced rather than copied. The source-independent archive test therefore covers a real documented dependency. [Source-reference behavior](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/SUPPORTED_FORMATS_AND_LIMITS.md#L126)

**Backup implementation constraint:** use a database-supported snapshot strategy and coordinate it with the external blob/source inventory. SQLite documents incremental online backups and the relationship between the database and its WAL; copying an active main database file alone is not a sufficient whole-app backup design. This requirement does not mandate one particular library. [SQLite backup](https://www.sqlite.org/backup.html) · [SQLite WAL](https://www.sqlite.org/wal.html)

**One combined preservation test:** import a representative archive into self-contained mode; verify counts/content; detach the original test source; restart; find a document inside an attachment; identify a changed version correctly; create a backup; restore it in a clean profile/device; rebuild its index if needed; then export and independently verify the selected mail. Repeat key stages around an interrupted job and an app upgrade. Use disposable test sources, never remove the owner's real source archive as part of testing.

Each LIFE check needs evidence on the same release candidate as the 30 core work items. Existing working behavior may satisfy a check after execution; there is no requirement to rewrite passing code.

### 6.1 Supporting help and access deliverables

Keep help attached to the task: a first-import quick start, a sample archive, a searchable guide covering the five jobs and format states, and contextual explanations for incomplete search, duplicate classes and export verification. Hover text supplements clear labels; it cannot be the only instruction available to keyboard, touch or VoiceOver users. A carousel is optional and skippable, not a release goal by itself.

For LIFE-06, maintain one tested capability table covering reading, search, import, export and recovery under active entitlement, trial, offline use, expiry, refund and restored purchase. Preserve data in every state. The owner has adopted post-expiry reading/basic-export access. Apply the implementation defaults and tests in section 12.2; adoption is not evidence that the app has been changed or the tests passed.

## 7. Delivery sequence and dependencies

| Stage | Work | Exit evidence |
|---|---|---|
| 0. Establish the real baseline | Identify release source/build, preserve local work, inventory advertised capabilities and create the requirement/format matrices | Every finding is reconciled with the actual candidate; no old branch or website version is mistaken for the shipped source |
| A. Correct misleading and unsafe behavior | DUP-01; FOLD-01; FIND-03; truthful import/search/export completion and scope labels | Candidate matches cannot drive unsafe permanent cleanup; all folders are reachable; failures cannot appear as full success |
| B. Make preservation and jobs reliable | Source/occurrence identity, bounded parsing, source-change checks, import checkpoints, stable export selections; LIFE-01, LIFE-02 and LIFE-03 | Self-contained data survives source detachment; interrupted jobs recover; whole-archive restore and migration preserve counts, content and relationships |
| C. Complete retrieval and duplicate analysis | FIND-01/02/04/05/06/07, complete DUP-02/03/04/05; required formats exercised throughout | Known content is found across supported formats, former cutoffs are gone, full-scope scans finish and changed versions remain distinct |
| D. Prove output and portability | OUT-01 through OUT-07, folder-aware output, original attachments, final inventory and independent destination checks | The complete selection reconciles and usable output survives cancellation, resume and tamper checks |
| E. Finish customer experience and release evidence | LIFE-04/05/06, final privacy/entitlement regression, help, real-user pilot, platform tests and claim reconciliation | All ten gates pass on the release candidate, with unresolved findings visible and the customer-facing scope matching the evidence |

Stages are dependencies, not calendar promises. Privacy, safe handling, accessibility and data integrity apply throughout; final-stage testing must not postpone their design. Small independent fixes may proceed together. Reuse passing components and avoid a broad rewrite solely to satisfy the plan.

Do not spend this release expanding analytics, studios, personas or live mail. The owner's 6 November Outlook/Office request is the scope decision for the expanded required matrix in sections 4 and 13. Complete those rows together with existing advertised formats; preserve valid Stage A–E work and add the missing adapters and evidence.

## 8. Validation protocol

### 8.1 Engineering benchmark targets

These are development targets to validate, not existing performance claims or artificial maximums. On 6 November 2026 the owner accepted the available testing resources while retaining the goal of a final product without artificial caps. For this release, unexecuted larger-file tiers remain unverified evidence targets; they do not impose a 100 MB app limit or, by themselves, require a reduced-feature edition. They must not be recorded as passed or advertised as demonstrated capacity. Sections 3.4 and 12 govern the qualified claims and remaining release checks. The exception does not waive an observed correctness failure, unsafe resource handling, silent omission or required feature.

| Workload | Target and evidence |
|---|---|
| Large Mac archives | Retain 1, 5, 20, 50 and 100 GB MBOX/valid Unicode PST as additional validation targets when resources permit. Record available executed runs, including the reported 100 MB matrix, with actual device/RAM/storage and fixture composition; do not imply the proposed 16 GB Apple-silicon reference was used if it was not. Unexecuted larger tiers are not passes and are not a new product ceiling. Removing artificial limits and preserving safe, complete accounting remain required. |
| Message count | At least 1,000,000 messages, including both small-message and attachment-heavy workloads. Vary message count independently of byte volume. |
| Folder count | At least 10,000 folders/labels across multiple sources, including collisions, Unicode paths and multiple memberships. |
| Search completeness | Known targets beyond 500,000 attachment characters and the former 4 MiB body-index budget must be found, including phrases crossing chunk boundaries. Include individual messages beyond the documented 100 MiB source-locator threshold in reading/search/export tests. Require exact expected retrieval for deterministic supported text fixtures. |
| OCR | Maintain labelled samples per advertised language and image class; report measured retrieval accuracy and failures. Completing OCR is not a guarantee of recognising every word. |
| Responsiveness | Initial target: p95 warm first-page display and ordinary indexed search within 2 seconds on the declared reference corpus/hardware. Record cold-search and background-import performance separately; heavy queries may use visible cancellable progress. |
| Recovery | Process termination, low disk, source changes, locked files, removed drives at a batch boundary and during a write, and output tampering are exercised. Confirm correct state after relaunch. |
| Mobile | iPhone/iPad get separate measured workloads, OS/device records and suspend/relaunch tests; Mac success never substitutes for mobile evidence. |

If a target fails, record the cause and keep affected correctness, safety and required functionality open. Distinguish an observed failure from a test not run because of the available resource budget. The owner's large-file validation exception is not a pass and does not excuse a known bug. Preserve format-specific validity constraints; for example, a size that is valid for one PST variant does not make it valid for every variant.

### 8.2 Fixtures and test layers

Use small fixtures with independently known expected results before expensive scale runs. Maintain real originating-client samples for each promised format/variant, plus synthetic edge cases whose expected identities, payloads and folder memberships can be enumerated. Use public/licensed samples or consented data; keep private mail, credentials and attachment contents out of public repositories and ordinary logs.

| Layer | What it must establish |
|---|---|
| Deterministic parser/storage tests | MIME/encoding correctness, header/body/attachment relationships, source identities, folder memberships, malformed-input states and consistent migrations |
| Search tests | Targets present only in bodies or attachment contents; end-of-document and cross-chunk matches; repeated filenames; multilingual text; coverage states; OCR evaluated separately from deterministic extraction |
| Duplicate tests | Byte-identical, equivalent, similar and unresolved classes; same ID with different content; same prefix with different tails; changed attachments/headers; copies beyond 5,000; preserved annotations and holds |
| Integration tests | Import → read → search → review duplicates → export with stable selections; self-contained mode without original source; concurrent jobs; full backup/restore and index rebuild |
| Fault tests | Cancellation, force quit, low storage, permission loss, changed/missing sources, source-drive removal and archive-database-drive removal including during a write; incomplete and tampered outputs |
| Destination tests | Reparse/reconcile all outputs for full verification, then exercise promised workflows in independent readers/actual supported client versions |
| Release/platform tests | Optimised candidate, actual target hardware/OS, signed/distribution configuration where applicable, offline entitlement behavior, upgrade and restore; separate mobile suspension/relaunch evidence |
| Usability tests | Each five-job journey, recovery/help paths, correct interpretation of incomplete search and unverified/partial outputs, and safe duplicate decisions |

Keep source accounting and processing coverage distinct. If source totals are unknown, report that uncertainty. Duplicate groups are classifications of imported occurrences, not extra imported records. “Checked” is a coverage count over outputs, not another mutually exclusive export disposition to add to “written.” Keep selected, intentionally excluded, failed and written outcomes reconcilable without double counting.

Historical executed results may be retained as context, but they do not replace evidence on changed paths in the actual candidate. Do not turn projected throughput or an earlier small fixture into a completed 100 GB test. Once appropriate checks pass, broaden testing only for a new change, failure or unresolved concern.

### 8.3 Real-user task test

Recruit a small initial group of representative archive users with permission to use their data. Give each five tasks:
1. Open a supplied archive and explain whether import is complete.
2. Locate a message in a nested folder.
3. Find a document from text that appears only inside its attachment.
4. Review repeated copies and correctly keep a changed version.
5. Export selected mail and explain whether it is ready to use elsewhere.

Record task success, time, wrong selections, missed content, help requests and ability to interpret partial results. Compare with the user's previous method using equivalent tasks in a counterbalanced order. A small pilot informs design; it does not justify a broad percentage claim about all users.

The release record should name the commit, signed/release build, OS/device, datasets, expected results, actual results and limitations. Unit tests are appropriate for parser/search/deduplication invariants; integration and real-client tests are necessary for the end-to-end promise.

### 8.4 Combined preservation rehearsal

Use the combined LIFE test in section 6 as the product rehearsal: import a representative self-contained archive; reconcile contents; detach only its disposable original test source; restart; find an attachment by its contents; retain a changed version during duplicate review; back up; restore into a clean profile/device; rebuild indexes if needed; export; and independently verify the result. Repeat the relevant stages across interruption and app upgrade.

A successful rehearsal complements, rather than replaces, the format matrix and fault tests. Retain expected-versus-actual results and actionable failures.

## 9. Ten mandatory release gates

Use the 30 work items above plus LIFE-01 through LIFE-06 as the implementation and acceptance checklist, and attach evidence to each. Existing working behavior can satisfy an item after verification; rewriting it is unnecessary.

The next version passes only when:
1. All five complete customer journeys and the six LIFE acceptance checks pass on the actual release candidate.
2. Required supported-format paths have real fixtures and expected outcomes; synthetic fixtures add edge cases rather than replace real-format validation.
3. Deterministic ground-truth tests have zero unexplained missing records, wrong folder memberships, wrong attachment associations or false identical-duplicate classifications.
4. Known arbitrary ceilings are removed. Pagination, streaming and bounded work queues may remain, but they cannot silently change the processed/searchable scope.
5. Full exports reconcile the entire selection and preserve final verification inventories. Independent reader/destination tests substantiate compatibility.
6. Fault tests demonstrate recoverable data and honest outcomes, including separate-process testing for drive removal during a write, and the whole-archive restore passes on a clean profile/device.
7. Existing archive upgrades, saved professional work, holds, purchases and restoration still pass; data-access behavior matches the explicitly adopted entitlement policy.
8. No unresolved critical/high issue remains that could lose data, misclassify removable copies, omit searchable content without disclosure, misstate completeness or produce incorrect output.
9. Every claimed benchmark has executed results tied to a commit, build, device/OS and dataset. Unrun tests and projections are not passes. Under the owner's 6 November validation decision, larger-file tiers not executed with available resources remain explicitly unverified rather than becoming a 100 MB product cap or an “unlimited capacity” claim. The no-artificial-cap claim requires the audit in sections 3.4 and 12.
10. A representative usability pilot completes the five tasks without developer coaching. Initial target: at least 9 of 10 participants succeed on each ordinary task, and all participants correctly identify deliberately partial/unverified outputs and avoid destructive mistakes. This is an internal acceptance target, not a population-wide marketing statistic.

Maintain one release matrix with: requirement ID, actual current behavior, code change if needed, automated result, manual result, evidence location, unresolved limitation and release decision. A requirement can be “not started,” “in progress,” “implemented,” “verified,” “failed” or “blocked.” “Implemented” is not “verified.” OCR uncertainty and unavailable/decryption-blocked source content must be represented explicitly; they do not become searchable merely because a job finishes.

If any mandatory outcome fails, keep the release open and finish the affected work. Do not ship a “fully functional five” claim by relabelling an implementation gap as a user limitation. Reconcile store copy and onboarding with the final verified matrix.

### 9.1 Evidence tracker and release record

Use a single tracker with one row for every OPEN/FOLD/FIND/DUP/OUT/LIFE identifier. Add separate rows for required format variants and destinations where they need distinct evidence. Keep source findings, implementation progress and test results separate.

| Tracker field | Required value |
|---|---|
| Requirement ID and owner | Stable ID from this plan plus the accountable implementer/reviewer |
| Source state | What the actual release branch does now; distinguish the earlier finding from any intervening fix |
| Implementation state | Not started / in progress / implemented / verified / failed / blocked |
| Change reference | Commit or explicit “existing behavior reused” |
| Test definition | Fixture identity, independent expected result, scope and acceptance condition |
| Execution evidence | Build/commit, device/OS, test/client versions, actual result and evidence location |
| Exceptions | Unreadable, protected, unsupported, partial or resource-paused items; unresolved issues |
| Release decision | Pass / fail / blocked with a concrete reason; no requirement waived just because code exists |

The final release record must state the exact build, supported input variants, attachment extraction/OCR coverage, output/destination compatibility, measured scale envelope and remaining inherent constraints. A known required implementation gap keeps the release open; a declared unsupported input does not become a passed supported-format case.

## 10. Adopted decisions, proposals and deferred expansion

These decisions reconcile earlier recommendations with the owner's 6 November request for Outlook/Office to become a main strength. Compatibility expands within the same five jobs; unrelated product modules remain outside this release.

| Item | Consolidated treatment |
|---|---|
| OLM input | Required under the 6 November Outlook/Office expansion. Add a dedicated reader, real-origin fixtures and every applicable dimension of format acceptance before promising support. |
| TAR/TGZ input | Required with the expanded container/attachment workflow. GZip alone does not imply TAR extraction; reconcile members, integrity, path safety and supported enclosed content. |
| Post-expiry reading and basic portability export | **Adopted by the owner, 6 November 2026.** The policy decision is closed; implement and test the access matrix in section 12.2. Preserve all existing data and purchased rights |
| Exact performance thresholds | Engineering targets in section 8.1, not demonstrated speed claims or artificial maximums. Record executed results; identify unexecuted larger-file tiers under the owner's resource-budget decision. No 100 MB app cap or universal capacity claim follows |
| New saved-search tools, search-within-results, typo assistance and richer attachment browsing | Later retrieval improvements; retain existing working conveniences |
| Batch archive queues, selective mailbox import and incremental snapshot comparison | Later import improvements with stable source identity; not substitutes for reliable current imports |
| Guided storage relocation and cross-archive comparison | Later convenience work unless needed to make an already advertised workflow safe |
| Shared attachment-storage deduplication | Later, after reference integrity, deletion, backup, migration and honest physical-space accounting are proven |
| Legacy/modern Office variants, OpenDocument/iWork and compressed-attachment contents | Required under sections 4.2 and 13. Add supported credential/rights workflows and detailed section-level coverage. Preserve the distinction between new requirements and verified capabilities. |
| PST/MSG output and other native-store writers | Complete and independently verify the reported PST/MSG writers as Outlook portability routes. OLM writing is separate from OLM reading; direct OST/NSF generation and unclaimed historical-store adapters are not implicitly promised. |
| Standalone output verifier and extra destination presets | Later trust/portability improvements; durable verification inventories are required now |
| More AI, analytics, investigation workflows/personas and general inbox/live-mail features | Expansion frozen/deferred for this release; preserve existing customer access and records |

If a proposed item is adopted, update this master, the requirement matrix, tests and public promise together. Do not resolve an optional decision by quietly counting it as completed or required. Existing paid capabilities remain protected even when their expansion is deferred.

## 11. Implementation handoff and required deliverables

Use this document as the sole mailin next-release execution brief. First reconcile its baseline with the actual app source; then implement or verify all 30 core items and six LIFE checks, including sections 4 and 13's expanded format contracts. Retain valid prior evidence; reopen affected rows for their additional scope. Keep existing data, purchase rights and holds intact. Parser classes, compilation, file creation or a demonstration on a small archive do not establish complete compatibility.

Deliver the following together:

1. The focused application changes, with safe schema migration and preserved existing customer capabilities.
2. The requirement tracker covering all 36 IDs, with actual pass/fail evidence and unresolved issues.
3. A machine-readable capability registry and per-format/per-platform matrix covering import, preservation, extraction sections, folders, search, duplicate comparison, exports and independent verification.
4. Reproducible fixtures and automated/integration checks for content correctness, complete scope, recovery and output fidelity, including COMP-01–20 and the original acceptance cases.
5. Executed performance, clean-restore, fault, platform and independent destination-client results tied to the candidate.
6. Quick-start/sample data, task help, recovery guidance, accessibility evidence and the real-user pilot results.
7. A tested entitlement/access matrix consistent with adopted policy, plus reconciled app, website and store claims.
8. A release report showing all ten gate decisions. If any required gate fails, state exactly what remains and continue the affected work; do not describe the release as completing the five jobs.

**Completion means the customer can preserve the archive, find its supported contents, distinguish repeated copies safely, recover after failure and obtain independently checked usable exports—with complete accounting across the declared scope.**

## 12. Owner decisions and final-release closure — 6 November 2026

### 12.1 What has been decided, and what has not been verified

The owner has approved LIFE-06's retention of reading/basic export after expiry, confirmed that the five archive jobs define mailin's main presentation, and insisted on a final product without artificial limits. The current reported 100 MB test matrix is accepted as available scale evidence; it is not an app capacity ceiling. Additional larger-file tests remain unexecuted evidence targets, without limiting the product to that fixture size.

The owner's phrase “unlimited everything” is recorded here as the ambition to remove artificial product restrictions. It must not become an unqualified guarantee of infinite capacity, universal format support or perfect extraction. Use the audited and qualified wording in section 3.4. This is a claim/evidence distinction, not an instruction to add limitations.

The implementation report supplied by the owner describes 17 local commits on `v3-architecture` ending at `e48f556`, not pushed. That report describes substantial implemented work and passing checks. This planning document has not independently inspected those commits or logs. Do not replace the historical code baseline with an invented verified release state.

Two search requirements are expressly still open in the report: the ordinary search box uses the previous engine, and attachment evidence opens only the parent message. Keep FIND-04/FIND-05 partial until these paths meet sections 5.3 and 13. The later screenshot reports an AccessPolicy/LIFE-06 change, but the complete policy test matrix and presentation change still need candidate evidence. The owner's subsequent Outlook/Office request also adds the required compatibility completion pass in section 13; Stage E completion for the old scope does not establish that expanded coverage.

### 12.2 LIFE-06 policy to implement and test

The approved policy is that users retain access to their imported data and basic portability after subscription expiry, while new paid work stops according to their plan. The following implementation defaults make that policy usable; they do not introduce new prices, free-import limits or restrictions on valid lifetime purchases.

| Capability/state | Required treatment |
|---|---|
| Existing archive after expiry | Keep folder browsing, reading, attachment opening and existing deterministic search available so users can locate their data. Search uses existing indexed/extracted content with truthful coverage; this does not promise free new AI/OCR processing. |
| Basic portability export after expiry | Allow supported mail-preserving EML/MBOX export of already imported data, including original attachments and the appropriate inventory/verification record. Do not reapply trial preview/count limits to lock away previously imported data. Format/resource constraints and honest partial states still apply. |
| New paid work | Enforce the existing plan for new imports, new paid OCR/enrichment, AI or specialist productions. Preserve separately purchased/lifetime rights and existing professional records/holds. |
| Necessary access and maintenance | Permit source relinking, safe recovery, index rebuild from retained extracted text and content hydration needed to read/basic-export existing mail. Do not require a new subscription solely to regain access after an app upgrade or restore. |
| Expiry, refund or entitlement change | Never automatically delete imported mail, attachments, annotations, holds or backups. Revoke affected future paid work according to the entitlement while preserving the adopted data-access path. |
| Offline or temporarily unavailable store | A failed entitlement refresh is not itself proof of expiry/refund. Handle verified cached entitlement state consistently and preserve existing-data access. |
| Purchase restoration/reactivation | Restore the relevant paid capabilities without reimporting, duplicating or damaging the archive. Test transition back to the adopted plan. |
| Paywall/help | State plainly that existing archives remain readable and basically exportable after expiry, and identify what requires an active paid entitlement. |

Test active purchase, trial, confirmed expiry, refund/revocation, offline refresh failure and purchase restoration in the appropriate test environment. Verify both allowed existing-data access and blocked new paid work. The previously skipped entitlement tests are not passes; the policy must be wired and exercised before release. Use sandbox transactions, not real charges, for purchase testing. [Apple sandbox testing guidance](https://developer.apple.com/help/app-review/before-submitting-for-review/configure-in-app-purchases)

### 12.3 Remaining final-release work

Use existing valid evidence rather than repeating completed work without a reason. This closure list now includes the owner's expanded Outlook/Office contract as well as the unfinished work in the supplied report. Section 13 specifies new compatibility requirements; do not present them as already implemented.

| Remaining item | Exact closure condition |
|---|---|
| Complete the expanded format contract | Implement/verify sections 4 and 13: Outlook PST/OST/OLM/MSG and declared variants; old/new Office and the remaining named business formats; safe nested extraction; password/key/rights workflows; correct folder/duplicate semantics and Outlook portability. COMP-01–20 need recorded results. Disclosing an unsupported healthy required file does not close the implementation gap. |
| Finish the two search paths | Ordinary search and Advanced Search share the validated model, coverage/unknown rules and scope; attachment evidence opens the specific matching attachment/location where supported. Execute the affected section 5.3 tests, including incomplete negative searches. |
| Implement and verify LIFE-06 | Apply section 12.2 and run relevant purchase/expiry/offline/refund/restore tests. Owner policy approval is complete; app verification is not inferred from it. |
| Validate real supported inputs | Add real originating-client fixtures or permitted independent samples for every advertised format/variant, with known content/folders/attachment expectations. These can be small files within available resources; larger file size is not required to establish real-format fidelity. Synthetic fixtures remain useful edge-case tests. |
| Validate usable exports | Retain reported inventory/re-hash work and prove source-to-output content reconciliation. Complete appropriate Apple Mail/Thunderbird destination tests; independently validate PST output if it is advertised. Record actual client versions, workflows and results, including attachments and folder mapping. |
| Complete external-process recovery evidence | Run interruption/drive-detachment during a write with an external controller and a disposable test volume, or document the exact environment blocker. Check recovery after relaunch. Retain the reported clean-profile restore test and cross-machine locator fix with regression evidence. |
| Close the human usability gate | Run the five-task pilot with real participants using the existing acceptance target, including recognition of partial/unverified results. The agent prepares fixtures, instructions and scoring; automated tests do not substitute for people. |
| Reconcile remaining LIFE/security/help evidence | Confirm the candidate has the required safe previews, protection/key behavior, temporary/log handling, recovery help and keyboard/VoiceOver evidence. Owner-only permissions alone are not the whole LIFE-04 check. Reuse existing passing results where they cover the actual paths. |
| Finish presentation and the release candidate | Apply sections 3.3–3.4 to the app/listing/website/help, audit product-imposed caps, reconcile all 36 requirement rows and ten gates, and prepare a signed distribution candidate. Record build/commit, fixture hashes, executed results and the truthful tested-workload matrix. Smoke-test installation/update on every platform being released and complete App Store metadata/review information. |

The no-artificial-cap audit must cover paid-product import size/count, folder enumeration, both search paths, attachment/body text scope, duplicate scanning, selected export size/count and paging. Work-unit budgets must not silently discard the remainder. It is acceptable for a task to report a genuine resource or unsupported-format barrier; it is not acceptable to label that task fully complete. Audit scope and results belong in the release record.

The reported uncommitted change to the legacy Xcode project is housekeeping: inspect its diff, preserve a patch if needed, and exclude or discard only confirmed generated changes. Do not blindly reset unrelated local work. No push, merge, release upload or publication is performed by this document update.

### 12.4 The final release claim

Release the complete five-job product when the remaining functionality and required evidence above, including the expanded sections 4 and 13 compatibility contract, pass, with the owner's explicit scale-evidence limitation recorded. Do not impose an artificial 100 MB product cap and do not market untested infinity. Keep the planned larger workload matrix available for future verification.

The release record must distinguish **implemented**, **executed and passed**, **not executed**, **observed limitation** and **owner-approved validation scope**. A final release label is not proof that every conceivable file/device combination has been tested.

Apple asks for tested device/OS information and accurate, complete feature and purchase information during review. Prepare that information for the actual candidate. [Complete review information](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## 13. Outlook and Office completion pass — researched 6 November 2026

### 13.1 Why the previous completion statement was too broad

The earlier plan explicitly left OLM as a proposal and legacy Office/container-content extraction as later work. An agent could complete that narrower implementation and still leave the exact gaps shown in the owner's screenshot. This was a scope shortcoming in the earlier plan. It does not establish that the agent failed to implement an assigned reader.

The owner's new instruction expands compatibility within the same five jobs. Sections 4 and 10 are reconciled accordingly. Do not create a second roadmap or restart passing Stage A–E work. Reopen only the affected requirement/evidence rows and their regressions.

| Evidence supplied by the owner | What it establishes for planning |
|---|---|
| Agent reports PST/MSG/MBOX/EML work and a 100 MB synthetic matrix | A reported implementation baseline; not independent real-format or large-workload certification. |
| Screenshot says DOCX/XLSX/PPTX text is searchable | Modern Office extraction is reported. Its coverage of comments, hidden content, embedded objects and variants still needs a section-level contract and tests. |
| Screenshot says DOC/XLS/PPT, OpenDocument and iWork are retained but not read | Known extraction gaps against this expanded target. |
| Screenshot says compressed attachments are retained but contents are not searched | A known recursive retrieval gap, even if ZIP source import already works. |
| Screenshot says protected Office/PDF stays locked | Recognition/preservation exists in the report; a successful user-password unlock-and-index workflow is not demonstrated. |
| Prior report admits legacy ordinary search and imprecise attachment navigation | FIND-04/FIND-05 remain unfinished until the actual candidate proves both paths. |
| Screenshot shows an AccessPolicy/LIFE-06 change and passing module-gating tests | Work on the approved policy is reported. The complete expiry/refund/offline/restore capability matrix is not independently established by those visible lines. |

Microsoft's documentation gives a strong reason to make this a central use case: its Mac archive guidance identifies PST/OLM workflows, while Windows PST operations differ by Outlook edition and currently have version/installation prerequisites. This is an opportunity for a dependable local archive bridge, not evidence that no competing product exists. Do not claim every current Outlook edition can import every output. [R1–R3]

### 13.2 The five end-to-end customer outcomes

| Job | Expanded completion contract | Existing requirement mapping |
|---|---|---|
| Open archives | Import the required mail families without requiring Outlook or Office to be installed for ordinary unprotected files. Read messages while work continues; checkpoint bounded work; expose damaged, missing, protected and non-mail records. Leave source files unchanged. | OPEN-01–06; LIFE-01/03/04 |
| Preserve folders and relationships | Keep every actual source folder, original name, empty folders and message membership. Preserve categories/labels/flags separately. Distinguish virtual/search-folder views from physical copies. Retain the parent chain through embedded mail, winmail.dat, compressed members and embedded Office objects. | FOLD-01–05; LIFE-01–03 |
| Find messages and attachments | Search all required document families and their declared sections through the same simple/advanced query model. Show active filters, real snippets, exact file/section location and coverage. Open the actual matching child document, including a file inside a ZIP. Offer retry/unlock actions. | FIND-01–07 |
| Identify duplicates safely | Scan the whole selection and retain the four existing classes. Distinguish original byte identity, explicitly defined normalised content equality, candidate identity and near similarity. Across PST/OLM/EML, compare full declared content and attachments with format-aware rules; never equate converted messages using subject, Message-ID or extracted text alone. Preserve all source memberships, metadata, holds and undo. | DUP-01–05; FOLD-03; LIFE-03 |
| Export and verify | Produce the complete frozen selection as usable EML/MBOX/PST/MSG as appropriate, with original attachments, folder mapping and a durable inventory. Reconcile content with the imported source and independently test destinations. Preserve nonrepresentable information in the full preservation package and disclose conversion losses. | OUT-01–07; FOLD-05; LIFE-01/02/06 |

An exact byte comparison of two encrypted attachments can establish that those encrypted bytes are identical. It cannot establish equality of different encrypted containers' hidden content. Similarly, two Word files with identical extracted text but different revisions, images, macros or metadata are not byte-identical. Keep storage consolidation separate from message removal.

### 13.3 Extraction depth, location and coverage contract

Create one machine-readable capability registry used by import dispatch, extraction, Help, the public format matrix and tests. Each entry names the actual format signature/version, encryption/container variants, engine version, applicable platforms, extracted sections, navigable locations, known exclusions and fixture results. Read actual content signatures; treat extension/MIME mismatches as evidence to inspect, not a reason to route blindly.

Each document record carries: stable source/message/attachment identity; parent document; full container/member path; immutable original hash; detected format/version; extractor version; protection status; extraction sections and coverage; content chunks with actual location spans; and errors/retry checkpoints. Keep imported original data, decoded text, OCR text and rendered previews distinct.

Implementation requirements:

1. **Word depth:** index ordinary text, tables, headers/footers, notes, text boxes and comments. Represent insertions/deletions/revisions explicitly. A comment-only match must say "Comment"; historical deleted text must not appear as a current quotation. Index embedded supported files as children.
2. **Excel depth:** enumerate all sheets and stored cells, including hidden sheets/rows/columns, with sheet names and cell addresses. Keep formatted/cached values, raw values and formulas as distinguishable fields where available. Do not recalculate or fetch data. A formula with no stored result has no verified result to search. Test both date systems, number formatting and text encodings without silently changing original values.
3. **PowerPoint depth:** include slides, tables/text boxes, notes, hidden slides, comments and available chart text, each labelled. Do not lose notes merely because a preview image does not show them.
4. **Other business documents:** define equivalent page/shape/task/table/row locations. Search stored textual values; preserve unsupported objects. A registry entry must say exactly which sections remain unprocessed.
5. **Nested content:** represent a chain such as "message → winmail.dat → forwarded.msg → documents.zip → budget.xls → Forecast!D27". Different files with the same name remain distinct. Keep the outer archive, enclosed file and all parent references.
6. **Full indexing:** feed the existing complete chunk index incrementally. Avoid flattening a whole archive or document into one giant string/array. Preserve cross-chunk phrase matching within a logical document without joining different cells/sections/files into false phrases.
7. **One search meaning:** the ordinary box, advanced builder, saved query and export selection share the validated query model. Type, filename and content conditions scoped to one attachment must refer to the same actual descendant, not different files in the same ZIP.
8. **Honest negatives:** unfinished or locked children may change the answer to a negative query. Propagate unknown through the existing three-valued rules. If the number of children cannot yet be known, show an unknown extent instead of a fabricated "N".
9. **Navigation:** selecting evidence opens the exact matching attachment/member and its supported location. Where native layout rendering is unavailable, provide a readable extracted-content view with an accurate section anchor and an Open Original action. This fulfils retrieval without requiring Office for text navigation; do not invent a page/cell coordinate.
10. **Coverage UX:** distinguish original preserved, extracted, indexed, no text found, partly processed, locked, rights required, remote-only, missing member, unsupported version, failed, paused and stale. Offer applicable Unlock, Retry, Resume, Locate missing part or Attach downloaded original actions. Report affected items rather than a reassuring global green badge.
11. **Migration:** on extractor upgrades, keep original hashes and identities, rebuild affected derived documents and invalidate stale hits atomically. A newly failed parser must not silently delete previously indexed evidence or mark the remaining index complete.
12. **Protected derived content:** session decryption and persistent indexing are different choices. Protect temporary plaintext, keys and credentials; make retention of decrypted search content explicit and permitted. A rights-managed record must not leave a permanent searchable plaintext copy that ignores expiry/revocation/export rights.

### 13.4 Passwords, signatures and unavailable content

| Condition | Required behavior |
|---|---|
| Ordinary password-protected PDF/Office/archive | Ask for the supplied password, verify it, process the supported scheme, clear in-memory credentials and continue affected work without reimporting the whole mailbox. Wrong password, unknown password and unsupported encryption are different states. Test each advertised encryption family; do not call every protected file supported because one AES example worked. |
| Office editing/worksheet protection | Detect separately from encryption. Read permitted stored content without treating edit restrictions as proof that the document cannot be searched; never execute or modify it. |
| S/MIME and OpenPGP encrypted messages/attachments | Detect the envelope and provide a tested unlock path using the user's eligible certificate/private key or key material for explicitly supported schemes. Missing keys remain visible. Preserve the encrypted original; derived plaintext and exported copies must be labelled and protected. |
| Signed mail or signed Office/PDF | Preserve the signed original. If verification is offered, distinguish checked integrity, certificate/trust status, unknown/offline revocation and unverified signatures. A conversion's digest does not preserve the original signature's validity. |
| Microsoft Purview/IRM-protected items | Detect and retain the item, explain required identity/rights, and support an authorized access route. A native MIP adapter is a separate, rights-aware integration; it may need authentication/network access. Never silently substitute tenant-wide privileges, bypass restrictions or claim that a document password unlocks enterprise rights. If access is provided through the authorized originating app, let the user bring back a permitted readable copy with provenance; label the original's search coverage honestly. |
| OneDrive/SharePoint or other remote attachment reference | Preserve the URL/reference and available metadata, explicitly say "content not stored in this archive", and offer user-directed retrieval or association of an authorized downloaded copy. No background crawling, fabricated text or assumption that a link points forever to the original version. |
| OST cache omits content, missing archive volume or corrupt source | Explain what is actually present, preserve readable records, and offer re-export/download/locate/retry as applicable. Recovery/salvage output remains separate from a fully reconciled import. |

Password handling has practical implementation paths: POI documents standard/agile OOXML decryption and format-specific older Office schemes. Its matrix also has gaps, so the chosen adapter must be tested rather than treated as a universal decryptor. Microsoft's MIP documentation describes authorization and rights checks for protected content. [R8–R10] S/MIME is a distinct secure MIME protocol, not ordinary Office password protection. [R11]

These are external conditions that a completed workflow must handle transparently. No local tool can manufacture absent server data, a missing decryption key or authorization that the customer does not have. The target is comprehensive handling and successful processing of accessible supported content, not an impossible promise about inaccessible information.

### 13.5 Build on existing engines, with explicit adapter decisions

Preserve ArchiveCore, source/occurrence identity, the chunk index, advanced builder, duplicate classes, export receipts and backup work already reported. Add adapters and acceptance evidence; do not rewrite those components merely to introduce a format library.

| Layer | Recommended implementation investigation | Constraint to prove before choosing |
|---|---|---|
| PST/OST/MSG | First test the existing native readers/writers against Microsoft specifications and real fixtures. Use an independent implementation as a comparison oracle; evaluate a maintained library/SDK only for demonstrated gaps. | Correct MAPI properties, compressed RTF, nested attachments, bounded traversal and real destination readability. A PST reader does not supply a PST writer. |
| OLM | Add a dedicated semantic reader. Benchmark native implementation versus a suitable SDK using actual Mac exports; Aspose.Email documents an OLM reader with folder/message traversal and OLM-to-PST conversion. | Actual supported versions, full member/folder/property fidelity, memory, cancellation, runtime footprint, platform support and distribution rights. Vendor documentation establishes an option, not mailin compatibility. [R12] |
| Office extraction | Use Apache Tika/POI as a concrete benchmark candidate for old/new Office and structured text extraction; keep or extend native parsers where they meet the same contract. Compare results against known content from originating apps. | Tika/POI is Java-based, so prove a bundled, signed, offline macOS helper or choose another compliant implementation. Do not require the customer to install Java or Office. Plain text output alone may lose required locations. [R5–R7] |
| iWork/older document fallback | Evaluate a dedicated version-aware parser or controlled conversion engine. LibreOffice publishes filters for many legacy and iWork formats. | A listed filter is not proof of full extraction fidelity. Current Tika documentation explicitly says newer iWork generations yield metadata/resources/previews without full body text. Resolve that gap with a tested engine; do not mark it complete with OCR of a thumbnail. [R5, R13] |
| Compressed containers | Prefer an embedded native library such as libarchive where its tested methods meet the matrix; add another licensed adapter for actual method gaps. | Verify encryption, ZIP64, solid/split and RAR variants individually. Libarchive's own documentation says library support does not guarantee that an application enabled it. [R14] |
| Other Office business families | Evaluate targeted extractors for OneNote/Publisher/Visio, MPXJ for declared Project variants and Jackcess for declared Access variants. | Only claim tested stored text/properties. Parser-specific omissions, linked content, encryption and platform/runtime requirements remain acceptance work. [R6, R16–R18] |
| PDF/OCR | Reuse the existing PDF and OCR path, extending coverage and location mapping where fixtures find gaps. | Test supported languages and mixed/scanned pages; extraction completeness is distinct from OCR recognition accuracy. |
| Protected enterprise documents | Evaluate Microsoft's rights-aware MIP APIs for the separately consented access workflow. | Supported platform/build, user authentication, tenant policies, relevant read/extract/export rights, expiry behavior, and truthful network/privacy disclosure. No universal offline rights-management promise. [R9–R10] |

Make the parser choice with a short comparative fixture run, not by counting extensions on a sales page. POI's XLSB extractor, for example, documents text extraction but says its formula-text option is unsupported; that is a concrete section-level gap to close or label, not a reason to call the whole workbook "fully searchable". [R7]

Run untrusted parsers in a restricted worker with bounded memory, cancellable work, private temporary storage and restart after failure. On macOS, assess an XPC service with appropriately narrow capabilities. Do not grant the parsing worker network or broad filesystem access just for convenience. POI itself recommends isolation for resource failures, and Apple documents separation into helpers/XPC for limiting capabilities. [R15, R19]

For nested archives, reject traversal/absolute output paths, unsafe links and malformed lengths; track expansion, disk and time budgets. Legitimate large work can pause and resume with a visible reason or an explicit resource decision. Do not remove protection against decompression bombs to satisfy "no artificial limits"; do not count paused work as finished.

The Mac engine does not automatically establish iPhone/iPad parity. Keep a per-platform capability matrix and upgrade regression for existing purchases/data. Before advertising the same new extraction support on mobile, execute it there; a Java desktop helper cannot simply be assumed available in an iOS app.

### 13.6 Distribution and maintenance requirements

This is a dependency/distribution review, not permission to buy a licence or publish a release.

- Record pinned versions, dependency inventory, licence texts/notices, redistribution obligations and update ownership for every bundled parser, runtime and cryptography component. Apache projects normally use Apache-2.0, but bundled dependencies need their own review. [R20]
- libpff's project describes itself as alpha and LGPL-3.0-or-later. That makes it a candidate to evaluate, not a drop-in proof of commercial readiness or a licence-free SDK. Review exact linkage/distribution terms before bundling. [R21]
- A commercial SDK needs a licence covering distribution inside this customer-facing app and the chosen platforms. Aspose distinguishes developer/site/OEM/SDK/metered categories; obtain the applicable terms rather than assuming a developer evaluation licence is sufficient. A no-cloud offline promise must also fit any licence validation/metering behavior. [R22]
- Validate bundled helper/runtime signing, sandbox access, architectures and startup on a clean Mac with no Office/Outlook/Java installed. Include all necessary code through the permitted distribution route; do not silently download executable parser code after installation.
- Test local-only operation and disable automatic remote parsers, external-entity fetching, remote images, macro execution and document data refresh. Rights-authorized retrieval/authentication is a separate, clearly described user action.
- Use Microsoft format/product names factually to describe tested compatibility. Keep mailin's branding distinct and avoid implying Microsoft endorsement. Update supported formats, privacy/help, review notes and actual screenshots together.
- Maintain a fixture regression set when Microsoft/Apple formats or parser dependencies change. "Final five-job release" means the defined workflows are complete; maintained compatibility continues after release.

### 13.7 Required additional acceptance cases

These are test/evidence cases mapped to existing IDs, not 20 new product pillars. Each needs a real-origin fixture where available, independently authored expected content, a recorded candidate build and an actual result. Public fixtures need appropriate usage permission; no private customer mail is necessary.

| Case | Scenario and pass condition | Requirement mapping |
|---|---|---|
| COMP-01 | ANSI and Unicode PST with Unicode/empty/deep folders, diverse bodies, real attachments and non-mail items: complete record accounting, original bytes and declared property mapping. | OPEN/FOLD; LIFE-01 |
| COMP-02 | Real OST with full messages plus cache-only headers/missing bodies: distinguish both, import accessible content, never promise missing server history. | OPEN-01/05/06; FIND-03 |
| COMP-03 | Real OLM with nested folders, repeated names, categories, dates and embedded documents: all declared mail content accessible; non-mail inventory disclosed. | OPEN/FOLD/FIND |
| COMP-04 | ANSI/Unicode MSG, tested OFT, compressed RTF, CID inline content, winmail.dat and embedded MSG: correct recipients/body and entire child tree with original hashes. | OPEN; FIND-01/03/05 |
| COMP-05 | Actual DOC/XLS/PPT and their declared older generations: known body/table/sheet/slide/annotation terms are found, without Office installed. | FIND-01/07 |
| COMP-06 | Modern macro/template/show variants plus XLSB and claimed Strict/Transitional XML: correct detection and extraction; active content never runs. | FIND-01/06; LIFE-04 |
| COMP-07 | Excel term only in a hidden sheet, cell comment, late cell, or stored formula result: exact location and text class; no false result when a cache is missing. | FIND-01/03/05/07 |
| COMP-08 | Word term only in header, text box, footnote, comment or deleted revision: correct section and revision label; original remains unchanged. | FIND-01/05 |
| COMP-09 | PowerPoint term only in speaker notes, hidden slide, table or chart label: correct match evidence and navigation. | FIND-01/05 |
| COMP-10 | Declared OneNote/Visio/Project/Publisher/Access variants: known local text is found with appropriate context; linked/not-stored content is distinct. | FIND-01/03/05 |
| COMP-11 | Real OpenDocument and both legacy/newer iWork generations: known body/table/slide text found; metadata/thumbnail-only output fails the body-text requirement. | FIND-01/03/07 |
| COMP-12 | Nested ZIP/7z/RAR/TAR/GZip with same-named files, mixed formats, encrypted members and missing split volumes: complete tree, truthful unresolved scope and no path escape. | OPEN; FIND-01/03/06 |
| COMP-13 | Password-protected Office/PDF/container: wrong-password, correct-password, cancel/retry, restart and any chosen retention policy work as specified. | FIND-01/03/06; LIFE-04 |
| COMP-14 | S/MIME/OpenPGP, signed files, IRM and cloud references: available credentials/rights take the tested authorized path; absent rights/content never becomes a false no-match or complete export. | FIND-03; OUT; LIFE-04 |
| COMP-15 | Same mail represented in PST/OLM/EML plus changed attachment/revision cases: safe classes, no false exact identity, all memberships/notes/holds retained, undo works. | DUP-01–05; FOLD-03 |
| COMP-16 | EML/MBOX/PST/MSG output consumed by appropriate independent readers: folder/selection/content/attachment reconciliation plus durable hash inventory. | OUT-01–07 |
| COMP-17 | Equivalent ordinary/advanced queries, negative queries during partial indexing and same-child conditions inside a ZIP: identical semantics and honest unknown results. | FIND-03/04/05/07 |
| COMP-18 | Import → detach original test source → restart → find nested Office document → backup → clean-profile restore → export: originals and relationships survive. | LIFE-01/02/03; all five |
| COMP-19 | Malformed document, decompression bomb, worker crash, disk exhaustion and external-process interruption: contain failure, retain checkpoints, reconcile partial work and resume. | OPEN-03/05; FIND-06; OUT-06; LIFE-04 |
| COMP-20 | Clean machine, entitlement changes and human five-job pilot: ordinary supported work needs no Office installation; existing-data access follows LIFE-06; users notice partial results. | LIFE-05/06; release gates |

Put a unique target word in each required section and known non-target words in nearby sections/files to catch both omissions and false matches. Include English, Hindi/Bengali and the other advertised scripts/encodings in fixtures. For duplicates, use intentional same-body/different-attachment and same-text/different-document cases. For conversions, validate attachment hashes plus semantic fields against an independent source inventory rather than assuming entire converted-message bytes stay identical.

Destination testing must name actual client/OS versions and import steps. Use Windows Outlook for promised PST/MSG behavior and applicable Mac Outlook versions for their documented route. Apple Mail and Thunderbird remain part of the EML/MBOX portability checks. The writer and reader must not share the only implementation used to declare a pass.

Real-origin Office/Outlook fidelity fixtures can be much smaller than 100 MB. Run them within the available Mac resources; the scale evidence stays exactly what was measured. Repeat broader scale testing only when justified/resources permit, without implying it already passed.

### 13.8 Implementation order and final completion rule

1. **Reconcile the actual candidate.** Preserve uncommitted work and local commits. Compare every section 4 family with implemented adapters and tests; replace blanket "Office supported" and "all rows verified" labels with precise evidence. Retain valid Stage A–E results.
2. **Lock down the shared document/coverage model.** Add stable nested identities, section locations, capability registry and recovery states. Finish ordinary/advanced query parity and exact attachment navigation.
3. **Complete Microsoft mail intake.** Validate/fix PST/OST/MSG and add OLM/OFT/TNEF/embedded-message gaps. Keep source metadata and folder semantics through the same model.
4. **Complete document extraction.** Legacy/modern Word/Excel/PowerPoint variants and depths first, then the remaining named Office/OpenDocument/iWork rows. This is sequencing within the expanded goal, not a promise to leave required rows unsupported at release.
5. **Complete recursive and protected workflows.** Shared container traversal, user-password processing, supported key-based decryption and explicit rights/remote-content paths; then exercise combined queries.
6. **Reconcile duplicates and outputs.** Validate full fingerprints across representations and independently read every promised mail output, including the reported PST writer. Keep originals and conversion sidecars.
7. **Close release evidence and presentation.** Run the added compatibility cases plus affected original tests, the LIFE-06 matrix, recovery rehearsal and real-user pilot. Record unexecuted scale tiers honestly and ship only the claims supported by the candidate.

For each required, accessible test fixture, completion means zero unexplained missing records/folders/attachment bytes/search sections and no false exact-duplicate classifications. Every selected export item is accounted for and the declared portable format is independently readable. Unsupported processing of an ordinary required fixture is a gap to fix; displaying "unsupported" alone does not close it.

Conditional cases such as wrong credentials, absent server content, revoked rights and damaged files pass by truthful handling, preservation and recovery actions—not by pretending the unavailable content was extracted. Keep these distinct from parser omissions on healthy accessible files.

The main positioning remains **mailin: Email Archive Manager**. Lead with opening Outlook and other archives on Mac, preserving folders, finding Office attachments, reviewing copies safely and exporting with verification. Demonstrate those five jobs in the first screenshots. AI/Professional tools remain optional and secondary; do not remove existing rights or protections.

A suitable claim after the relevant checks pass is: "Open Outlook and other supported email archives on your Mac. Keep their folders, search supported Office documents and attachments, review duplicates safely, and export with verification." "No Outlook or Office installation required" is an additional claim only after the clean-machine test passes. Link the exact compatibility matrix nearby. This document is the research/implementation contract; it does not certify that those additions are already built.

### 13.9 Primary research references

Checked 6 November 2026. Documentation establishes available specifications, implementation options and product-version conditions; mailin's acceptance evidence must be produced separately.

- **R1. Microsoft — Outlook for Mac import, PST and OLM:** https://support.microsoft.com/en-us/outlook/import-email-messages-contacts-and-other-items-into-outlook-for-mac
- **R2. Microsoft — open/find PST, edition-specific requirements:** https://support.microsoft.com/en-us/outlook/open-and-find-items-in-an-outlook-data-file-pst
- **R3. Microsoft — OST contains only synchronized subset:** https://learn.microsoft.com/en-us/troubleshoot/outlook/user-interface/only-subset-items-synchronized
- **R4. Microsoft format specifications — PST, MSG and TNEF:** https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/141923d5-15ab-4ef1-a524-6dce75aae546 ; https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxmsg/b046868c-9fbf-41ae-9ffb-8de2bd4eec82 ; https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxtnef/1f0544d7-30b7-4194-b58f-adc82f3763bb
- **R5. Apache Tika — documented extraction families and iWork generation distinction:** https://tika.apache.org/docs/4.2.x/formats.html
- **R6. Apache POI — component capabilities and text extraction:** https://poi.apache.org/components/index.html ; https://poi.apache.org/text-extraction.html
- **R7. Apache POI — XLSB extractor and formula-text limitation:** https://poi.apache.org/apidocs/6.0/org/apache/poi/xssf/extractor/XSSFBEventBasedExcelExtractor.html
- **R8. Apache POI — encryption support matrix:** https://poi.apache.org/encryption.html
- **R9. Microsoft — Office cryptography structures and MIP SDK:** https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-offcrypto/4c132f1a-f4a0-42cc-9046-15af9afa9b9e ; https://learn.microsoft.com/en-us/information-protection/develop/overview
- **R10. Microsoft — rights checks/decryption and API permissions:** https://learn.microsoft.com/en-us/information-protection/develop/concept-republishing ; https://learn.microsoft.com/en-us/information-protection/develop/concept-api-permissions
- **R11. IETF — S/MIME 4.0 and OpenPGP/MIME:** https://www.rfc-editor.org/rfc/rfc8551.html ; https://www.rfc-editor.org/rfc/rfc3156.html ; https://www.rfc-editor.org/rfc/rfc9580.html
- **R12. Aspose — OLM traversal and conversion API:** https://docs.aspose.com/email/java/read-outlook-for-mac-olm-file-and-get-folders-and-subfolders-information/
- **R13. LibreOffice — conversion filter names and format families:** https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html
- **R14. libarchive — architecture, licensing and actual format/method support:** https://www.libarchive.org/ ; https://github.com/libarchive/libarchive/wiki/LibarchiveFormats
- **R15. Apache POI — security, memory/temp handling and process isolation:** https://poi.apache.org/security.html
- **R16. Apache POI — Visio binary/XML extraction:** https://poi.apache.org/components/diagram/index.html
- **R17. MPXJ — Project file and field coverage:** https://www.mpxj.org/supported-formats/ ; https://www.mpxj.org/field-guide/
- **R18. Jackcess — Access database reader:** https://jackcess.sourceforge.io/
- **R19. Apple — sandbox violations and separating helper capabilities:** https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations
- **R20. Apache Software Foundation — licence/redistribution terms:** https://www.apache.org/licenses/LICENSE-2.0
- **R21. libpff — project status, formats and licence:** https://github.com/libyal/libpff
- **R22. Aspose — commercial licence categories:** https://purchase.aspose.com/policies/license-types/

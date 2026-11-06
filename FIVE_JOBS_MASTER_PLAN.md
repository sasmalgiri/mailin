# mailin — consolidated next-release master plan

**Prepared:** 5 November 2026  
**Updated:** 6 November 2026 — LIFE-06 adopted; five-job product identity confirmed; testing scope distinguished from product capacity.  
**Purpose:** one implementation and acceptance brief for the next archive-focused release.  
**State:** planning consolidated; app changes and release acceptance are not established by this document.

This replaces the earlier fragmented mailin scope descriptions with one governing plan. It combines the archive-focus review, source-gap analysis, five-job implementation plan, format clarification, removal of artificial limits, and the later preservation, recovery, privacy, usability and access checks. Earlier reviews remain evidence and history; they are not separate competing backlogs.

**Execution scope:** 30 core work items, six cross-cutting LIFE checks and ten release gates. Preserve the identifiers below when creating issues, tests and release evidence. No version number, price, delivery date or new format promise is invented by this consolidation.

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
10. Proposed decisions and deferred expansion
11. Implementation handoff and release deliverables
12. Owner decisions and final-release closure, 6 November 2026

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

Format support is part of the five core jobs. Track **import**, **content/attachment extraction**, **folder preservation**, **search coverage**, **duplicate comparison** and **export** separately. A recognised extension or parser class is not a passed compatibility test.

The current-state notes below refer to the reviewed v3 source and repository evidence. They are not results from a new executed release test.

### 4.1 Incoming mail and archive formats

| Input family | Current evidence | Next-release treatment |
|---|---|---|
| MBOX, including extensionless mailbox files and Gmail/Thunderbird exports | Streaming/offset paths and executed fixtures exist; some very large messages are stored as source locators and are not fully searchable | Required: complete MIME/attachment handling, Gmail-label preservation, quoted From-line handling, documented MBOX variants, large-message reading/search/export and independently reconciled results |
| EML and folders of EML | Reader and directory path exist | Required: individual and batch import with original relative paths, nested attachments, Unicode headers/filenames and source identity; test nested folder layouts |
| EMLX and Apple Mail mailbox packages | Readers exist; repository evidence includes synthetic directory layouts using real message content | Required: genuine Apple Mail exports and EMLX examples, original hierarchy, inline/attached content and any required companion data; do not equate an exported mailbox with every arbitrary live Apple Mail database layout |
| Maildir and supported Thunderbird directory layouts | Maildir reader exists; MBOX handles appropriate Thunderbird mailbox payloads | Required: cur/new membership, supported flags, subfolders and source mapping; explicitly identify which complete profile layouts can be imported. A Thunderbird index file alone is not a mailbox |
| PST: supported ANSI and Unicode variants | Parser exists and fixtures have run; whole-result materialisation and variant coverage remain gaps | Required: real independent fixtures, scalable parsing, folder/body/attachment fidelity and inventory by variant. Preserve format-specific size constraints and declare protected/unreadable content |
| OST | Reader shares the PST parser; the checked format report records no real-file OST execution | Required before promoting complete support: genuine offline-store fixtures from claimed variants, full folder/message/attachment reconciliation and honest handling of unavailable/protected records |
| MSG | MAPI reader exists and real fixtures have run; current implementation is not fully streamed | Required: sender/recipient metadata, HTML/plain/RTF bodies as applicable, inline and embedded-message attachments, valid large-message handling and independent Outlook comparison |
| NSF | Parser exists; heuristic text fallback and lack of real-file evidence prevent a full-fidelity claim | Required before promoting complete support: real Notes/Domino fixtures, tested database variants and structured message/attachment/folder extraction. Heuristic salvage remains a separate partial recovery result |
| ZIP/ZIP64 containing supported mail; GZip containing a supported payload | Container support exists for named methods; encrypted members and nested archives have limitations | Required: member accounting, integrity checks, path safety, streamed extraction, reliable handling of supported mail members and explicit reporting of others. Compression does not itself define a mailbox format |
| OLM: Outlook for Mac archive | No dedicated OLM type/reader is present in the reviewed classifier/parser routing | **Proposed high-priority addition:** implement and verify OLM mail/folder/attachment import. This is a format gap in the current Mac archive proposition, not an existing capability |
| TAR and TGZ/TAR.GZ mail bundles | No TAR source reader is present in the reviewed routing; GZip support alone does not implement TAR member extraction | **Proposed addition:** complete this wrapper path for Takeout-style bundles, with member accounting, integrity and extraction safety |
| DBX, legacy MBX, Outlook OLK/profile databases and other historical client stores | Not established by this review | Later additions with explicit demand and their own parser/fixture matrix; do not advertise them as covered by generic “all email archives” wording |

Existing advertised input families remain required. OLM and TAR/TGZ are explicit proposed additions to the format roadmap, rather than silently claimed implementations. Their inclusion in a release promise requires the same evidence as the other rows.

Microsoft identifies OLM as an Outlook for Mac archive format and PST as the corresponding Windows archive format. This supports prioritising an OLM reader for a Mac archive product; it does not establish mailin support or compatibility with every current Outlook edition. [Microsoft format guidance](https://support.microsoft.com/en-gb/outlook/import-email-messages-contacts-and-other-items-into-outlook-for-mac)

Google documents ZIP/TGZ download packaging and the X-Gmail-Labels header used to preserve Gmail labels. Direct Gmail/Takeout support therefore needs label semantics and container completeness as well as an MBOX reader. [Google data export guidance](https://support.google.com/accounts/answer/3024190?hl=en)

### 4.2 Attachment preservation and searchable content

Preserve the original bytes, filename, MIME type, parent-message link and available metadata for every attachment that can be read from the source, including types with no text extractor. A type can be safely retained/exported without its internal contents being searchable. The UI and product copy must distinguish those capabilities.

| Attachment family | Release scope |
|---|---|
| PDF with embedded text | Required complete text extraction, page association and direct opening from a hit |
| Image-only/scanned PDFs, JPEG, PNG and TIFF | Required OCR integration for explicitly tested languages/image classes; preserve original bytes and label recognised text |
| DOCX, XLSX and PPTX | Required text extraction with document/sheet/slide context where available; do not execute macros or formulas |
| TXT, CSV, HTML/HTM and RTF | Required encoding-aware extraction and full-content search; safe HTML handling |
| Attached EML/MSG and nested MIME messages | Required where currently advertised: retain the parent/child relationship, child attachments and searchable supported text |
| ZIP and other compressed attachments | Preserve/export original bytes now; searchable supported contents require a separately tested safe extraction path. Container import support does not automatically provide attachment-content indexing |
| Legacy DOC/XLS/PPT, ODT/ODS/ODP and Pages/Numbers/Keynote | Explicit next extraction candidates; do not imply modern Office support covers these different formats |
| Other images, audio/video, CAD, executables and arbitrary binary files | Preserve/export readable bytes and searchable filename/metadata. OCR, transcription and format-specific content search require their own tested capabilities |

Digital signatures, password protection, S/MIME encryption, external attachment links and missing companion files are additional conditions, not new file formats. Retain original bytes and clearly state whether content could be decoded, authenticated, decrypted or retrieved. A valid parser must not fabricate inaccessible content or silently fetch remote material.

### 4.3 Outgoing formats

An import reader is not an export writer. Record output capabilities independently, including which fields can be preserved and which are transformed.

| Output | Role in the next release |
|---|---|
| EML files in a source/folder directory layout | Required preservation output: complete email content, attachments, original location mapping and a durable verification manifest. Ordinary EML export alone does not encode a whole mailbox hierarchy |
| MBOX, including partitioned output where needed | Required portable mailbox output: correct envelope/MIME handling and destination-client tests. Preserve hierarchy through separate mailbox files/directories plus an inventory rather than implying one MBOX contains every source folder relationship |
| MSG | Existing writer to verify and retain: require actual Outlook-readable results and attachment/metadata reconciliation before making a compatibility claim |
| PDF and portable HTML | Readable viewing/sharing outputs; distinguish rendering from a restorable archive. State how attachment originals accompany the report |
| CSV and JSON | Structured metadata/report outputs, with exact schemas and explicit inclusion/omission of bodies/attachments. A JSON result is only a restorable archive if a compatible importer and fidelity checks exist |
| Original attachments plus inventory | Required extraction output: byte hashes, parent messages, collision-safe filenames and original filename mapping |
| Word, Markdown, text, TIFF, vCard/ICS and existing professional productions | Preserve existing entitlements and verify their stated purpose. These formats do not substitute for mail-preserving EML/MBOX output |
| PST or OLM archive output | Separate writer projects requiring independent Outlook compatibility tests. They are not present as ordinary options in the reviewed unified export format enum; no new fully supported export promise is made by this plan |
| OST or NSF output | Separate native-store generation capabilities; no default promise to create them from an imported archive |

The reviewed folder-export layout enum only offers flat or by-year layouts. Original source/folder layout therefore needs explicit implementation and acceptance evidence under FOLD-05 and OUT-03; preserving a folder name inside metadata is not equivalent to reproducing the selected output tree.

PST/OLM/NSF stores may contain non-email objects. Count and disclose the object types outside mail import scope; keep source material available. Do not describe an email-only extraction as a complete backup/conversion of contacts, calendars, tasks, notes and every native property. Preserve existing contact/calendar features without allowing them to displace the five core mail jobs.

### 4.4 Evidence required for each format

For each promised input variant and each output format, record: actual originating application/version, fixtures and ground truth, source size/count, folder memberships, body/attachment checks, search targets, duplicate scenarios, interrupted-run recovery, conversion losses, destination reader/version and evidence tied to the release commit.

Use “implemented,” “tested,” “partially supported” and “unsupported” distinctly. An executed MBOX fixture does not validate PST; a ZIP path does not validate OLM or TGZ; a shared parser must not be the only oracle for an exporter. No feature badge or marketing list may collapse these differences.

Current-code references: [format classification](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/SourceFormatClassifier.swift#L28), [parser routing](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/EmailParserProtocol.swift#L66), [export formats and layout](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/Packages/ArchiveCore/Sources/ArchiveCore/ExportRequest.swift#L11), and [format evidence/limitations](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/SUPPORTED_FORMATS_AND_LIMITS.md).

## 5. Thirty core implementation items

The “Status” column below describes source evidence at review time; it is not current execution progress. Track actual implementation and verification states separately in section 9. All 30 items are required even where the status is “Complete or verify.”

### 5.1. Open large archives reliably

**Customer outcome:** “I can open my old mail, start reading it, and know whether the import finished correctly.”

| ID | Status | Required work |
|---|---|---|
| OPEN-01 | Complete or verify | Preflight detects the actual archive/container format, readable access, available destination storage and relevant limitations. Distinguish corrupt, unsupported, inaccessible and encrypted inputs. Do not request account credentials to open an ordinary local archive. |
| OPEN-02 | Fix | Replace whole-result materialisation in the PST/OST/NSF/MSG ingest paths with bounded parsing/storage and cancellable work. Keep database writes, indexing and UI browsing bounded too. A batch writer cannot fix an upstream parser that retains the whole archive. |
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
| FOLD-04 | Complete or verify | Keep original location metadata immutable. User-created tags, saved searches and renamed display labels must not rewrite the historical source path. Preserve attachment-to-message relationships. |
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
| FIND-01 | Fix | Complete ordinary content extraction for TXT/CSV, HTML, RTF, text PDF, DOCX, XLSX and PPTX; retain supported nested-email handling. Store each attachment's extracted text with its stable parent, part/document identity, version and available page/sheet/slide context. Do not execute macros, formulas or remote content. |
| FIND-02 | Fix | Connect OCR for supported JPEG/PNG/TIFF and scanned PDF pages to ordinary search. Process mixed text/scan PDFs without duplicating equivalent text; label OCR results, record language/model revision where available and retain original bytes. Test actual advertised languages/image classes. |
| FIND-03 | Fix | Persist honest processing/coverage states per message field and attachment, including queued, running, text extracted, processed with no text found, unsupported, locked, failed, cancelled, paused, partial and stale. Show scope-relevant coverage and recovery actions. A missing counter or failed coverage query is unknown, not zero. |
| FIND-04 | Complete or verify | Extend the existing guided form into the visual advanced search builder specified below. Support field filters, all/any/exclude conditions, clear source/folder scope, active editable filters, defined dates and attachment predicates through one validated query model. All visible conditions must reach execution. |
| FIND-05 | Fix | Return actual match evidence with results: field, matched condition, parent message, attachment identity and available location/snippet. Show truthful highlights and open the correct matching content. Remove invented Body attribution. Filter-only results explain which filters passed without inventing a text hit. |
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

**FIND-06:** use bounded memory, task concurrency, decompression/nesting limits and cancellable time budgets. Resource-paused, locked, unsupported or failed items remain visible with actionable next steps. A guard stopping an extraction cannot count as successful full processing. This release still has the same supported attachment families and deferred extraction formats as section 4.

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

**Later:** new saved-search management, search-within-results, a separate attachment-only browser, typo/synonym expansion, new extraction formats, searching inside compressed attachments and optional natural-language assistance. Retain existing working features. Raw SQL editing and AI-generated SQL are not required to deliver this plan.

This amendment expands FIND-04 and its dependencies within FIND-01–07. It does not add formats, change entitlement policy, expand AI/analytics, or change OPEN, FOLD, DUP, OUT, LIFE or the ten master release gates.

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
| OUT-01 | Complete or verify | Offer clear export choices: mail-preserving formats such as supported EML/MBOX paths, attachment-only output, and human-readable reports. Explain that PDF/CSV reports are not automatically complete restorable email archives. Keep only formats the release can actually write and validate. |
| OUT-02 | Complete or verify | Snapshot the selected messages and memberships before writing. Exporting a filtered view must not drift because background import/search changes. Let users decide whether the export includes unique messages or each folder occurrence and disclose any intentional duplication. |
| OUT-03 | Complete or verify | Preserve supported headers, bodies, inline MIME parts, attachments, names and source/folder mapping. Record format-induced changes and omissions. Verify decoded attachment bytes, not filenames alone. |
| OUT-04 | Complete or verify | Extend existing receipts/manifests into a clear reconciliation of selected, written, checked, excluded and failed items. Reopen/reparse all outputs for a full-verification status; a sampled check must say sampled. Verify exported payload against source records as well as output-file integrity. |
| OUT-05 | Complete or verify | Exercise destination compatibility with supported versions of Apple Mail and, where claimed, Thunderbird. Use an independent reader or fixture oracle so a shared bug in mailin's importer and exporter cannot validate itself. Record exact software versions and workflows tested. |
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

Do not spend this release expanding analytics, studios, personas or live mail. Proposed new formats join the required matrix only after an explicit scope decision; they must not silently displace completion of existing advertised formats.

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

## 10. Proposed decisions and deferred expansion

These boundaries resolve the differences between earlier recommendations without silently expanding the owner's approved five-job goal.

| Item | Consolidated treatment |
|---|---|
| OLM input | High-priority proposal for a Mac archive product. No reader was established in reviewed routing. If adopted, add real fixtures and all six dimensions of format acceptance before promising support |
| TAR/TGZ input | Proposed wrapper addition. GZip alone does not imply TAR extraction. If adopted, test all members, integrity, path safety and supported enclosed mail |
| Post-expiry reading and basic portability export | **Adopted by the owner, 6 November 2026.** The policy decision is closed; implement and test the access matrix in section 12.2. Preserve all existing data and purchased rights |
| Exact performance thresholds | Engineering targets in section 8.1, not demonstrated speed claims or artificial maximums. Record executed results; identify unexecuted larger-file tiers under the owner's resource-budget decision. No 100 MB app cap or universal capacity claim follows |
| New saved-search tools, search-within-results, typo assistance and richer attachment browsing | Later retrieval improvements; retain existing working conveniences |
| Batch archive queues, selective mailbox import and incremental snapshot comparison | Later import improvements with stable source identity; not substitutes for reliable current imports |
| Guided storage relocation and cross-archive comparison | Later convenience work unless needed to make an already advertised workflow safe |
| Shared attachment-storage deduplication | Later, after reference integrity, deletion, backup, migration and honest physical-space accounting are proven |
| Legacy document extraction and searching inside compressed attachments | Later format projects with their own extraction, security and fixture evidence |
| Additional native-store formats and PST/OLM writers | Separate reader/writer projects; no blanket “all formats” promise |
| Standalone output verifier and extra destination presets | Later trust/portability improvements; durable verification inventories are required now |
| More AI, analytics, investigation workflows/personas and general inbox/live-mail features | Expansion frozen/deferred for this release; preserve existing customer access and records |

If a proposed item is adopted, update this master, the requirement matrix, tests and public promise together. Do not resolve an optional decision by quietly counting it as completed or required. Existing paid capabilities remain protected even when their expansion is deferred.

## 11. Implementation handoff and required deliverables

Use this document as the sole mailin next-release execution brief. First reconcile its baseline with the actual app source; then implement or verify all 30 core items and six LIFE checks. Keep existing data, purchase rights and holds intact. Do not mark work complete based only on parser classes, successful compilation, file creation or a demonstration on a small archive.

Deliver the following together:

1. The focused application changes, with safe schema migration and preserved existing customer capabilities.
2. The requirement tracker covering all 36 IDs, with actual pass/fail evidence and unresolved issues.
3. A per-format support matrix covering import, extraction, folders, search, duplicate comparison and export independently.
4. Reproducible fixtures and automated/integration checks for content correctness, complete scope, recovery and output fidelity.
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

Two search requirements are expressly still open in the report: the ordinary search box uses the previous engine, and attachment evidence opens only the parent message. Keep FIND-04/FIND-05 partial until these paths meet section 5.3. Implementation of the new LIFE-06 policy and the presentation change also needs evidence.

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

Use existing valid evidence rather than repeating completed work without a reason. The following is a closure list based on the supplied report, not a new feature expansion.

| Remaining item | Exact closure condition |
|---|---|
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

Release the complete five-job product when the remaining functionality and required evidence above pass, with the owner's explicit scale-evidence limitation recorded. Do not impose an artificial 100 MB product cap and do not market untested infinity. Keep the planned larger workload matrix available for future verification.

The release record must distinguish **implemented**, **executed and passed**, **not executed**, **observed limitation** and **owner-approved validation scope**. A final release label is not proof that every conceivable file/device combination has been tested.

Apple asks for tested device/OS information and accurate, complete feature and purchase information during review. Prepare that information for the actual candidate. [Complete review information](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## 13. Completion contract — COMP-01…20 and the R01…R07 regressions (6 November 2026)

Transcribed into the repository from the owner's handoff `Mailin_Product_Completion_Instructions_7481852_2026-11-06.md`
(§4 "Acceptance cases", §2 "Immediate remaining defects"), which reproduces the scope of the consolidated plan
version 7 §13. The consolidated plan file itself was not supplied to the repository; this section is the
authoritative copy of its acceptance cases until it is. These cases extend the 30 job rows and six LIFE checks;
they do not replace them. Decision in force: preserve completed work; finish architecture, format coverage,
recovery and verification; the five jobs remain the product. The owner has approved the five-job identity and
LIFE-06 — neither is asked again.

### 13.1 Regressions found at 7481852

| ID | Defect | Instruction |
|---|---|---|
| R01 | The ordinary-search translator expands OR alternatives into conjunctive groups (exponential; 64-group cap then folds to all-words; unchecked multiplication) | Represent Boolean structure without expansion; preserve phrases, branch-local negation and same-document conditions; checked arithmetic; never silently run a different query |
| R02 | Literal verification removes 512 SQLite code points where the chunker overlapped 512 Swift Characters (Unicode mismatch); literals longer than a chunk change mode; Limits text stale | One offset unit across storage, SQL, snippets; verify long phrases without changing mode; Unicode boundary tests |
| R03 | GZip payload name derived from the temporary file URL; dispatch trusts temporary extensions | Pass an immutable logical filename; sniff the payload; preserve `.tar.gz` / `.txt.gz` semantics |
| R04 | EML and RTF inside archives decoded as raw strings before their readers | Route EML/MSG/TNEF/embedded packages through semantic adapters producing children; RTF through the decoder |
| R05 | Budgets are stopping rules; the gzip budget is checked after full decompression | Enforce budgets inside the production of bytes; turn exhaustion into a paused, resumable state; never call paused work complete |
| R06 | An unverified export (inventory failed) has no repair or Verify action | "Finish inventory" / "Verify export" from the retained manifest; keep written / hashes recorded / rehash checked / content reconciled distinct |
| R07 | LIFE-06 archive-access record has no production clean-profile transition test; refresh after restore/switch missing | Explicit initialisation; refresh after restore and archive change; visible failures; sandbox journeys |

### 13.2 Acceptance cases

| ID | Required customer outcome |
|---|---|
| COMP-01 | Real ANSI/Unicode PST: empty/deep/repeated/Unicode folders, varied bodies/attachments/properties and non-mail inventory reconcile. |
| COMP-02 | Real OST: accessible content works; cache-only headers and missing server content remain distinct. |
| COMP-03 | Real OLM: hierarchy, categories, dates and embedded documents survive import and search. |
| COMP-04 | MSG/OFT/TNEF/embedded messages: correct recipients, body variants, CID and complete child tree with original hashes. |
| COMP-05 | Actual legacy Word/Excel/PowerPoint: known section/cell/annotation terms are found without Office installed. |
| COMP-06 | Declared macros/templates/shows/XLSB and Strict/Transitional variants: correct detection/extraction; active content never runs. |
| COMP-07 | Excel hidden/comment/late-cell/formula-result-only matches: accurate location, raw/displayed/formula classification and no invented result. |
| COMP-08 | Word header/text-box/footnote/comment/deleted-revision-only matches: correct section/revision labels. |
| COMP-09 | PowerPoint notes/hidden slides/tables/chart labels: accurate evidence and navigation. |
| COMP-10 | Declared OneNote/Visio/Project/Publisher/Access versions: stored content searchable with appropriate location; linked-only content distinct. |
| COMP-11 | Real ODF and old/new iWork: actual document content found; thumbnail-only extraction fails this case. |
| COMP-12 | Nested ZIP/7z/RAR/TAR/GZip: full tree, repeated filenames, encrypted members and missing volumes handled; no path escape. |
| COMP-13 | Protected PDF/Office/container: correct/wrong password, cancel/retry/restart and chosen credential retention work. |
| COMP-14 | Mail encryption/signatures/IRM/cloud references: authorized paths work; unavailable credentials/rights/content never become false no-matches or complete exports. |
| COMP-15 | PST/OLM/EML equivalents and changed attachments/revisions: correct duplicate classes, preserved memberships/notes/holds, undo. |
| COMP-16 | EML/MBOX/PST/MSG consumed independently: selection, folder, content and attachment reconciliation with durable inventory. |
| COMP-17 | Ordinary/advanced equivalent searches, incomplete negative queries and same-child predicates: identical semantics and honest coverage. Includes R01/R02. |
| COMP-18 | Import → detach original → restart → find nested Office file → backup → clean-profile restore → export: originals/relationships survive. |
| COMP-19 | Malformed documents, expansion attacks, worker crash, disk-full and external interruption: contained failure, checkpoints and recovery. Includes R03–R06. |
| COMP-20 | Clean install, entitlement changes and human five-job pilot: ordinary work needs no Office installation, existing-data access survives, people notice partial results. |

For each case the tracker records: implemented / test executed / passed or failed / evidence location / known
limitation / external dependency. A synthetic-fixture pass never implies real-origin compatibility. Expected
unsupported or locked states are conditional cases, not successful extraction of healthy required content.

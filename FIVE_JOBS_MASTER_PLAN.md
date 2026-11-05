# mailin — consolidated next-release master plan

**Prepared:** 5 November 2026  
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

**Customer outcome:** “I can find the actual document, even if I forgot which email contained it.”

| ID | Status | Required work |
|---|---|---|
| FIND-01 | Fix | Extend the ordinary attachment index beyond its current PDF-text/RTF/HTML/plain-text paths to DOCX, XLSX and PPTX as required release coverage. Extract useful document text and spreadsheet/slide context without executing macros or embedded content. |
| FIND-02 | Fix | Connect image and image-only PDF OCR results to ordinary archive search. Reuse existing OCR services where sound. Preserve the original bytes and distinguish recognised text from original document text. Do not advertise unsupported OCR languages. |
| FIND-03 | Fix | Replace a simple “attempted” state with meaningful coverage: queued, processing, searchable text extracted, processed with no text found, unsupported, locked, failed, cancelled and truncated. Retain extractor version so newly supported types can be retried without reimporting mail. |
| FIND-04 | Complete or verify | Search sender, recipients, subject, body, attachment filename and extracted content with source/folder/date/type filters. Provide a usable literal-search default; advanced syntax must not turn ordinary punctuation into confusing errors. Test English, Bengali and Hindi text independently of OCR coverage. |
| FIND-05 | Complete or verify | Each result identifies the matching email or attachment and opens the correct parent message. Show a snippet and, where the extractor supports it, page/sheet/slide context. Two attachments with the same filename must remain distinguishable. |
| FIND-06 | Complete or verify | Run extraction in bounded jobs with timeout, memory, decompression and nesting budgets. Make work resumable where possible; an interrupted or guarded extraction stays explicitly incomplete. Keep encrypted-file handling explicit; never treat failure to unlock as proof of no matching content. |
| FIND-07 | Fix | Remove permanent prefix-only indexing, including the 500,000-character attachment cutoff. Store/index bounded chunks with stable parent/page offsets and query across all chunks. Test the end of long documents and words/phrases crossing chunk boundaries; changing chunk size must not change recall. |

Apple documents on-device OCR through Vision and says supported languages depend on the recognition path/revision. Query actual runtime support rather than assuming every language is available. [Apple Vision](https://developer.apple.com/documentation/vision/recognizing-text-in-images?changes=_9)

SQLite FTS5 already supports useful building blocks including phrase/prefix queries, Boolean combinations, snippets and highlighting. Reuse the existing database/search architecture where practical; these building blocks do not themselves prove correctness of mailin's extraction, multilingual tokenisation or UI. [SQLite FTS5](https://sqlite.org/fts5.html)

**Later:** saved searches, “search within these results,” attachment-only browsing, safe indexing inside supported compressed attachments, typo-tolerant suggestions and optional natural-language query assistance. Plain deterministic search remains independently usable.

**Acceptance:** place known target strings only inside attachments, not their filenames or parent messages. Verify retrieval in each advertised format, and separately measure OCR retrieval on a labelled scan set. Check unsupported/encrypted/truncated items are visible. An OCR job completing is not proof that every word was recognised. Test query correctness and performance on the same scale matrix used for import.

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
| LIFE-06: ownership and access policy | Define and test reading, searching, new imports, exports, offline entitlement checks, subscription expiry, refund and purchase restoration separately. Imported data must never be automatically deleted because an entitlement changes. Recommended policy for the owner to adopt: keep reading and basic portability export of already imported data available after subscription expiry, while new paid work remains governed by the plan. This recommendation does not change pricing, existing trial rules or existing purchased rights in this document; the final policy must be explicit before release. |

**Why LIFE-01 matters now:** the reviewed format document says oversized messages can retain byte locators into the original source, and that those originals are referenced rather than copied. The source-independent archive test therefore covers a real documented dependency. [Source-reference behavior](https://github.com/sasmalgiri/mailin/blob/a8e875883b7888fb59efc093402996370ad37594/SUPPORTED_FORMATS_AND_LIMITS.md#L126)

**Backup implementation constraint:** use a database-supported snapshot strategy and coordinate it with the external blob/source inventory. SQLite documents incremental online backups and the relationship between the database and its WAL; copying an active main database file alone is not a sufficient whole-app backup design. This requirement does not mandate one particular library. [SQLite backup](https://www.sqlite.org/backup.html) · [SQLite WAL](https://www.sqlite.org/wal.html)

**One combined preservation test:** import a representative archive into self-contained mode; verify counts/content; detach the original test source; restart; find a document inside an attachment; identify a changed version correctly; create a backup; restore it in a clean profile/device; rebuild its index if needed; then export and independently verify the selected mail. Repeat key stages around an interrupted job and an app upgrade. Use disposable test sources, never remove the owner's real source archive as part of testing.

Each LIFE check needs evidence on the same release candidate as the 30 core work items. Existing working behavior may satisfy a check after execution; there is no requirement to rewrite passing code.

### 6.1 Supporting help and access deliverables

Keep help attached to the task: a first-import quick start, a sample archive, a searchable guide covering the five jobs and format states, and contextual explanations for incomplete search, duplicate classes and export verification. Hover text supplements clear labels; it cannot be the only instruction available to keyboard, touch or VoiceOver users. A carousel is optional and skippable, not a release goal by itself.

For LIFE-06, maintain one tested capability table covering reading, search, import, export and recovery under active entitlement, trial, offline use, expiry, refund and restored purchase. Preserve data in every state. The proposed post-expiry reading/basic-export policy in section 10 remains a policy choice, not an automatic code change.

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

These are development targets to validate, not existing performance claims or artificial maximums.

| Workload | Target and evidence |
|---|---|
| Large Mac archives | Exercise 1, 5, 20, 50 and 100 GB MBOX and valid Unicode PST workloads, recording actual runs and failures. Use a declared 16 GB Apple-silicon Mac/SSD reference configuration with sufficient source, index, temporary and output storage. Larger archives should remain an architectural possibility, not be rejected simply because they exceed the test tier. |
| Message count | At least 1,000,000 messages, including both small-message and attachment-heavy workloads. Vary message count independently of byte volume. |
| Folder count | At least 10,000 folders/labels across multiple sources, including collisions, Unicode paths and multiple memberships. |
| Search completeness | Known targets beyond 500,000 attachment characters and the former 4 MiB body-index budget must be found, including phrases crossing chunk boundaries. Include individual messages beyond the documented 100 MiB source-locator threshold in reading/search/export tests. Require exact expected retrieval for deterministic supported text fixtures. |
| OCR | Maintain labelled samples per advertised language and image class; report measured retrieval accuracy and failures. Completing OCR is not a guarantee of recognising every word. |
| Responsiveness | Initial target: p95 warm first-page display and ordinary indexed search within 2 seconds on the declared reference corpus/hardware. Record cold-search and background-import performance separately; heavy queries may use visible cancellable progress. |
| Recovery | Process termination, low disk, source changes, locked files, removed drives at a batch boundary and during a write, and output tampering are exercised. Confirm correct state after relaunch. |
| Mobile | iPhone/iPad get separate measured workloads, OS/device records and suspend/relaunch tests; Mac success never substitutes for mobile evidence. |

If a target fails, record the cause and keep the relevant release requirement open. Do not silently convert an unexecuted benchmark into a passed capability claim. Preserve format-specific validity constraints; for example, a size that is valid for one PST variant does not make it valid for every variant.

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
9. Every claimed benchmark has executed results tied to a commit, build, device/OS and dataset. Unrun tests and projections are not passes.
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
| Post-expiry reading and basic portability export | Recommended access policy, not yet adopted. Preserve data and existing rights regardless; decide and test the final capability table before release |
| Exact performance thresholds | Engineering targets in section 8.1, not demonstrated speed claims or artificial maximum archive sizes; measure and record each result |
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



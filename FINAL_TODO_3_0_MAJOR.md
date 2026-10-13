# mailin 3.0 (major release) — final to-do list

Owner decision 2026-10-13: everything built under the "3.1" label — recovery, scripting, team review and forensic timestamps — ships inside 3.0.

This list holds every item not yet done, with:
- how to solve it,
- where the work goes in the code,
- what "done" means.

Work it in the order of the phases.

Legend:
- 🔴 blocks release
- 🟠 should ship
- 🟢 can follow in a point release

---

## Phase A — Turn 3.1 into 3.0 (release consolidation)

| # | Item | How | Done means |
|---|---|---|---|
| A1 🔴 | **Purchase gating for the new features.** Today the Recovery, Review Pack, Scripts and Team tabs live in Settings. `StoreManager.requiredTier` treats Settings as `.free`, so the Professional page switch is the only gate: anyone who turns the page on can use these features without buying | Add tier checks where each surface is offered, not by moving screens: Recovery center → Personal; carving / deep recovery → Professional; Scripts, Shortcuts *actions*, forensic timestamps, creating a Review Pack, merging responses, starting or applying a team case → Professional; reviewing a received pack, joining a case → Free. Reuse `storeManager.requestPurchase(...)`, the same pattern the Professional page tool strip uses. Add a `ProFeature` case for each, so `hasAccess(to:)` covers them | A ProfessionalGatingTests case per surface: Free tier is refused, the correct tier is allowed; the UI shows the lock with its reason |
| A2 🔴 | **Free-tier scope rule** (newest 500 in any list or search) in the new engines | Scripts, Find Emails, CSV export, Review Pack and Team case read through `ScopeJobEnvironment.archive`. Confirm the data-layer rule applies there, or route the reads through the same gated call the archive list uses | Test: a Free-tier archive of 600 emails — the script dry run, Find and the pack cover 500 and say "500 of 600" |
| A3 🔴 | **Version labels.** The names still say "(3.1)", e.g. "Deleted-email recovery (3.1)" | Remove "(3.1)" from the `EngineSpec` names and other user-facing strings. **Do not rename the `v31…` raw values**: they are persisted keys, pinned by `testPersistenceKeysArePinned`. Re-translate the changed keys | `grep "(3.1)" maxmailin/*.swift` is empty; translations complete |
| A4 🔴 | **Promotion decision** (rule 15) | Each `v31…` capability stays `.preview` until its gate passes (phases B–D). Then set `maturity: .stable` for the gated ones and update the M1/3.1 previews test to the new expectation, just as the M5 3.0 promotion was done (`148183e`) | Owner signs off per switch; the capability matrix tests pass |
| A5 🔴 | **Schema v20 on real 3.0 archives** | Open the kept 1M archive (schema v19) in this build: the snapshot is taken, v20 is added, nothing changes. Then turn recovery on and import a mailbox | Snapshot on disk; counts identical before and after; v20 tables exist; the 3.0 rollback switch still reads the archive |
| A6 🟠 | **Release documentation** | Fold `TODO_3_1_RECOVERY_SCRIPTING_TEAM.md` results into `SHIP_3_0.md`. Update the release notes, App Store description, keywords (recovery, scripting, team review), `AppReviewNotes.md` (the scripts answer is already written), the free/paid table and `SUPPORTED_FORMATS_AND_LIMITS.md` (already updated) | Owner reads and approves |
| A7 🟠 | **Screenshots** for the new features | Recovered folder plus evidence badge; Recovery center; Scripts dry run; Review Pack reviewer; Team dashboard; timestamps panel | Mac and iPhone sets, sample data only |

## Phase B — Not built yet

| # | Item | Solution (researched) | How to implement | Done means |
|---|---|---|---|---|
| B1 🟠 | **Gmail hidden timestamps** (F1) | The Gmail RFC `Message-ID` (`<CA…@mail.gmail.com>`) has **no decodable time**; don't claim one. Two Gmail values do carry one ([Metaspike part 2](https://www.metaspike.com/gmail-mime-boundary-delimiter-timestamps/), [part 3](https://www.metaspike.com/dates-gmail-message-id-thread-id-timestamps/)). (1) The **MIME boundary** `000000000000` + 6 hex + 8 hex + 2 hex: move the 8-hex group in front of the 6-hex group, read it as hex, and the first 13 digits are Unix milliseconds. (2) **X-GM-THRID / X-GM-MSGID** (in Google Takeout): convert to hex; the leading hex digits are a millisecond timestamp. Check the exact digit count against the Metaspike article before shipping. Also add **v1 GUIDs** in Message-IDs (RFC 4122 timestamp, 100-ns ticks since 1582) | `HiddenTimestamps` in `ForensicSignals.swift`: add `gmailBoundary(_:)`, `gmailInternalID(_:)`, `uuidV1(_:)`, and call them from `all(headers:rawSource:)` | Tests built from the published worked examples (boundary `000000000000b6809105a0ae7b18` → 2020-03-12 20:49:03.864 UTC). Random or v4 IDs decode to nothing |
| B2 🟠 | **ARC-Seal chain** (F3) | RFC 8617 §5. For each instance *i* (1…n), the ARC-Seal signs, in **relaxed** header canonicalization, every header of the sets 1…*i* in order: `ARC-Authentication-Results`, `ARC-Message-Signature`, `ARC-Seal`, with the `b=` value of the seal being checked emptied. Same keys (`d=`, `s=`) as DKIM. Chain rules: `i=1` must have `cv=none`, every later one `cv=pass`, no gaps; the newest AMS must verify (already built) | `DKIMVerifier.verifyARCChain(rawSource:keys:) -> ARCResult` (pass / fail(at: i, why) / noKey). Reuse `relaxedHeader`, `parseTags` and the key cache. Add the result to the timestamps panel | Hand-built chains of 1 and 3 hops pass; a changed AAR, a `cv=fail` and a missing set each fail at the right instance; one real forwarded message passes, with its keys captured once by you |
| B3 🟢 | **Lotus Notes deletion stubs** (R8) | Public facts ([HCL C API RRV_xxx](https://opensource.hcltechsw.com/domino-c-api-docs/reference/Symb/RRV_xxx/), [Anatomy of a Note ID](https://opensource.hcltechsw.com/domino-c-api-docs/howto/user_guide/Anatomy_of_a_Note_ID/), [libnsfdb format notes](https://github.com/libyal/libnsfdb/blob/main/documentation/Notes%20Storage%20Facility%20(NSF)%20database%20file%20format.asciidoc)): a note ID is the file position of its **RRV** entry; a deleted note's ID carries **`RRV_DELETED` = 0x80000000**. A stub keeps only the UNID, note ID, sequence number and dates. The on-disk stub layout is **not** publicly documented (libnsfdb lists it as to-do), so the known structures must be reverse-checked against real files | (1) In `NSFParser`, read the superblock (RRV bucket size, data RRV bucket position, soft-deleted count at offset 78). (2) Walk the RRV buckets. (3) An entry with the deleted bit, or a note header with the "deleted" status flag, becomes a `.deletionStub` record (UNID, sequence, dates; no body; marked partial). Use libnsfdb as **reading reference only** (LGPL, never linked) | Needs from you: two NSF files made in HCL Notes, with known deleted documents (one with the purge interval off), plus the count from `NotesDatabase.GetModifiedDocuments` (deleted). Our stub count equals it. Until then, keep the "not supported" line in the limits doc |
| B4 🟠 | **R12 import preview** | The import sheet should say what recovery will do before the run starts | Where the import preview shows source size and engine: "Recovery is on — deleted mail is marked", and when deep recovery is on "Deep scan adds about N min" (estimate at about 1 GB/s from the measured carve speed) | UI check; 10 languages |
| B5 🟢 | **S1: more Shortcuts entities** (Matter, Document, Tag) | `AppEntity` plus `EntityQuery` over `legal_holds` matters, `DocumentRegistry` and tag counts, the same pattern as `EmailEntity` | Each appears in Shortcuts' Find actions; the counts equal SQL |
| B6 🟢 | **S8 / S9 polish** | A one-page help sheet per bundled script; recipe conditions `hash equals`, `received IP in range`, `header matches`, so every bundled script can be rebuilt as a recipe | Test: for each bundled script, a recipe produces the same changes on a fixture |
| B7 🟢 | **T2 MDM identity**, **T9 shared redaction profiles**, **T11 merged-audit verification** | T2: read the managed-config user name and role into log entries. T9: store redaction profiles in the case folder (a signed file). T11: a "Verify audit" button that re-checks every log signature and chain | Tests per item |
| B8 🟢 | **Outlook-loadable PST export** (pre-existing: README says "experimental") | `PSTWriter` writes a simplified property context (bytes `0x0C 0x7C`, not the [MS-PST] heap-on-node `0xEC` + `0xBC`/`0x7C`), and no AMap/PMap, so Outlook won't open it. A real writer needs heap-on-node + BTH + property contexts + table contexts, AMap and DList, and correct NBT/BBT levels | A new `PSTWriterV2` behind a switch (rule 14). Validate with the free `pffexport` tool run externally, and by you in Outlook on Windows | Outlook opens it, item counts match, folders kept. Until then, keep "experimental" |

## Phase C — Hardening found by the tests

| # | Item | How | Done means |
|---|---|---|---|
| C1 🔴 | **Hostile scripts** (beyond loops) | Add tests and guards for: a huge allocation (`new Array(2**31)`), string doubling, deep recursion, a huge `report` output, `mailin.column` with very large values. Cap value length at write time (state the cap on the Scripts screen), and wrap `run` so a JavaScriptCore exception or out-of-memory error becomes `ScriptError.watchdog` | Each hostile script is stopped and reported; the app stays up; memory returns |
| C2 🔴 | **iOS / iPadOS pass on the new screens** (never run) | `ScriptsView` and `TeamCaseView` use `NavigationSplitView` inside Settings tabs and sheets; `fileImporter` for folders behaves differently on iOS (security scope, Files). Run each screen on the iPhone and iPad simulators with the device-interaction tools; fix layouts (use `NavigationStack` on compact width); check that "Open a case folder" works with iCloud Drive and SMB in Files | Screenshots of every new screen on iPhone and iPad; the shared-folder flow works from Files |
| C3 🟠 | **Scale for Review Pack and Team case** | Opt-in (`MAILIN_SCALE=1`) tests: pack 100k emails (build, open, respond, merge); team case 100k log entries over 3 reviewers (load time, memory) | Numbers in `SCALE_RESULTS.md`; memory flat; load time under 2 s with incremental reads |
| C4 🟠 | **Shortcuts Find at 100k** | `EmailEntityQuery.find` calls `StorageActivationCoordinator` and production singletons; route it through `ScopeJobEnvironment` like the other engines, then measure | 10,000 results in under N s, memory flat |
| C5 🟠 | **Real deep recovery on Outlook PSTs** | Our freed-space test uses our own writer's format. Run `carveUnallocated` on real Outlook files: the Tika `testPST.pst`, plus a PST you make in Outlook where items are deleted and Deleted Items emptied, without compacting | At least the emptied items reported as carved and partial; no false items on the Tika file |
| C6 🟠 | **Real Thunderbird and Apple Mail mailboxes** | Your own profile: delete messages without compacting, export the folder | Our "unpurged" count equals the number deleted; Apple Mail's Deleted Messages counted |
| C7 🟢 | **DKIM provider dates** (F2 table) | Check each "signs all mail since" date against the providers' own announcements; keep only sourced dates, each with its source in a comment | Every row has a citation |

## Phase D — Verification that needs you or a device

| # | Item | How | Done means |
|---|---|---|---|
| D1 🔴 | **Accessibility audit** (fails since 2026-10-12, 3.0 screens) | Work through the audit report: label list Section headers and containers (`.accessibilityElement(children: .contain)` + `.accessibilityLabel`); label outlines/lists; give image-only buttons and menus labels (`square.and.arrow.up`, `arrow.up.arrow.down`); fix "Contrast failed" (`secondary.opacity(0.7)` captions → `.secondary`, no small text below 4.5:1); find the unlabelled element at 0,0 685×30 (type 81 — likely a window or Touch Bar element) with Accessibility Inspector. Re-run `AccessibilityAuditUITests` until green. The test should audit the Archive page, Professional page and Settings explicitly (it currently audits whatever page the window was left on) | Audit test green on all three surfaces |
| D2 🔴 | **Shortcuts on a device** | Turn on Shortcuts actions; in the Shortcuts app run Find, Count, Tag, Place Hold, Bates, Verify, Export CSV. From Terminal: `shortcuts run "mailin Export" --input-path q.txt --output-path out.csv`. Check the confirmation prompts and the role refusal (managed Viewer) | Checklist ticked on Mac and iPhone; the example in `SHORTCUTS_AUTOMATION.md` verified |
| D3 🔴 | **Real shared folder** | Make `V31SharedFolderTests` take `MAILIN_SHARE_PATH`. Run it on (a) macOS File Sharing over SMB (`smb://localhost` or a second Mac), (b) a NAS if you have one, (c) an exFAT USB drive. Fault runs: unplug or turn Wi-Fi off mid-write; two Macs with clocks set 10 min apart | Same state on both Macs; torn writes reported, not lost; leases exclusive over SMB (`O_EXCL` honoured) |
| D4 🟠 | **Full UI crawl with all new switches on** | Turn every new switch on (in a UI-test launch argument), run `testRealMailbox_importThenPressEveryButton` and the click-through tests | Green; every new button reached |
| D5 🟠 | **Apple Intelligence script assistant** | On an Apple Intelligence Mac, draft each bundled goal from a sentence | Drafts compile ("Check" passes) for most goals; record the failures |
| D6 🔴 | **TestFlight cycle** | Build, upload, install on your devices, run the "new in 3.0" checklist (A–D) | No crash in Xcode Organizer for a week of use |

---

## Suggested order

1. A1 → A2 → A3 (gating and labels: small, and they block release).
2. C1, C2 (hostile scripts, iOS pass).
3. D1 (accessibility audit), B1, B2, B4 (small, high-value forensic items).
4. C3–C6 (scale and real-file runs; C5/C6 need files from you).
5. D2, D3, D4, D5 (device and owner sessions).
6. A4 promotion → A5 → A6/A7 → D6 TestFlight → submit.
7. B3, B5–B8 can ship in 3.0.x if time is short. Each is behind its own switch, and the limits doc already states what is missing.

## What you need to provide

- **B3:** two NSF files from HCL Notes, with known deleted documents and their counts.
- **C5:** an Outlook PST with deleted items, made without compacting.
- **C6:** a Thunderbird folder, not compacted, after deleting messages.
- **B2:** one forwarded message that passed through Gmail or Microsoft 365, plus its domains' DKIM/ARC DNS records, captured once.
- **D3:** a second Mac or a NAS for the share runs; presence for SMB unplug tests.
- **B8:** Outlook on Windows (only if the Outlook-loadable PST is in scope).
- **D1–D5:** presence on the Mac to approve automation.
- **A4:** the promotion sign-off per switch.

---

## Progress

| # | State | Commit | Notes |
|---|---|---|---|
| A1–A3 | Done | 7169a63 | One `TierAccess` table; `TierGate` on every new screen; "(3.1)" removed from names (persisted keys unchanged) |
| B1, B2, B4 | Done | de14344 | Gmail boundary µs and X-GM-MSGID/THRID ms (Metaspike examples), version-1 UUIDs; ARC chain per RFC 8617 — ValiMail open suite 166/168, the 2 differences pinned; import sheet states what recovery will do |
| C1 | Done | dcd4381 | Native allocation guards, memory checked inside loops, 64 KB value cap, deep recursion reported, async/generator constructors blocked, API frozen; limits stated on screen |
| C5 | Partly done | 1ed892b | New MS-PST reader checked on 15 real Outlook PSTs (Digital Corpora): items, Message-IDs, subjects, senders and deleted-folder counts equal `readpst`; deep recovery on all 15 invents nothing readable as noise. Cyclic encoding verified by re-encoding all 15. **Still needs** an Outlook PST with Deleted Items emptied (owner) for the "emptied items carved" half |
| C6 | Partly done | 1ed892b | Thunderbird: 828 public messages, 35 deleted-but-unpurged, equal to an independent scan, through both import engines. **Still needs** the owner's Apple Mail Deleted Messages folder |
| C2 | Partly done | see below | iPhone 17 simulator, all four new Settings screens. Found and fixed: Scripts was blank (a split view nested in the More tab's stack) — now a list with each script in a sheet; sheet minimum sizes (640–680 pt) pushed content off a phone — now macOS-only; team coding buttons ran off the screen — now scroll sideways; cut-off intro and AI hint; empty "Yours" section explained. Recovery, Review Pack and Team fit. Seen, not changed: disabled Label buttons in a Form keep a black title on iOS 27 (system drawing; the reasons are stated beside them); the Settings tabs show no title of their own on iPhone, like the older tabs. **Still open:** iPad pass, and the shared-folder flow from Files (D3) |

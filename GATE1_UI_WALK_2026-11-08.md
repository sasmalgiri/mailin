# Gate 1 hand-walk — five journeys + LIFE checks on iPad (2026-11-08)

**Build walked:** branch `v3-architecture` at `b9db4e6`.
- **Release** configuration, built with `xcodebuild … -configuration Release -destination 'platform=iOS Simulator,id=7922C0FA…' CODE_SIGNING_ALLOWED=NO`, installed with `simctl install`, on **iPad Pro 13-inch (M5) simulator, iOS 27.0**. Clean install (the earlier app container was uninstalled first). Tier = **Free** (no StoreKit purchase is possible in a Release simulator build).
- A **Debug** build (Xcode Install & Run, `-mailinSimulateTier professional`) was installed afterwards on the same archive data, only to walk journey 4 (duplicates), which is Personal+ and so is behind the paywall in a Free Release build. Debug results are labelled **[Debug/Pro]**.
- Mac UI was not walked (Mac automation needs the owner). Several findings below are **iPad-only**: the three-pane archive, the folder tree (`ArchiveSidebarView`), the Import Receipt window and backup/restore folder pickers are all `#if os(macOS)`.

**Test data** (`/tmp/gate1data/gen.py`, synthetic): an Apple Mail export layout `MailExport/{Inbox.mbox (26), Work.mbox (17), Work.mbox/Clients.mbox (8), Archive 2019.mbox (empty)}` = 51 messages, zipped as `MailExport.zip`. It includes a PDF ("Pelican budget overview"), a DOCX ("lighthouse renovations"), a ZIP holding `inner/Contract.docx` ("The secret codeword is **zebracrossing** quarterly."), Unicode subjects (`Café ünïcödé — 日本語 件名 ✓`, `Привет мир`), one message with the same Message-ID in Inbox and Work, and a near-duplicate (same subject, body differs by "!", different Message-ID).

**How the data got in:** writes into the simulator's containers from the host hung (no permission prompt could be approved), so the file was opened with `simctl openurl file:///tmp/gate1data/MailExport.zip`. Files saved it to *On My iPad* and unzipped it, and the app's own **Open Email Archive** picker was used from there. iPadOS cannot pick the unzipped *folder* (the picker's Open stays disabled on a directory), so the ZIP was the only way to import a folder layout on iPad.

Screenshots: `gate1-screenshots/` (numbered in walk order).

---

## Summary

| # | Journey / check | Result | One-line evidence |
|---|---|---|---|
| 1 | Open a large archive | **Partial pass** | Pre-import sheet is honest (type detected, Free allowance, space estimate, duplicates policy). 51 of 51 imported. On iPad you **cannot see the import receipt** (it is a Mac-only window), and progress could not be seen at this size |
| 2 | Preserve folders | **FAIL** | The backup inventory records `folders: 0, folderMemberships: 0`. The iPad "Folders" list shows only `All Emails 51 / Inbox 51 / Has Attachments 3`, so Work, Clients and the empty Archive 2019 are missing |
| 3 | Search messages + attachments | **FAIL (iPad search box)** | `zebracrossing` (DOCX inside the ZIP), `lighthouse` (DOCX) and `in:attachments zebracrossing` all return 0 with a **blank pane and no "no match" notice**. The text **is** indexed (`search_chunks` holds it as `childText`), but the plain box uses the previous year-sharded FTS index |
| 4 | Duplicates safely | **Partial pass [Debug/Pro]**; **paywall on Free Release** | Exact group verified and the count shown before acting ("1 redundant copies move to the Trash"); the archive went 51→50. The near-duplicate was not offered as a candidate; the Trash cannot be reached on iPad, so restore could not be walked; counts are stale afterwards |
| 5 | Verify exports | **Pass (with caveat)** | mbox export: pre-flight "51 emails", receipt "Complete — 51 written; selected 51 · written 51 · excluded 0 · failed 0 · selection frozen at start"; **Verify export** → "rehash checked… content checked: 51 of 51". Caveat: the receipt says Complete even though the share sheet was closed without saving |
| L1 | LIFE-01 self-contained | Pass (observed) | Health ▸ Original files: "Copies of imported files, 5 KB — new imports are copied into the archive and checked byte for byte"; backup inventory `linkedSources: []` |
| L2 | LIFE-02 backup / restore | **FAIL on iPad** | "Back up archive…" reports "Backed up 51 emails, 7 files (1.1 MB) to mailin-backup-…", but the backup is written to the app's **tmp** folder, which the user cannot reach and iOS may purge. "Restore from backup…" says it is done on the Mac |
| L3 | LIFE-03 fields / concurrent jobs | Not walked | Headers in the reading pane show From/To/Date/Message-ID correctly; concurrent jobs not exercised by hand |
| L4 | LIFE-04 privacy / safe handling | Partial (observed) | Plain-text view, "Quoted text hidden", risk badge; diagnostics "kept on this device", "Nothing was sent anywhere". A Speech Recognition permission prompt appears on first launch before any switch is on (see F-9) |
| L5 | LIFE-05 recovery / help | Pass (observed) | Health: Integrity "Run full check" → OK; Rebuild search index; Recover missing imported attachments; snapshots; 3.0 engines tripped 0; crash/hang 0. Duplicate Manager has an inline "How to use" sheet |
| L6 | LIFE-06 access policy | Pass for Free (observed) | Free Release: browse/search/view and mbox export (51 written) work; Dedup / Recovery / per-attachment Download are gated with an upgrade path. The paywall matrix says "everything you imported stays yours…" |
| — | Resume after quit | Pass | `simctl terminate` + relaunch: 51 emails, the date range and the search index all intact |
| — | Ask to Buy test | **Not run — the iOS test target does not compile** | See F-1 |

---

## Findings (bugs) — repro steps, no code changed

**F-1 (blocker for iOS tests) — `maxmailinTests` does not build for iOS.** `maxmailinTests/V2CutoverTests.swift:4903` uses `Process()` → "Cannot find 'Process' in scope" (`Process` is macOS-only). The line was added by 488e276 (`testSPLIT01_splitZipAttachedAsVolumes…`) and is not wrapped in `#if os(macOS)`. Consequence: `RunSomeTests StoreKitPurchaseFlowTests/askToBuyPendingThenApproved()` with an iPad simulator destination fails with "Build action failed"; no iOS-only test can run until this is fixed.

**F-2 (FOLD, P0) — a ZIP of an Apple Mail export imports with no folders.** Repro: import `MailExport.zip` (layout above) with "Keep every copy". Result: 51 messages, the backup inventory says `folders 0, folderMemberships 0`, and nothing shows Work / Work/Clients / the empty "Archive 2019". The FOLD-02 tests cover the directory layout, not that layout inside a ZIP. (This may also affect the Mac; the Mac was not walked.)

**F-3 (FOLD, iPad) — the iPad has no source-folder tree.** `FolderTreeView` (iOS) shows v1 buckets: "Inbox" = `type:received` (51), Has Attachments, Labels, Source Files (only with more than one source). The FOLD-01/02 tree (`ArchiveSidebarView`) is reached only from the macOS three-pane view. So even with folders stored, the iPad cannot show "every source folder with counts, empty folder listed".

**F-4 (FIND, P0 on iPad) — the attachment text is indexed but the search box cannot find it, and the empty result is silent.** Repro: type `zebracrossing`, `lighthouse` or `in:attachments zebracrossing` in "Search emails…". Result: "0 Emails" and a blank list, with no FIND-03 "no attachments matched / what was not searchable" notice. Evidence that the data is right: `search_chunks MATCH 'zebracrossing'` → `childText … The secret codeword is zebracrossing quarterly.`, `attachment_children` lists `inner/Contract.docx` extracted, and coverage marks all 3 attachments `extracted`. The console shows the query going to `[FTSSearchIndex] Opened FTS shard for year 2024/2025` (the previous index), which Health describes as "behind the plain box when the search model is off". Same result on Debug/Pro. Body words work (`Routine` → 20, with a "Body" chip).

**F-5 (FIND, iPad) — no way to reach the child document.** The message with `Bundle.zip` shows one attachment only; the child `Contract.docx` is not listed. On Free, the "Download Bundle.zip" button is **Disabled with no reason shown**, although the plan matrix says Free includes 10 attachment downloads.

**F-6 (OPEN, iPad) — the import receipt cannot be reached.** `LatestImportReceiptView` lives only in the macOS `Window("Import Receipt")`. The iPad has no receipt after an import (no counts, verdict or signature) and nothing in Settings ▸ Health/More to open it. At 51 messages progress was not visible either (the import finished within one capture), so the progress UI is untested here.

**F-7 (LIFE-02, iPad) — the backup goes into tmp, and restore is Mac-only.** `ArchiveBackups.backUpInteractively()` uses `FileManager.default.temporaryDirectory` on iOS. Confirmed on disk at `…/Application/F581BE6A…/tmp/mailin-backup-2026-11-08_03-31-57/`. The success line names a folder the user cannot open, so the "backup" is not one. "Restore from backup…" answers "Restoring from a backup folder is done on the Mac."

**F-8 (DUP, iPad, Debug/Pro):**
- (a) **There is no Trash on iPad**, so restore cannot be done. The sidebar has no Trash row, and `in:trash` in the search box is ignored (the list still shows the normal 50).
- (b) **Counts are stale after the move:** the header says 50 Emails, but All Emails still shows 51 and Inbox 51; the Duplicate Manager line still says "All 51 emails in scope processed".
- (c) With **Include near-duplicates** on at 85%, the near-duplicate (same subject, one "!" difference, different Message-ID) never appears as a candidate group. After the exact group was handled, the sheet says "**No duplicates found — Your email archive has no duplicate messages.**" That is an over-claim while near-duplicates exist and the whole-archive near-duplicate engine is off (the line above does say that switch is needed).
- (d) Grammar: "1 verified identical copies", "Verified identical (1 groups)", "1 redundant copies".

**F-9 (LIFE-04) — Speech Recognition permission is requested at first launch**, before onboarding finishes and before the user turns on the switch. The system half of the prompt says "Speech data from this app will be sent to Apple", while the app half says "Nothing is sent anywhere; recognition runs only when the switch in Settings ▸ Modules is on". The request should wait until the switch is turned on.

**F-10 (rule 4) — the toolbar "house" icon opens "Start New Import? This will clear your current emails…"** with "Clear & Start Fresh". It does not show how many emails will be cleared, and the icon looks like "Home", not "Clear archive".

**F-11 (OUT, rule 5) — the receipt says "Complete" after the share sheet was dismissed.** On iPad, Export ▸ mbox ▸ Start opened a share sheet that rendered blank in the simulator (a simulator issue). Closing it with ✕ left the receipt at "Complete — 51 written" with no saved / shared / cancelled outcome. The file stays in the app's tmp folder. The pre-flight sheet also shows the internal tmp path (`/Users/…/CoreSimulator/…/tmp`) as the "Destination".

**F-12 (minor UI)**
- In Settings ▸ Health, the floating **Done** button overlaps the top row's text.
- The iPad sidebar panel is fixed-height: Folders shows three rows above Apply/Clear with an empty area below; more rows would need scrolling inside a small box.
- "What's New" says "11 Languages" (English + 10). That is correct but worth matching to the store text.
- Console: duplicate key commands ⌘O / ⌘F / ⌘A / ⇧⌘G conflict with system menu items (`[MenuBuilder]` errors on every launch).

---

## Journey detail and click counts

### 1 — Open an archive (Release, Free)
1. Launch → Speech prompt (Don't Allow) → What's New → Continue → Terms (2 checkboxes + I Agree) = **5 taps** before the app.
2. **Open Email Archive** (1) → picker *On My iPad* (1) → select `MailExport.zip` (1) → **Open** (1) → pre-import sheet (`04-preimport-sheet-zip.png`): "Detected ZIP archive", Free allowance "100 MB, this import adds 5 KB", space "Adds about 16 KB (1.07 GB always kept free)", engine "Offset parser", "Receipt: written for every source".
3. Duplicates menu (1) → **Keep every copy** (1) → **Start import** (1). Total: **7 taps** from the welcome screen.
4. Result: 51 Emails, 27–29 Oct 2024 (`06-after-import-51.png`). No receipt on iPad (F-6). Unicode subjects display correctly in the list.
- Confusing: the default "Skip messages already in the archive" would have hidden the cross-folder duplicate. "Auto-Remove on Import" is ON in the sidebar while the sheet said "Keep every copy", and the two settings are not reconciled on screen.

### 2 — Preserve folders — FAIL (F-2, F-3). `06-after-import-51.png`.

### 3 — Search (Release and Debug)
- Body word `Routine` → 20 results with "Body" chips (2 taps + typing).
- Subject/attachment-name `Bundle` → 1 result with Subject and Attachment chips; opening it shows Bundle.zip only (`10-zip-message-no-child-shown.png`).
- Attachment-only words → 0 with a blank pane (`08-…`, `09-…`) — F-4. The chip-opens-attachment step cannot be reached.

### 4 — Duplicates
- Free Release: **Find Duplicates Now** → paywall (Personal pre-selected), with no line saying why it appeared (`13-…`).
- Debug/Pro: Find Duplicates Now (1) → "How to use" sheet → Got It (1) → the verified exact group with the scope line "whole archive — All 51 emails in scope processed" (`22-…`). Near-duplicates toggle (1) → still only the exact group (`23-…`). **Move All to Trash** (1) → confirmation with the count "1 redundant copies move to the Trash, where they can be restored…" (`24-…`) → Move to Trash (1) → 50 Emails (`25-…`). Total: **5 taps**. Restore could not be walked (F-8a).

### 5 — Export and verify (Release, Free)
Export Emails (1) → **mbox Archive** (1) → pre-flight "51 emails as mbox archive", "About 23 KB needed", "Can be resumed from its receipt if interrupted" (`15-…`) → Start (1) → share sheet (blank, ✕) → receipt card (`17-…`) → **Verify export** (1) → "rehash checked: the file matches the receipt's SHA-256; content checked: 51 of 51 messages say what the archive says" (`18-…`). Total: **4 taps + share sheet**. The file on disk has 51 `From ` separators, and Message-ID `<dupe-exact@…>` appears twice, as imported.

### LIFE
- Health (gear (1) → Health (1)): Integrity "Not checked yet" → **Run full check** (1) → OK (`07-…`). Rebuild search index; Recover missing imported attachments; Formats list with its evidence; Limits listed (single message 104.9 MB; previous duplicate engine newest 5,000; previous search index first 50,000 characters); Snapshots (a "scheduled" snapshot from the first launch, before the import); Back up / Restore (F-7); Original files copied; Archive fingerprint; 3.0 engines "Switched on 23 of 52", tripped 0, fallbacks 0; diagnostics 0/0/0.
- Settings ▸ Recovery (deleted-mail recovery) → "part of Personal — Unlock Personal" on Free.
- Resume after quit: pass.

## Ask to Buy (`StoreKitPurchaseFlowTests/askToBuyPendingThenApproved()`)
**Not run:** the test bundle fails to compile for iOS (F-1). Destination at run time: iPad Pro 13-inch (M5) simulator.

## Housekeeping
- Run destination switched back to **My Mac**.
- `/tmp/mailin-sim-rel` deleted. The simulator still has the **Debug** build installed with the walk's archive (51→50 emails), and `MailExport.zip` / `MailExport/` are in *On My iPad*.
- No source, project or tracker file was edited.

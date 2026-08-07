# mailin v2.0 — Ship Checklist

> **UPDATE 2026-08-07:** engineering is COMPLETE
> (V2_IMPLEMENTATION_COMPLETE.md, PR #4). Before running the archive steps
> below, execute the device gates in **V2_OWNER_RELEASE_CHECKLIST.md** —
> that file is the authoritative owner sequence; this one covers the
> Xcode-UI stamping/archive mechanics only.


A flip-the-switch list to take the current code state to a TestFlight-ready
v2.0 build. Code changes for v2 have landed in this branch already (see
`RELEASE_NOTES_v2.md`). The remaining work is project-file metadata plus a
re-archive.

> **Important:** the project.pbxproj must NOT be edited while Xcode is open
> — Xcode rewrites it from in-memory state and you'll lose edits or
> corrupt the project. **All steps that touch the project file must be
> done through the Xcode UI, with Xcode being the editor.** That's
> reflected in the steps below.

---

## Phase 1 — Stamp the build as v2.0.0 (do in Xcode UI)

Target: `maxmailin` (the sibling target inside `mailin.xcodeproj`, NOT the
original `mailin` target).

1. **Open the project in Xcode.** Select the `maxmailin` target in the
   sidebar.
2. Go to the **General** tab. Set:
   - **Version (CFBundleShortVersionString)** → `2.0.0`
   - **Build (CFBundleVersion)** → `200`
3. (Optional) on the same screen, set **Display Name** to `mailin` so the
   Dock label and Finder name read "mailin" once you flip the bundle ID
   in step 4. *Leave it as `maxmailin` if you want one more dry-run.*
4. Go to **Build Settings** → search for `PRODUCT_BUNDLE_IDENTIFIER`. For
   the `maxmailin` target, change it from:
   - `com.ecosanskriti.maxmailin` → `com.ecosanskriti.mailin`

   Apply to **both Debug and Release** configurations.

   > Doing this will conflict with the original `mailin` target's bundle ID
   > if both targets remain in the project. That's expected — only one
   > target will archive under this ID. See Phase 3 for retiring the old
   > target.

5. **Save** (`⌘S`) and close Xcode briefly.

---

## Phase 2 — Verify the build cleanly compiles

After re-opening Xcode:

1. Select scheme `maxmailin` → destination *My Mac*.
2. **Product → Clean Build Folder** (`⇧⌘K`).
3. **Product → Build** (`⌘B`). Should succeed with 0 errors.
4. **Product → Archive**. The archive should appear in Organizer with:
   - Bundle Identifier: `com.ecosanskriti.mailin`
   - Marketing Version: `2.0.0`
   - Build Number: `200`

If Organizer warns about a bundle-ID collision with the old `mailin`
target archive, that's fine for now — App Store Connect will treat this
archive as a new build of the existing `com.ecosanskriti.mailin` SKU.

---

## Phase 3 — Retire the old `mailin` target (optional but recommended)

You can keep the legacy `mailin` target around indefinitely as a fallback
build; nothing forces removal. But if you want a clean Xcode project:

1. In Xcode, select the original `mailin` target. **Right-click → Delete**.
2. When prompted, choose **Remove Reference** (NOT *Move to Trash*) — the
   source files in `mailin/` are shared between the two targets via the
   project's file-system-synchronised group. Removing reference simply
   detaches the target.
3. Update the default scheme:
   - **Product → Scheme → Manage Schemes** → set `maxmailin` as the
     active scheme.
   - (Optional) rename the scheme from `maxmailin` to `mailin` to match
     the product name.

After this, the project has one target that produces a `mailin.app` bundle
with ID `com.ecosanskriti.mailin`.

---

## Phase 4 — App Store Connect

1. **App Store Connect** → your `mailin` app → **+ Version**.
2. Version number: `2.0.0`.
3. **Upload Build**: drag the v2.0.0 archive from Organizer (or use
   `xcrun altool` / Transporter).
4. **What's New in This Version**: paste this short version of
   `RELEASE_NOTES_v2.md`:
   > **mailin 2.0 — Foundation release**
   > • Streaming ingest pipeline — memory bounded regardless of archive size
   > • Resumable imports — a crash mid-import resumes from the last batch, not the start of the file
   > • Year-sharded full-text search — fast across multi-million-message archives
   > • Keyset pagination — deep scrolling stays instant
   > • Robustness fixes from live testing — multi-sheet launch race, Keychain on main thread, FoundationModels context overflow
5. **Screenshots**: existing v1 screenshots are valid; the UI surface is
   unchanged in v2.0. Optionally add one screenshot of a large archive
   to highlight the scale story.
6. **Privacy answers**: no changes from v1.
7. **Submit for Review**.

---

## Phase 5 — Lock OFFLINE_MODE on (recommended)

mailin's product promise is "your archive never leaves the device."
The shipped v1 binary already had `OFFLINE_MODE` on for Release only;
**Debug** builds compile the network code in. To make the privacy
posture airtight — so a developer build can never accidentally send
or receive — set `OFFLINE_MODE` on Debug too.

In Xcode:
1. `maxmailin` target → **Build Settings** → search
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
2. **Debug** value is `DEBUG $(inherited)`. Change to
   `DEBUG OFFLINE_MODE $(inherited)`.
3. **Release** value already includes `OFFLINE_MODE` — leave alone.
4. Clean Build Folder, build, run. The Compose / IMAP / SMTP /
   Multiple-Accounts / Outbox UI should not appear in the running
   app — even in Debug.

This is optional but recommended. It removes the "what if a debug
build leaks" attack surface and makes the privacy claim verifiable by
running any build, not just the App Store one.

## Phase 6 — Standalone maxmailin repo

The `~/Downloads/maxmailin/` SPM repo (`github.com/sasmalgiri/maxmailin`)
is now orphaned by the consolidation. Options:

- **Archive on GitHub** — set the repo to read-only, add a note in the
  README that mailin v2 is the successor.
- **Rename to `mailin-engine`** — keep the standalone MaxMailCore /
  FTS5 / MboxStream library as a future engineering release.
- **Delete entirely** — if you don't want to maintain it.

The mailin v2 codebase doesn't depend on it.

---

## Quick code-state summary (as of v2.0 prep)

| File | Status |
|---|---|
| `BulkImportCoordinator.swift` | Streaming pipeline + per-batch checkpoint |
| `ImportCheckpointStore.swift` | SHA-256 + in-progress batch counter |
| `MBOXParser.swift` | `parseStreamingCallback` drain-as-you-go |
| `EmailParserProtocol.swift` | Streaming variant on ParserFactory |
| `PSTParser.swift` | mmap'd, 50 GB cap |
| `NSFParser.swift` | mmap'd, 64 GB cap |
| `FTSSearchIndex.swift` | Year-sharded router, LRU eviction, 20 open-handle cap |
| `EmailStore.swift` | `pageKeyset` (date, id) cursor + accountID column |
| `PaginatedEmailViewModel.swift` | Keyset adopted |
| `StoredEmail.swift` | `accountID` field added (lightweight migration) |
| `OutboxQueue.swift` | Persistent send queue (OFFLINE_MODE-gated) |
| `MailAccount.swift` / `MailAccountStore.swift` | Multi-account (OFFLINE_MODE-gated) |
| `IMAPSyncCursorStore.swift` / `IMAPSyncManager.swift` | Incremental sync (OFFLINE_MODE-gated) |
| `IMAPClient.swift` | UIDVALIDITY/UIDNEXT parsing, `uidFetchSince` |
| `OutboxQueueView.swift` / `AccountsView.swift` | UIs (OFFLINE_MODE-gated) |
| `SettingsView.swift` | New Accounts / Mail Sync / Outbox sections |
| `MemoryPressureHandler.swift` | Subscriber pattern for cache eviction |
| `FoundationModelEngine.swift` | 12k-char input cap to fit 4096-token window |
| `mailinApp.swift` | Launch-sheet race fixed; FTS5 eviction wired |

All storage paths use `com.ecosanskriti.mailin/` — same location as v1, so
the upgrade is in-place. No data migration needed for existing users.

---

## Rollback

If v2.0 ships and a critical bug surfaces:

1. App Store Connect → expedited review request → roll back to v1.x.
2. Existing v2 users keep their data (unchanged data layout).
3. Engineering can land fixes on the v2 branch and submit a 2.0.1 patch.

There's no destructive schema change in v2, so rollback is safe.

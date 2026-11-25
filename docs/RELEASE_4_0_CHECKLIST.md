# mailin 4.0 (build 1000) — release checklist for the owner

Owner decision 2026-11-14: 4.0 ships the **connected edition** on the existing App Store record
(`com.ecosanskriti.mailin`): Gmail over IMAP + Google app password, Outlook / Microsoft 365 via Microsoft sign-in,
iCloud / Fastmail / other IMAP with passwords; no cloud AI. Tick each line on the candidate, in order.

## 2026-11-19: the 4.0.1 attempt, reverted — and the Google application you owe

For about two hours on 2026-11-19 this checklist, the plist and the privacy page were switched to **4.0.1 (1001)
with Google sign-in**, on the report that Google had verified the restricted Gmail scopes. Your own console
screenshots then showed **Audience = Testing, 2 test users, no verification application**. Everything was reverted
to the 4.0 state (plist `imap`, 4.0 / 1000, privacy page 4.0 text re-published); the 4.0.1 switch is kept in git as
commit 03530d1 for the day Google approves.

**Apply to Google now, in parallel with the App Store submission** (`docs/V4_PROVIDER_REGISTRATION.md` §1 has every
text to paste; Google Auth Platform for project mailin-mail):
1. Google Search Console: prove ownership of `sasmalgiri.github.io` (URL-prefix property, HTML-file method).
2. Branding: app name, support email, logo, home page / privacy / terms URLs, authorized domain `sasmalgiri.github.io`.
3. Data access: add `gmail.readonly`, `gmail.labels`, `gmail.send`, `gmail.modify`; paste the §1.5 justifications.
4. Record the §1.6 demo video (about 3 minutes), upload unlisted on YouTube, give the link in the form.
5. Audience ▸ **Publish app** (In production), then Verification centre ▸ prepare and submit.
6. Expect brand review in days, scope review in weeks, Google emails asking for changes, and possibly a CASA security
   assessment for the restricted scopes (mailin keeps all data on the device and has no server, the case Google lists
   as possibly exempt; Google decides). **Approved** = Verification centre shows Verified per scope and a non-test
   user sees no "unverified app" warning. Tell the agent then; 4.0.1 is a re-apply of 03530d1 plus a test run.

## Status 2026-11-15 (agent part done)

- [x] Five-jobs gate on the candidate: V2CutoverTests + ConnectedFiveJobsTests + ConnectedFiveJobsFixPassTests
      209 passed, 2 skipped (owner-bound: S/MIME Keychain identity, speech permission), 0 failed.
- [x] Offline Debug (macOS) and Debug-Connected (iOS Simulator) builds compile.
- [x] Website for 4.0 (terms, home, support; privacy already 4.0) — merged to `main`; live once GitHub Pages publishes.
- [x] Tracker updated (`FIVE_JOBS_TRACKER.md` V4-12, V4-13, V4-15).
- [ ] Owner, in the app: delete the 8 empty test drafts; confirm "Remove and Delete Mail…" for the removed
      sasmalgiri account; try Change server mail on the Outlook account; look at Live Mail on an iPhone / iPad.

## Status 2026-11-19 (candidate 4bd48b2, agent part done)

- [x] Release-configuration unit run on 20cbfa2: Release 429 / Release-Connected 429, only the two StoreKit
      failures, fixed and re-verified 11/11 at 0ef44be (LIFE-06). Package `swift test -c release` 729/0 + opt-in 29/29.
- [x] Five-journey Mac UI test and main-window accessibility audit PASS on Release and Release-Connected (6da0b78).
- [x] Privacy page live with the 4.0 text (checked over HTTPS 2026-11-19); `docs/privacy` identical on `main`.
- [x] `Info-Connected.plist`: `MailinGmailSignInMode = imap`, Gmail and Graph client IDs present, Graph redirect
      `msauth.$(PRODUCT_BUNDLE_IDENTIFIER)://auth`. `ITSAppUsesNonExemptEncryption` not set (owner's declaration, §3).
- [x] Xcode: active scheme "maxmailin Connected", destination My Mac; the scheme's Archive action = Release-Connected.
- [ ] Not committed on purpose: `mailin.xcodeproj/xcshareddata/xcodecloud/manifest.json` (Xcode Cloud manifest
      inside the old 1.0 `mailin.xcodeproj`, not the release project) — delete it or leave it untracked.

## Status 2026-11-21 (candidate after the 20–21 Nov work, agent part done)

Since 19 Nov the candidate gained: fast import on by default (FAST-01…07), whole-list counts / dates / printing fixes
(LIST-01/02, PRINT-01, DEEP-01), Advanced Search + Whole words + search operators on the main list, New Message from
any page, named toolbar buttons (WORD-01…04), and empty-draft handling (DRAFT-01). Build stays **4.0 (1000)** — no
4.0 build has been uploaded yet; if one was uploaded in the meantime, raise the build to 1001 in Xcode first.

- [x] Package `swift test -c release`: 781 run, 0 failed, 26 opt-in skips.
- [x] Five-jobs gate + touched classes (Debug-Connected): 336 run, 333 passed, 2 owner-bound skips; one load-timing
      failure passed alone and in a quiet re-run of its class (207/208, 1 owner-bound skip).
- [x] What's New in the app (10 languages) and in `V4_STORE_METADATA_DRAFT.md` updated for the new features.
- [x] Build 0 warnings; every new string in 10 languages (InterfaceLocalizationTests pass).
- [ ] **Owner, in the app before the screenshots / review:** Live Mail ▸ Drafts ▸ "Delete 12 empty drafts".
- [ ] **Owner:** Settings ▸ Modules ▸ Archive ▸ "Search model" should be **on** (your 21 Nov screenshots show the
      search box without Whole words / Advanced Search, which appear only with it on). If it was switched off by the
      crash safeguard, turn it back on and tell the agent.
- [ ] Not run by the agent (blocked in its sandbox): the Release-configuration app unit run and the five Release UI
      journeys of 19 Nov. Optional re-run: scheme "maxmailin Release Tests" ▸ Test, with you at the Mac.

## Status 2026-11-26: 4.0.1 (1004) submitted; mailin Enterprise 4.0 (4) submitted

- mailin 4.0.1 (1004, 8e864a6 + 9685b38): HANG-01 fix only; What's New in 10 languages; uploaded via Organizer and
  submitted for iOS and macOS together; China mainland removed from availability (owner).
- mailin Enterprise 4.0 (build 4, branch enterprise-4.0 013c173): own icon, HANG-01, reviewed listing text; submitted
  for iOS and macOS together.

## Status 2026-11-25: iOS 4.0 (1003) approved — 4.0 released on both platforms

App Store Connect, 25 Nov 2026 02:24 IST: "Review of your mailin (iOS) submission is complete … eligible for
distribution" (submitted 24 Nov 04:30 PST, submission 5c90e16f-b6df-4d6e-a197-22bf8f96169f). Next: mailin
Enterprise 4.0 on branch `enterprise-4.0` (docs/ENTERPRISE_4_0_PLAN.md).

## Status 2026-11-25: macOS 4.0 (1003) approved

App Store Connect, 25 Nov 2026 01:43 IST: "Review of your mailin (macOS) submission is complete … eligible for
distribution" (submitted 23 Nov 11:56 PST, submission 6eee1f8b-c2e6-461b-b6d6-e0cf28a9d8af,
https://apps.apple.com/app/mailin/id6767245397). iOS 4.0 (1003) submitted, in review.

## Status 2026-11-23 (evening): 1003 is ready to archive

Also in 1003: CRASH-02 (7bb16e4) — crash reports are files in the on-device diagnostics folder, shown in Settings ▸
Crash reports (path, Show in Finder / Share reports), no banner in the window. Everything is pushed to
`v3-architecture`. Owner: archive "maxmailin Connected" for My Mac and for Any iOS Device, upload 4.0 (1003) from
Organizer, attach 1003 to both 4.0 versions in App Store Connect, submit.

## Status 2026-11-23 (afternoon): 1003 also carries TOR-01/02; release tests run

Since the 1003 note below: TOR-02 adaptive downloads (eb33b8d), TOR-01 endgame mode (2d4f9e3); TOR-03 Gmail batch
evaluated and not built (51ebf68). Build number unchanged (1003, not uploaded yet). Tests on this candidate:
- Package `swift test -c release`: 781 run, 26 opt-in skips, 0 failed.
- MailConnectivity with the fast-mode paths forced on (`MAILIN_PIPELINED_PAGES=1`): 197 run, 2 skips, 0 failed.
- Five-jobs gate + touched classes (V2CutoverTests, ConnectedFiveJobsTests, ConnectedFiveJobsFixPassTests,
  DeepDiveAppFixes, MailWorkspace, ConnectedLifecycleAudit, InterfaceLocalization): 277 run, 275 passed,
  2 owner-bound skips (S/MIME Keychain identity, offline build), 0 failed.
- Found on the way and fixed in the tests (not the app): ConnectedFiveJobs T14/T15 used a PDF with 19 text
  characters, which the reader rightly treats as a scanned page, so it passed only when this Mac's attachment-OCR
  switch was on — the fixture now has a real text layer; the DL-06 timing test compared ratios that a loaded machine
  stretched — now a relative check plus the limiter's own lower bound. OPEN02 (PST memory) failed twice in the app
  test host and passed in the quiet gate run; the same PST stream measured alone in the package is flat at 17 MB for
  all 20 batches (both runs), so the reader keeps nothing — the growth is other work in the test host process.

## Status 2026-11-23: build 1003 replaces 1002

**Upload and submit 4.0 (1003), for Mac and iOS** — it adds to 1002: Cancel sync in the Live Mail toolbar
(SYNC-CANCEL-01, 77b69f4) and the download-manager work (owner "build all"): newest mail and Inbox first (DL-01),
speed and time left under a saving account (DL-02), overlapping pages (DL-03) and parallel saving (DL-04) with the
fast mode, Automatic sync with Wi-Fi-only / while-charging / at-night conditions, off by default (DL-05), a download
speed limit, none by default (DL-06), and continuing a broken large IMAP download (DL-07). Build number set through
the target's build settings (all four configurations); version stays 4.0. Checks on this candidate: DeepDiveAppFixes,
MailWorkspace, ConnectedLifecycleAudit, InterfaceLocalization 54/0 (1 existing skip); package MailConnectivity 192/0
with the queue on and off. Owner check: Only on Wi-Fi and Only while charging on a real device.

## Status 2026-11-22 (evening): build 1002 replaces 1001

**Upload and submit 4.0 (1002), for Mac and iOS** — it adds to 1001: CRASH-01 (ac08d4f; the Mac window could
stop with "more Update Constraints in Window passes than there are views in the window" on Live Mail 8 s after a
status message, when that message cleared itself; the status line now sits below the three columns on the Mac) and
LIVE-SCALE-01 (e818082; 100,000 live messages on a 200,000-message archive measured — all checks pass, page calls
0.03–0.43 s; the 2 s account refresh no longer overlaps itself). Build number set through the target's build
settings (all four configurations); version stays 4.0. Checks on this candidate: DeepDiveAppFixes,
MailWorkspace, ConnectedLifecycleAudit 42/0 (1 existing skip); package LiveMailScaleTests (20k/20k) pass; full
rebuild: no warnings from mailin code (3 from Apple's StoreKitTest header / App Intents metadata step).

## Status 2026-11-22: build 1001 replaces 1000

4.0 (1000) was uploaded for the Mac on 21 Nov. **Upload and submit 4.0 (1001) instead, for Mac and iOS** — it adds:
the search-operators list opens below the search box (above it, it ran off the top of an iPhone screen; the App
Store screenshots show the fixed layout), and the bundled demo archive no longer carries the owner's name and address
(now "Alex Morgan <alex.morgan@example.com>"). Build number set through the target's build settings (all four
configurations); version stays 4.0. Checks: DeepDiveAppFixes (incl. the popover direction), InterfaceLocalization,
V3Lint 15/15; build 0 warnings. Screenshots: Downloads ▸ "mailin 4.0 App Store Screenshots" (Mac "Upload these (in
order)", iPhone 6.9-inch, iPad 13-inch).

## 0. Before archiving

- [x] The release-audit fixes (5 audits, 2026-11-14) that the owner wants in 4.0 are merged on `v3-architecture`
      (`FIVE_JOBS_TRACKER.md` § v4.0, release-audit note) — 9782aa6 is on `v3-architecture` and `main`.
- [x] **Privacy page published with the 4.0 text** (re-verified 2026-11-19 after the revert, `main` = 316dc78):
      `https://sasmalgiri.github.io/mailin/privacy/` says "Effective Date: November 14, 2026 (version 4.0)", lists
      `imap.gmail.com` / `graph.microsoft.com`, and the Google API Services heading says "(applies only when Google
      sign-in ships)". The 4.0.1 text was live for about an hour in between. The 3.0 text is at `/privacy/3.0.html`.
- [x] Xcode run destination is **My Mac** (2026-11-19); repeat the archive for **Any iOS Device** for the iPhone / iPad build.

## 1. Archive, validate, upload

- [ ] Scheme **"maxmailin Connected"** ▸ Product ▸ Archive. Its Archive action uses configuration
      **Release-Connected**; Organizer must show **4.0 (1000)**.
- [ ] Organizer ▸ Validate App — no errors.
- [ ] Organizer ▸ Distribute App ▸ App Store Connect ▸ Upload (CLI upload has been blocked before; Organizer works).
- [ ] Also Distribute ▸ Export (App Store Connect / or "Copy App") to a folder, for the checks below.

## 2. Check the exported app (Mac)

```
APP="/path/to/export/maxmailin.app"
codesign -d --entitlements - "$APP"
Scripts/check-connected-release.sh "$APP"
```

- [ ] Entitlements show `com.apple.security.app-sandbox` = true, `com.apple.security.network.client` = true,
      **no** `com.apple.security.network.server`.
- [ ] `check-connected-release.sh` ends `T47 connected checks: PASS`: marker `mailin.online.capable`; real
      `MailinGmailClientID` / `MailinGraphClientID` / `MailinGraphRedirectURI = msauth.com.ecosanskriti.mailin://auth`;
      no `CloudAIManager`; step 5 prints **`MailinGmailSignInMode = imap`** (the 4.0 value; `oauth` only from 4.0.1).
- [ ] (Offline edition, if one is also distributed) `Scripts/verify-no-network.sh` on that signed app passes all
      checks (see `NO_NETWORK_PROOF.md` § v4.0 correction: the package's transport code is linked but unreachable).

## 3. App Store Connect — version 4.0

- [ ] New version **4.0**; build 1000 selected (Mac and iOS).
- [ ] What's New, description, promotional text, keywords from `docs/V4_STORE_METADATA_DRAFT.md` (the app-password
      Gmail wording is the right one for 4.0), translated into the 10 listing languages; remove working tags such as
      "(V4-15 Outlook)" before pasting.
- [ ] **Privacy Policy URL:** `https://sasmalgiri.github.io/mailin/privacy/` (same URL; now the 4.0 text).
- [ ] **App Privacy:** answers per `docs/V4_APP_PRIVACY_ANSWERS.md` (owner's choice: "Data Not Collected" or the
      conservative declaration — and `PrivacyInfo.xcprivacy` must say the same).
- [ ] **Export compliance (owner's declaration).** Facts checked 2026-11-15: every cipher mailin uses is Apple's —
      TLS through URLSession / Network for mail; CommonCrypto (CCCryptor) for opening password-protected
      attachments (ODF Blowfish/AES, iWork, RAR, 7-Zip, Office, PDF); Security framework for S/MIME; CryptoKit for
      hashes. OpenPGP only verifies signatures (no decryption, no secret keys); Argon2 is a hash. No cipher is
      implemented in mailin's own code. So in App Store Connect choose: *uses encryption* → *only encryption that is
      exempt / provided by Apple's operating system* ("None of the algorithms mentioned above"). If you want the
      question to stop appearing on every upload, add `ITSAppUsesNonExemptEncryption = NO` to `Info-Connected.plist`
      (and `Info.plist`) — the agent did not add it because it is your legal statement.
- [ ] Screenshots: connected-edition shots per the metadata doc; no "Offline & Private" / "Live Mail is not included".
- [ ] **App Review Information ▸ Notes:** paste the review notes from `V4_STORE_METADATA_DRAFT.md` (exact steps:
      Settings ▸ Modules ▸ Live Mail on ▸ Features… ▸ Connected mail on ▸ Mail ▸ Add account…), with the Gmail-IMAP
      line: Change server mail is not available for Gmail with an app password in 4.0.
- [ ] **Demo accounts** in the sign-in fields (never in public text). Make new accounts used only for review —
      not your personal ones:
      1. **Outlook:** create a free account at outlook.live.com with a new @outlook.com address (no phone-only
         sign-in, no passkey: reviewers need a password). Send it 3–4 emails, one with an attachment, and make one
         folder.
      2. **iCloud or Gmail with an app password:** e.g. a new Gmail address, turn on 2-Step Verification, create an
         app password at myaccount.google.com/apppasswords, send it a few emails.
      3. In App Store Connect ▸ App Review Information: Sign-in required = No (the app works without), and in Notes
         add "Demo Outlook: <address> / <password>; demo Gmail: <address> / app password <16 letters>".
      4. On the day you submit, sign in to both once in mailin to check they still work, then remove them.
- [ ] Attach a small sample `.mbox` for the archive features.

## 3a. Microsoft publisher verification (recommended before or soon after release)

Without it, Microsoft's sign-in page shows mailin as **"unverified"**, and some work / school Microsoft 365
organisations block unverified apps entirely. Personal Outlook.com accounts still work.
1. Join the Microsoft AI Cloud Partner Program (free) at partner.microsoft.com with the same organisation as the
   Entra directory **ECOSANSKRITI**, and note the **Partner (MPN) ID**. It needs a domain email for the organisation
   (not gmail.com) and Microsoft's business verification, which can take a few days.
2. Entra admin center ▸ App registrations ▸ **mailin** ▸ Branding & properties ▸ Publisher verification ▸ enter the
   MPN ID ▸ Verify and save. The publisher domain must be verified first (Branding & properties ▸ Publisher domain).
3. Sign in again in mailin: the consent page should show a blue "verified" badge.

## 4. Release

- [ ] Release option: **phased release** for automatic updates (7 days) — pause it if a crash or a provider problem
      is reported; "Release to all users now" stays available.
- [ ] After release: on a clean Mac, install from the App Store, add one Gmail (app password) and one Outlook
      account, Preserve mail, Sync now — record the result in `FIVE_JOBS_TRACKER.md` V4-15.

## 5. 4.0.1 plan — Google sign-in (after Google approves; the whole switch is ready in commit 03530d1)

1. Finish Google's OAuth verification of the restricted Gmail scopes (`docs/V4_PROVIDER_REGISTRATION.md` §1); the
   consent screen points to the same privacy URL.
2. Flip **`MailinGmailSignInMode`** in `Info-Connected.plist` from `imap` to **`oauth`** (Google sign-in, Gmail API:
   `accounts.google.com`, `oauth2.googleapis.com`, `gmail.googleapis.com`). Accounts already added with an app
   password keep working over IMAP.
3. Before that build is released, update the privacy page: the Gmail row gains the Google API hosts and the
   "Google API Services (applies only when Google sign-in ships)" section becomes current (Limited Use), and
   `PrivacyPolicy.html` the same; update the App Privacy answers and review notes (Google sign-in page, Change server
   mail for Gmail via the Gmail API).
4. `Scripts/check-connected-release.sh` step 5 must then print `MailinGmailSignInMode = oauth`.

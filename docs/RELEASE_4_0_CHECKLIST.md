# mailin 4.0.1 (build 1001) — release checklist for the owner

Owner decision 2026-11-14: 4.0 ships the **connected edition** on the existing App Store record
(`com.ecosanskriti.mailin`): Gmail over IMAP + Google app password, Outlook / Microsoft 365 via Microsoft sign-in,
iCloud / Fastmail / other IMAP with passwords; no cloud AI. Tick each line on the candidate, in order.

**Owner decision 2026-11-19: the first submitted build is 4.0.1 (1001) with Google sign-in for Gmail.** Google's
consent screen is In production and the restricted `gmail.*` scopes are Verified (owner-attested); no 4.0 build was
uploaded. `Info-Connected.plist` carries `MailinGmailSignInMode = oauth`; the privacy page, What's New, store text and
review notes below are the 4.0.1 versions. Where a line below says 4.0 / 1000, read 4.0.1 / 1001.

## Status 2026-11-19, 4.0.1 (agent part done; see the commit for the hashes)

- [x] `MailinGmailSignInMode = oauth` in `Info-Connected.plist`; `MARKETING_VERSION = 4.0.1`, `CURRENT_PROJECT_VERSION = 1001`
      (set through Xcode's build settings, rule 12).
- [x] Privacy page text for 4.0.1 in `docs/privacy/index.html` + `PrivacyPolicy.html` (Google sign-in hosts and scopes,
      Limited Use section current, withdrawal at myaccount.google.com/permissions); the 4.0 text kept at
      `docs/privacy/4.0.html`; support page and home page updated. **Not live until `main` is published (§0).**
- [x] What's New 4.0.1 entry (connected edition only), 2 strings in 10 languages; in-app privacy summary names both
      Google withdrawal routes; `check-connected-release.sh` step 5 wording.
- [x] `V416GmailIMAPTests` now assert `oauth` (fails on the old plist); `MailWorkspaceTests` assert the 4.0.1 note.
- [ ] **Owner, on the candidate before archiving:** Live Mail ▸ Add account ▸ Gmail must open Google's page; sign in
      with your own account (the consent page must show the verified app, no "unverified app" warning), allow,
      Preserve mail ▸ Sync now, then switch on Change server mail and mark one message read / unread. Record the
      result in `FIVE_JOBS_TRACKER.md` V4-16 (this is the only live check of the oauth path on a verified consent screen).

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

## 0. Before archiving

- [x] The release-audit fixes (5 audits, 2026-11-14) that the owner wants in 4.0 are merged on `v3-architecture`
      (`FIVE_JOBS_TRACKER.md` § v4.0, release-audit note) — 9782aa6 is on `v3-architecture` and `main`.
- [x] ~~**Privacy page published.** `https://sasmalgiri.github.io/mailin/privacy/` says version 4.0 and lists
      `imap.gmail.com` / `graph.microsoft.com` (2026-11-19). The 3.0 text is at `/privacy/3.0.html`.~~
- [ ] **4.0.1 privacy page published.** Merge `v3-architecture` into `main` and push (GitHub Pages publishes `main`);
      then open `https://sasmalgiri.github.io/mailin/privacy/`: it must say "Effective Date: November 19, 2026
      (version 4.0.1)", list `accounts.google.com` / `gmail.googleapis.com` / `graph.microsoft.com`, and the
      "Google API Services" heading must no longer say "applies only when Google sign-in ships". The 4.0 text is at
      `/privacy/4.0.html`, the 3.0 text at `/privacy/3.0.html`. Until this is live, do not submit (App Review and
      Google read the URL).
- [x] Xcode run destination is **My Mac** (2026-11-19); repeat the archive for **Any iOS Device** for the iPhone / iPad build.

## 1. Archive, validate, upload

- [ ] Scheme **"maxmailin Connected"** ▸ Product ▸ Archive. Its Archive action uses configuration
      **Release-Connected**; Organizer must show **4.0.1 (1001)**.
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
      no `CloudAIManager`; step 5 prints **`MailinGmailSignInMode = oauth`** (the 4.0.1 value; `imap` was 4.0).
- [ ] (Offline edition, if one is also distributed) `Scripts/verify-no-network.sh` on that signed app passes all
      checks (see `NO_NETWORK_PROOF.md` § v4.0 correction: the package's transport code is linked but unreachable).

## 3. App Store Connect — version 4.0.1

- [ ] New version **4.0.1**; build 1001 selected (Mac and iOS).
- [ ] What's New, description, promotional text, keywords from `docs/V4_STORE_METADATA_DRAFT.md` **with the 4.0.1
      replacements at the top of that file** (Google sign-in lines), translated into the 10 listing languages; remove
      working tags such as "(V4-15 Outlook)" before pasting.
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
- [ ] **App Review Information ▸ Notes:** paste the review notes from `V4_STORE_METADATA_DRAFT.md` with the 4.0.1
      replacements (exact steps: Settings ▸ Modules ▸ Live Mail on ▸ Features… ▸ Connected mail on ▸ Mail ▸
      Add account…; Gmail = "Sign in…" on Google's page; Change server mail works for Gmail).
- [ ] **Demo accounts** in the sign-in fields (never in public text). Make new accounts used only for review —
      not your personal ones:
      1. **Outlook:** create a free account at outlook.live.com with a new @outlook.com address (no phone-only
         sign-in, no passkey: reviewers need a password). Send it 3–4 emails, one with an attachment, and make one
         folder.
      2. **Gmail with Google sign-in:** a new Gmail address with a password the reviewer can type on Google's page
         (no passkey-only sign-in; if Google forces 2-Step Verification, put backup codes in the notes). Send it a
         few emails and add one label. Sign in once yourself from a fresh mailin archive to see that the consent page
         shows the verified app.
      3. In App Store Connect ▸ App Review Information: Sign-in required = No (the app works without), and in Notes
         add "Demo Outlook: <address> / <password>; demo Gmail: <address> / <password> (Google sign-in page;
         backup codes: …)".
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

## 5. 4.0.1 plan — Google sign-in — **done 2026-11-19 (this is the submitted version; steps 1–4 below are complete)**

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

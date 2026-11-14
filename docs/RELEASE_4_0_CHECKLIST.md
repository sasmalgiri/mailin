# mailin 4.0 (build 1000) — release checklist for the owner

Owner decision 2026-11-14: 4.0 ships the **connected edition** on the existing App Store record
(`com.ecosanskriti.mailin`): Gmail over IMAP + Google app password, Outlook / Microsoft 365 via Microsoft sign-in,
iCloud / Fastmail / other IMAP with passwords; no cloud AI. Tick each line on the candidate, in order.

## 0. Before archiving

- [ ] The release-audit fixes (5 audits, 2026-11-14) that the owner wants in 4.0 are merged on `v3-architecture`
      (`FIVE_JOBS_TRACKER.md` § v4.0, release-audit note).
- [ ] **Privacy page published.** Merge / publish the branch to the GitHub Pages site and open
      `https://sasmalgiri.github.io/mailin/privacy/` in a browser: it must say "Effective Date: November 14, 2026
      (version 4.0)" and list `imap.gmail.com` / `graph.microsoft.com`. The 3.0 text is at `/privacy/3.0.html`.
      Until this is live, do not submit (App Review reads the URL).
- [ ] Xcode run destination is **My Mac** (then repeat the archive for **Any iOS Device** for the iPhone / iPad build).

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
      no `CloudAIManager`; step 5 prints **`MailinGmailSignInMode = imap`** (the 4.0 value).
- [ ] (Offline edition, if one is also distributed) `Scripts/verify-no-network.sh` on that signed app passes all
      checks (see `NO_NETWORK_PROOF.md` § v4.0 correction: the package's transport code is linked but unreachable).

## 3. App Store Connect — version 4.0

- [ ] New version **4.0**; build 1000 selected (Mac and iOS).
- [ ] What's New, description, promotional text, keywords from `docs/V4_STORE_METADATA_DRAFT.md`, translated into the
      10 listing languages; remove working tags such as "(V4-15 Outlook)" before pasting.
- [ ] **Privacy Policy URL:** `https://sasmalgiri.github.io/mailin/privacy/` (same URL; now the 4.0 text).
- [ ] **App Privacy:** answers per `docs/V4_APP_PRIVACY_ANSWERS.md` (owner's choice: "Data Not Collected" or the
      conservative declaration — and `PrivacyInfo.xcprivacy` must say the same).
- [ ] Export compliance: standard TLS only (answer stays "No non-exempt encryption", per the answers doc).
- [ ] Screenshots: connected-edition shots per the metadata doc; no "Offline & Private" / "Live Mail is not included".
- [ ] **App Review Information ▸ Notes:** paste the review notes from `V4_STORE_METADATA_DRAFT.md` (exact steps:
      Settings ▸ Modules ▸ Live Mail on ▸ Features… ▸ Connected mail on ▸ Mail ▸ Add account…), with the Gmail-IMAP
      line: Change server mail is not available for Gmail with an app password in 4.0.
- [ ] **Demo accounts** in the sign-in fields (never in public text): a Gmail or iCloud address with an **app
      password** (Gmail: 2-Step Verification on, myaccount.google.com/apppasswords), and an Outlook.com account for
      the Microsoft sign-in. Check both still sign in the day you submit.
- [ ] Attach a small sample `.mbox` for the archive features.

## 4. Release

- [ ] Release option: **phased release** for automatic updates (7 days) — pause it if a crash or a provider problem
      is reported; "Release to all users now" stays available.
- [ ] After release: on a clean Mac, install from the App Store, add one Gmail (app password) and one Outlook
      account, Preserve mail, Sync now — record the result in `FIVE_JOBS_TRACKER.md` V4-15.

## 5. 4.0.1 plan — Google sign-in

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

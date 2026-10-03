# App Review Notes — mailin

Paste each section below into the corresponding field in **App Store Connect → mailin → TestFlight (or App Store) → Submit for Review**.

---

## 1. App Review Information → Notes (the big text box)

```
Thank you for reviewing mailin.

HOW TO TEST WITHOUT A REAL EMAIL ARCHIVE
Help > Open sample loads the bundled demo_emails.mbox (fictional messages). Or use "Try with Sample Data" on the welcome screen, or drag any .mbox/.eml/.pst/.msg/.nsf/.zip onto the window. Sample data can be removed at any time from Settings.

WHAT TO LOOK FOR (VERSION 3.0)
- The Archive page is always on: mailboxes, sources and labels on the left, the list in the middle, the message on the right. J/K move, Return opens, / searches.
- Import: drop several files to see the import queue (pause, resume, stop one file, reorder). Every import ends in a receipt.
- Search "project" or "invoice": results say where they matched and how much of the archive the index covered.
- Export (toolbar > Export): a pre-flight sheet shows the space needed; the run ends in a receipt with the file's SHA-256. Cancel mid-way and the receipt offers Resume.
- AI Insights and Professional Workflows are OPTIONAL pages, off on a fresh install. The page switcher at the top explains what each needs and turns it on. AI Insights runs on-device (Apple NaturalLanguage; Apple Intelligence on macOS 26+).
- There is no Live Mail page in this build: the page switcher shows Archive, AI Insights and Professional Workflows only. No account can be added and no mail server is contacted.

OFFLINE-FIRST
mailin works completely offline. No account creation, no login, no developer server, no network calls for anything to do with the archive. There is no cloud AI: the app has no network entitlement and cannot contact any server.

SUBSCRIPTIONS / IN-APP PURCHASES
All paywalls are gated by free trial. The app is fully functional in the free tier for evaluation: sample data, basic search, parsing, and a limited number of exports. Auto-renewable subscriptions (Personal / Professional) and a one-time Lifetime purchase unlock unlimited exports and advanced forensic features. Subscriptions are managed via standard StoreKit 2; cancellation is via Apple's standard Settings → Subscriptions UI.

DEMO ACCOUNT
Not required. mailin has no account system — it is a local file analyzer. No login, no signup, no server.

PRIVACY
- No tracking. No analytics SDK. No third-party libraries.
- All processing is on-device by default.
- No cloud AI. The app has no network entitlement.
- Privacy Manifest (PrivacyInfo.xcprivacy) declares zero data collection and only Required Reason APIs.

CONTACT
For any questions during review, please email: sasmalgiri@gmail.com (typical response within 24 hours, IST timezone).

Thank you.
```

---

## 2. App Review Information → Sign-In Required

**Toggle: OFF** (the app has no sign-in / no account system).

---

## 3. App Review Information → Demo Account

Leave blank. (Reason: no account system.)

---

## 4. App Privacy → Data Types Collected

For every category, select: **"No, we do not collect data from this app."**

mailin's `PrivacyInfo.xcprivacy` declares zero collected data. Reviewers will cross-check against your declaration here — these must agree.

---

## 5. Content Rights → Does your app contain, display, or access third-party content?

**No.** (User-imported email archives are the user's own data, not third-party content.)

---

## 6. Encryption Export Compliance (one-time)

In Info.plist (or App Store Connect → App Information → Export Compliance):

**`ITSAppUsesNonExemptEncryption`: YES**
**Self-classification report: NOT required** because mailin only uses:
- Standard HTTPS (Apple-exempt)
- CryptoKit (SHA-256, Curve25519 for export signing) — all Apple-provided
- No proprietary cryptographic algorithms
- No encryption "added beyond what's already in iOS/macOS"

This qualifies for **Mass Market self-classification with exemption** under U.S. Export Administration Regulation 740.17(b)(1).

In Info.plist add (if not already there):
```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```
Setting `<false/>` is correct because all encryption used is Apple-exempt.

---

## 7. Age Rating

Recommended: **4+** (no objectionable content). The app is a file/document viewer with analytical features. Sample data contains professional business emails with no mature themes.

---

## 8. Standard Reviewer Questions (anticipated) and your answers

**Q: How can users test the forensic features without their own data?**
A: The "Try with Sample Data" button loads 25 fictional emails. Reviewer can then open Settings → Forensic Mode → enable, then run Hash Verification, Chain of Custody export, Bates Numbering, etc.

**Q: Are the forensic outputs court-admissible?**
A: No, and the app explicitly disclaims this. See in-app Terms of Use clause 6 and the visible disclaimer in Settings: "Disclaimer: Forensic features are analytical tools and have NOT been independently validated for court admissibility." Admissibility is jurisdiction-specific; the app supports workflows but makes no admissibility claim.

**Q: Does the app upload email content anywhere?**
A: No. All processing is on-device and the app has no network entitlement, so it cannot upload anything. There is no cloud AI.

**Q: Why does the app declare BGTaskScheduler for background analysis?**
A: To allow long-running parsing/indexing of large archives to continue when the user briefly switches apps. Background work is gated to user-initiated parses only — never opportunistic, never network-bound.

**Q: Why does the app need file access?**
A: To open user-selected email archives (.mbox, .eml, .emlx, .msg, .pst, .ost). All access is through the standard `UIDocumentPickerViewController` / NSOpenPanel — user-selected only, no broad file system access.

**Q: AI outputs — are they accurate?**
A: A visible banner above every AI feature reads "AI and software can make mistakes. Verify important results before relying on them." The Terms of Use clause 7 explicitly disclaims accuracy and assigns verification responsibility to the user.

**Q: What is the subscription model?**
A: Standard StoreKit 2 auto-renewable subscriptions (monthly / yearly) plus a one-time Lifetime purchase. Free tier is fully usable for evaluation (up to 100 MB of imported input and the first 500 results of any list or search; 5 AI queries a day). Subscriptions auto-renew per Apple's standard terms; cancellation is via Settings → Subscriptions.

**Q: GDPR Compliance Report — does this confer GDPR compliance on the user's data?**
A: No. It's a discovery tool that helps users locate personal data (PII) in their email archives. The user remains the data controller; mailin is a tool, not a compliance certifier. This is clearly stated in the Glossary entry for "GDPR" and in the report's own disclaimer.

---

## 9. After Approval — What to do

- The app appears in TestFlight Internal Testing within minutes.
- Add up to 100 internal testers via App Store Connect → Users and Access.
- External testers require a Beta App Review (~24h).
- Once you submit for App Store review (not just TestFlight), expect 24–48h review time for first submission.

---

## Notes for you (do NOT paste to Apple)

- Keep the "Try with Sample Data" button prominent — that single feature has the highest impact on review pass rate.
- If a reviewer requests a video demo, screenshot the workflow with sample data loaded. Don't use your real email archive.
- If asked for proof of trademark/company, you have EcoSanskriti Innovation Pvt Ltd company registration and the MAILIN trademark search results (Class 9 & 42 clear) you ran on ipindia.gov.in.
